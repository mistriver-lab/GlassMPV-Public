import CoreVideo
import Foundation
import Metal
#if canImport(MetalFX) && !targetEnvironment(simulator)
import MetalFX
#endif
import QuartzCore
import VideoToolbox

private struct MetalEnhanceUniforms {
    var deblurStrength: Float
    var casStrength: Float
    var lineDarken: Float
    var clarityStrength: Float
    var noiseDeadzone: Float
    var isVideoRange: UInt32
    var isBT601: UInt32
    var compareMode: UInt32
    var splitX: Float
    var padding: UInt32
}

private struct MetalDisplayVertexUniforms {
    var scaleX: Float
    var scaleY: Float
}

private struct MetalFlowWarpUniforms {
    var phase: Float
    var flowScaleX: Float
    var flowScaleY: Float
    var flowTexelX: Float
    var flowTexelY: Float
    var deblurStrength: Float
    var casStrength: Float
    var lineDarken: Float
    var clarityStrength: Float
    var noiseDeadzone: Float
    var isVideoRange: UInt32
    var isBT601: UInt32
    var compareMode: UInt32
    var splitX: Float
    var isSceneCut: UInt32
}

enum MetalDirectRenderResult: Equatable, Sendable {
    case rendered
    case skippedBusy
    case unavailable
}

private final class MetalInFlightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightCount: Int = 0

    func tryAcquire(maxInFlight: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlightCount < max(1, maxInFlight) else {
            return false
        }
        inFlightCount += 1
        return true
    }

    func release() {
        lock.lock()
        inFlightCount = max(0, inFlightCount - 1)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        inFlightCount = 0
        lock.unlock()
    }
}

private final class MetalGPUTimingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var averageMs: Double = 0
    private var count: Int = 0

    func record(gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval, fallbackStart: CFTimeInterval) {
        let rawMs: Double
        if gpuEnd > gpuStart {
            rawMs = (gpuEnd - gpuStart) * 1000.0
        } else {
            rawMs = max(0.05, (CACurrentMediaTime() - fallbackStart) * 1000.0)
        }
        let clamped = max(0.05, min(rawMs, 200.0))
        lock.lock()
        count += 1
        averageMs = (count == 1) ? clamped : (averageMs * 0.85 + clamped * 0.15)
        lock.unlock()
    }

    func snapshotAverageMs() -> Double {
        lock.lock()
        let v = averageMs
        lock.unlock()
        return v
    }

    func reset() {
        lock.lock()
        averageMs = 0
        count = 0
        lock.unlock()
    }
}

/// 零第三方依赖的实时 FP16 Metal + MetalFX GPU 画质增强与零拷贝直绘引擎
@MainActor
final class MetalVideoEnhancer {
    private(set) var activePipelineLabel: String = "关闭"
    private(set) var averageProcessMs: Double = 0
    private(set) var enhancedFrameCount: Int = 0
    private(set) var shaderInitError: String?

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private let gpuTimingTracker = MetalGPUTimingTracker()
    private let inFlightCounter = MetalInFlightCounter()

    private var enhanceLumaPipeline: MTLComputePipelineState?
    private var copyChromaPipeline: MTLComputePipelineState?
    private var enhanceBGRAPipeline: MTLComputePipelineState?
    private var yuvToBGRAPipeline: MTLComputePipelineState?
    private var bicubicBGRAPipeline: MTLComputePipelineState?

    private var displayYUVRenderPipeline: MTLRenderPipelineState?
    private var displayBGRARenderPipeline: MTLRenderPipelineState?
    private var displayFlowWarpYUVRenderPipeline: MTLRenderPipelineState?

    private var outputPool: CVPixelBufferPool?
    private var outputPoolSignature: String = ""

#if canImport(MetalFX) && !targetEnvironment(simulator)
    private var spatialScaler: MTLFXSpatialScaler?
#endif
    private var scalerInputTexture: MTLTexture?
    private var scalerOutputTexture: MTLTexture?
    private var scalerSignature: String = ""
    private var isUsingHardwareMetalFX: Bool = false

    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct EnhanceUniforms {
        float deblurStrength;
        float casStrength;
        float lineDarken;
        float clarityStrength;
        float noiseDeadzone;
        uint isVideoRange;
        uint isBT601;
        uint compareMode;
        float splitX;
        uint padding;
    };

    struct DisplayVertexUniforms {
        float scaleX;
        float scaleY;
    };

    struct FlowWarpUniforms {
        float phase;
        float flowScaleX;
        float flowScaleY;
        float flowTexelX;
        float flowTexelY;
        float deblurStrength;
        float casStrength;
        float lineDarken;
        float clarityStrength;
        float noiseDeadzone;
        uint isVideoRange;
        uint isBT601;
        uint compareMode;
        float splitX;
        uint isSceneCut;
    };

    struct QuadVaryings {
        float4 position [[position]];
        float2 uv;
    };

    inline half toUnitLumaH(half raw, uint isVideoRange) {
        if (isVideoRange == 0u) {
            return clamp(raw, half(0.0h), half(1.0h));
        }
        return clamp((raw - half(0.0627451h)) * half(1.1643836h), half(0.0h), half(1.0h));
    }

    inline half fromUnitLumaH(half unitVal, uint isVideoRange) {
        half clamped = clamp(unitVal, half(0.0h), half(1.0h));
        if (isVideoRange == 0u) {
            return clamped;
        }
        return clamp(clamped * half(0.8588235h) + half(0.0627451h), half(0.004h), half(0.996h));
    }

    inline half rgbLumaH(half3 c) {
        return dot(c, half3(0.2126h, 0.7152h, 0.0722h));
    }

    inline half3 yuvSampleToRGBH(half yUnit, half2 uvRaw, uint isVideoRange, uint isBT601) {
        half cb = uvRaw.x - half(0.5019608h);
        half cr = uvRaw.y - half(0.5019608h);
        if (isVideoRange != 0u) {
            cb *= half(1.1383929h);
            cr *= half(1.1383929h);
        }
        half3 rgb;
        if (isBT601 != 0u) {
            rgb.r = yUnit + half(1.402h) * cr;
            rgb.g = yUnit - half(0.344136h) * cb - half(0.714136h) * cr;
            rgb.b = yUnit + half(1.772h) * cb;
        } else {
            rgb.r = yUnit + half(1.5748h) * cr;
            rgb.g = yUnit - half(0.187324h) * cb - half(0.468124h) * cr;
            rgb.b = yUnit + half(1.8556h) * cb;
        }
        return clamp(rgb, half(0.0h), half(1.0h));
    }

    inline float sampleMitchellWeightH(float x) {
        float ax = fabs(x);
        if (ax < 1.0f) {
            return ((7.0f * ax * ax * ax) - (12.0f * ax * ax) + 5.3333333f) / 6.0f;
        }
        if (ax < 2.0f) {
            return ((-2.3333333f * ax * ax * ax) + (12.0f * ax * ax) - (20.0f * ax) + 10.6666667f) / 6.0f;
        }
        return 0.0f;
    }

    inline half sampleLumaNeutralCubicH(
        texture2d<half, access::sample> inY,
        float2 uv,
        uint isVideoRange
    ) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float texW = max(1.0f, float(inY.get_width()));
        float texH = max(1.0f, float(inY.get_height()));
        float2 texPos = uv * float2(texW, texH) - 0.5f;
        float2 center = floor(texPos);
        float2 frac = texPos - center;
        half accum = half(0.0h);
        half weightSum = half(0.0h);
        for (int dy = -1; dy <= 1; ++dy) {
            float wy = sampleMitchellWeightH(float(dy) - frac.y);
            for (int dx = -1; dx <= 1; ++dx) {
                float w = wy * sampleMitchellWeightH(float(dx) - frac.x);
                half hw = half(w);
                float2 sampleUV = (center + float2(float(dx), float(dy)) + 0.5f) / float2(texW, texH);
                accum += toUnitLumaH(inY.sample(linearSampler, sampleUV).r, isVideoRange) * hw;
                weightSum += hw;
            }
        }
        return clamp(accum / max(weightSum, half(0.0001h)), half(0.0h), half(1.0h));
    }

    inline half3 sampleRGBNeutralCubicH(
        texture2d<half, access::sample> inColor,
        float2 uv
    ) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float texW = max(1.0f, float(inColor.get_width()));
        float texH = max(1.0f, float(inColor.get_height()));
        float2 texPos = uv * float2(texW, texH) - 0.5f;
        float2 center = floor(texPos);
        float2 frac = texPos - center;
        half3 accum = half3(0.0h);
        half weightSum = half(0.0h);
        for (int dy = -1; dy <= 1; ++dy) {
            float wy = sampleMitchellWeightH(float(dy) - frac.y);
            for (int dx = -1; dx <= 1; ++dx) {
                float w = wy * sampleMitchellWeightH(float(dx) - frac.x);
                half hw = half(w);
                float2 sampleUV = (center + float2(float(dx), float(dy)) + 0.5f) / float2(texW, texH);
                accum += inColor.sample(linearSampler, sampleUV).rgb * hw;
                weightSum += hw;
            }
        }
        return clamp(accum / max(weightSum, half(0.0001h)), half(0.0h), half(1.0h));
    }

    // FP16 5-tap + 4-diagonal bilinear multi-scale luma restoration (halo-clamped, zero exp)
    inline half computeEnhancedLumaParamsH(
        half c,
        half n,
        half s,
        half w,
        half e,
        half d0,
        half d1,
        half d2,
        half d3,
        float deblurStrength,
        float casStrength,
        float lineDarken,
        float clarityStrength,
        float noiseDeadzone
    ) {
        half mn1 = min(min(c, n), min(s, min(w, e)));
        half mx1 = max(max(c, n), max(s, max(w, e)));
        half working = c;
        half deadzone = half(noiseDeadzone);

        if (deblurStrength > 0.001f) {
            half blurFine = half(0.25h) * (n + s + w + e);
            half blurWide = half(0.25h) * (d0 + d1 + d2 + d3);
            half detailFine = c - blurFine;
            half detailWide = c - blurWide;
            half signF = detailFine >= half(0.0h) ? half(1.0h) : half(-1.0h);
            half signW = detailWide >= half(0.0h) ? half(1.0h) : half(-1.0h);
            half gatedFine = signF * max(half(0.0h), abs(detailFine) - deadzone * half(0.65h));
            half gatedWide = signW * max(half(0.0h), abs(detailWide) - deadzone);
            half rawUnsharp = working + half(deblurStrength) * (half(0.55h) * gatedFine + half(0.70h) * gatedWide);
            working = clamp(rawUnsharp, mn1 - half(0.025h), mx1 + half(0.025h));
        }

        if (casStrength > 0.001f) {
            half peakAmp = sqrt(clamp(min(mn1, half(1.0h) - mx1) / max(mx1, half(0.001h)), half(0.0h), half(1.0h)));
            half sharpenWeight = peakAmp * half(-0.125f - 0.075f * clamp(casStrength, 0.0f, 1.0f));
            half sharpened = (working + (n + s + w + e) * sharpenWeight) / (half(1.0h) + half(4.0h) * sharpenWeight);
            working = clamp(sharpened, max(half(0.0h), mn1 - half(0.02h)), min(half(1.0h), mx1 + half(0.02h)));
        }

        if (lineDarken > 0.001f) {
            half avgLocal = half(0.25h) * (n + s + w + e);
            half darkDelta = max(half(0.0h), avgLocal - working);
            half gatedDark = max(half(0.0h), darkDelta - deadzone * half(0.5h));
            working = max(half(0.0h), working - gatedDark * half(lineDarken * 1.55f));
        }

        if (clarityStrength > 0.001f) {
            half midOffset = working - half(0.5h);
            working = clamp(working + half(clarityStrength) * (working * (half(1.0h) - working) * (midOffset * half(1.85h))), half(0.0h), half(1.0h));
        }

        return clamp(working, half(0.0h), half(1.0h));
    }

    inline half computeEnhancedLumaFastH(
        half c,
        half n,
        half s,
        half w,
        half e,
        half d0,
        half d1,
        half d2,
        half d3,
        constant EnhanceUniforms& u
    ) {
        return computeEnhancedLumaParamsH(
            c, n, s, w, e, d0, d1, d2, d3,
            u.deblurStrength, u.casStrength, u.lineDarken, u.clarityStrength, u.noiseDeadzone
        );
    }

    vertex QuadVaryings fullscreenQuadVertex(
        uint vid [[vertex_id]],
        constant DisplayVertexUniforms& v [[buffer(0)]]
    ) {
        float2 positions[4] = {
            float2(-1.0f, -1.0f),
            float2( 1.0f, -1.0f),
            float2(-1.0f,  1.0f),
            float2( 1.0f,  1.0f)
        };
        float2 uvs[4] = {
            float2(0.0f, 1.0f),
            float2(1.0f, 1.0f),
            float2(0.0f, 0.0f),
            float2(1.0f, 0.0f)
        };
        QuadVaryings out;
        float2 pos = positions[vid];
        out.position = float4(pos.x * v.scaleX, pos.y * v.scaleY, 0.0f, 1.0f);
        out.uv = uvs[vid];
        return out;
    }

    fragment half4 displayEnhanceYUVFragment(
        QuadVaryings in [[stage_in]],
        texture2d<half, access::sample> inY [[texture(0)]],
        texture2d<half, access::sample> inUV [[texture(1)]],
        constant EnhanceUniforms& u [[buffer(0)]]
    ) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 uv = in.uv;
        half2 chroma = inUV.sample(linearSampler, uv).rg;
        half yCenter = toUnitLumaH(inY.sample(linearSampler, uv).r, u.isVideoRange);

        if (u.compareMode == 2u) {
            return half4(yuvSampleToRGBH(yCenter, chroma, u.isVideoRange, u.isBT601), half(1.0h));
        }
        if (u.compareMode == 3u) {
            half yCubic = sampleLumaNeutralCubicH(inY, uv, u.isVideoRange);
            return half4(yuvSampleToRGBH(yCubic, chroma, u.isVideoRange, u.isBT601), half(1.0h));
        }
        float splitRatio = clamp(u.splitX, 0.1f, 0.9f);
        float invWidth = 1.0f / max(1.0f, float(inY.get_width()));
        float invHeight = 1.0f / max(1.0f, float(inY.get_height()));
        if (u.compareMode == 1u) {
            if (abs(uv.x - splitRatio) <= max(0.0022f, invWidth * 1.5f)) {
                return half4(half(0.25h), half(0.96h), half(0.98h), half(1.0h));
            }
            if (uv.x < splitRatio) {
                return half4(yuvSampleToRGBH(yCenter, chroma, u.isVideoRange, u.isBT601), half(1.0h));
            }
        }

        float2 dx = float2(invWidth, 0.0f);
        float2 dy = float2(0.0f, invHeight);
        float2 dDiagA = float2(invWidth * 1.35f, invHeight * 1.35f);
        float2 dDiagB = float2(invWidth * 1.35f, -invHeight * 1.35f);

        half yN = toUnitLumaH(inY.sample(linearSampler, uv - dy).r, u.isVideoRange);
        half yS = toUnitLumaH(inY.sample(linearSampler, uv + dy).r, u.isVideoRange);
        half yW = toUnitLumaH(inY.sample(linearSampler, uv - dx).r, u.isVideoRange);
        half yE = toUnitLumaH(inY.sample(linearSampler, uv + dx).r, u.isVideoRange);
        half d0 = toUnitLumaH(inY.sample(linearSampler, uv - dDiagA).r, u.isVideoRange);
        half d1 = toUnitLumaH(inY.sample(linearSampler, uv + dDiagA).r, u.isVideoRange);
        half d2 = toUnitLumaH(inY.sample(linearSampler, uv - dDiagB).r, u.isVideoRange);
        half d3 = toUnitLumaH(inY.sample(linearSampler, uv + dDiagB).r, u.isVideoRange);

        half yOut = computeEnhancedLumaFastH(yCenter, yN, yS, yW, yE, d0, d1, d2, d3, u);
        return half4(yuvSampleToRGBH(yOut, chroma, u.isVideoRange, u.isBT601), half(1.0h));
    }

    fragment half4 displayEnhanceBGRAFragment(
        QuadVaryings in [[stage_in]],
        texture2d<half, access::sample> inColor [[texture(0)]],
        constant EnhanceUniforms& u [[buffer(0)]]
    ) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 uv = in.uv;
        half4 centerRGBA = inColor.sample(linearSampler, uv);
        if (u.compareMode == 2u) {
            return centerRGBA;
        }
        if (u.compareMode == 3u) {
            return half4(sampleRGBNeutralCubicH(inColor, uv), centerRGBA.a);
        }
        float splitRatio = clamp(u.splitX, 0.1f, 0.9f);
        float invWidth = 1.0f / max(1.0f, float(inColor.get_width()));
        float invHeight = 1.0f / max(1.0f, float(inColor.get_height()));
        if (u.compareMode == 1u) {
            if (abs(uv.x - splitRatio) <= max(0.0022f, invWidth * 1.5f)) {
                return half4(half(0.25h), half(0.96h), half(0.98h), half(1.0h));
            }
            if (uv.x < splitRatio) {
                return centerRGBA;
            }
        }

        float2 dx = float2(invWidth, 0.0f);
        float2 dy = float2(0.0f, invHeight);
        float2 dDiagA = float2(invWidth * 1.35f, invHeight * 1.35f);
        float2 dDiagB = float2(invWidth * 1.35f, -invHeight * 1.35f);

        half yC = rgbLumaH(centerRGBA.rgb);
        half yN = rgbLumaH(inColor.sample(linearSampler, uv - dy).rgb);
        half yS = rgbLumaH(inColor.sample(linearSampler, uv + dy).rgb);
        half yW = rgbLumaH(inColor.sample(linearSampler, uv - dx).rgb);
        half yE = rgbLumaH(inColor.sample(linearSampler, uv + dx).rgb);
        half d0 = rgbLumaH(inColor.sample(linearSampler, uv - dDiagA).rgb);
        half d1 = rgbLumaH(inColor.sample(linearSampler, uv + dDiagA).rgb);
        half d2 = rgbLumaH(inColor.sample(linearSampler, uv - dDiagB).rgb);
        half d3 = rgbLumaH(inColor.sample(linearSampler, uv + dDiagB).rgb);

        half yOut = computeEnhancedLumaFastH(yC, yN, yS, yW, yE, d0, d1, d2, d3, u);
        half3 finalRGB = clamp(centerRGBA.rgb + half3(yOut - yC), half(0.0h), half(1.0h));
        return half4(finalRGB, centerRGBA.a);
    }

    fragment half4 displayFlowWarpYUVFragment(
        QuadVaryings in [[stage_in]],
        texture2d<half, access::sample> inPrevY [[texture(0)]],
        texture2d<half, access::sample> inPrevUV [[texture(1)]],
        texture2d<half, access::sample> inCurrY [[texture(2)]],
        texture2d<half, access::sample> inCurrUV [[texture(3)]],
        texture2d<float, access::sample> inForwardFlow [[texture(4)]],
        texture2d<float, access::sample> inBackwardFlow [[texture(5)]],
        constant FlowWarpUniforms& u [[buffer(0)]]
    ) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        constexpr sampler nearestSampler(address::clamp_to_edge, filter::nearest);
        float2 uv = in.uv;
        float t = clamp(u.phase, 0.0f, 1.0f);

        half nearestY = (t < 0.5f)
            ? toUnitLumaH(inPrevY.sample(linearSampler, uv).r, u.isVideoRange)
            : toUnitLumaH(inCurrY.sample(linearSampler, uv).r, u.isVideoRange);
        half2 nearestUV = (t < 0.5f)
            ? inPrevUV.sample(linearSampler, uv).rg
            : inCurrUV.sample(linearSampler, uv).rg;

        if (u.compareMode == 2u || u.isSceneCut != 0u) {
            return half4(yuvSampleToRGBH(nearestY, nearestUV, u.isVideoRange, u.isBT601), half(1.0h));
        }
        float invWidth = 1.0f / max(1.0f, float(inCurrY.get_width()));
        float invHeight = 1.0f / max(1.0f, float(inCurrY.get_height()));
        float splitRatio = clamp(u.splitX, 0.1f, 0.9f);
        if (u.compareMode == 1u) {
            if (abs(uv.x - splitRatio) <= max(0.0022f, invWidth * 1.5f)) {
                return half4(half(0.25h), half(0.96h), half(0.98h), half(1.0h));
            }
            if (uv.x < splitRatio) {
                return half4(yuvSampleToRGBH(nearestY, nearestUV, u.isVideoRange, u.isBT601), half(1.0h));
            }
        }

        half rawPrevCenter = toUnitLumaH(inPrevY.sample(linearSampler, uv).r, u.isVideoRange);
        half rawCurrCenter = toUnitLumaH(inCurrY.sample(linearSampler, uv).r, u.isVideoRange);
        float staticDiff = abs(float(rawPrevCenter) - float(rawCurrCenter));

        float2 flowScale = float2(u.flowScaleX, u.flowScaleY);
        float2 flowStep = float2(u.flowTexelX, u.flowTexelY);
        float2 f0 = inForwardFlow.sample(linearSampler, uv).rg * flowScale;
        float2 b0 = inBackwardFlow.sample(linearSampler, uv).rg * flowScale;
        if (!isfinite(f0.x) || !isfinite(f0.y)) { f0 = float2(0.0f); }
        if (!isfinite(b0.x) || !isfinite(b0.y)) { b0 = float2(0.0f); }

        // 测量局部光流离散梯度：识别人物轮廓或前背景交界，防止线性插值光流拉伸撕裂边缘
        float2 fC_n = inForwardFlow.sample(nearestSampler, uv).rg * flowScale;
        float2 fL_n = inForwardFlow.sample(nearestSampler, clamp(uv - float2(flowStep.x, 0.0f), float2(0.0f), float2(1.0f))).rg * flowScale;
        float2 fR_n = inForwardFlow.sample(nearestSampler, clamp(uv + float2(flowStep.x, 0.0f), float2(0.0f), float2(1.0f))).rg * flowScale;
        float2 fU_n = inForwardFlow.sample(nearestSampler, clamp(uv - float2(0.0f, flowStep.y), float2(0.0f), float2(1.0f))).rg * flowScale;
        float2 fD_n = inForwardFlow.sample(nearestSampler, clamp(uv + float2(0.0f, flowStep.y), float2(0.0f), float2(1.0f))).rg * flowScale;
        if (!isfinite(fC_n.x) || !isfinite(fC_n.y)) { fC_n = f0; }
        if (!isfinite(fL_n.x) || !isfinite(fL_n.y)) { fL_n = fC_n; }
        if (!isfinite(fR_n.x) || !isfinite(fR_n.y)) { fR_n = fC_n; }
        if (!isfinite(fU_n.x) || !isfinite(fU_n.y)) { fU_n = fC_n; }
        if (!isfinite(fD_n.x) || !isfinite(fD_n.y)) { fD_n = fC_n; }
        float flowGrad = length(fR_n - fL_n) + length(fD_n - fU_n);

        float2 uv0Rough = clamp(uv - t * f0, float2(0.0f), float2(1.0f));
        float2 uv1Rough = clamp(uv - (1.0f - t) * b0, float2(0.0f), float2(1.0f));
        float2 fRef = inForwardFlow.sample(linearSampler, uv0Rough).rg * flowScale;
        float2 bRef = inBackwardFlow.sample(linearSampler, uv1Rough).rg * flowScale;
        if (!isfinite(fRef.x) || !isfinite(fRef.y)) { fRef = f0; }
        if (!isfinite(bRef.x) || !isfinite(bRef.y)) { bRef = b0; }

        float2 bestFlow = 0.5f * (fRef - bRef);
        float fbErr = length(fRef + bRef);

        float2 bestUV0Raw = uv - t * bestFlow;
        float2 bestUV1Raw = uv + (1.0f - t) * bestFlow;
        float2 bestUV0 = clamp(bestUV0Raw, float2(0.0f), float2(1.0f));
        float2 bestUV1 = clamp(bestUV1Raw, float2(0.0f), float2(1.0f));
        half bestY0 = toUnitLumaH(inPrevY.sample(linearSampler, bestUV0).r, u.isVideoRange);
        half bestY1 = toUnitLumaH(inCurrY.sample(linearSampler, bestUV1).r, u.isVideoRange);
        float bestDiff = abs(float(bestY0) - float(bestY1));

        // 离散边界矢量锐选（仅在光流边缘/高光度差/一致性异常处触发，且显式候选静态零矢量消除人物边缘晕影）
        if (flowGrad >= 0.0025f || bestDiff > 0.022f || fbErr > 0.003f) {
            float2 offsets[5] = {
                float2(0.0f, 0.0f),
                float2(-flowStep.x, 0.0f),
                float2( flowStep.x, 0.0f),
                float2(0.0f, -flowStep.y),
                float2(0.0f,  flowStep.y)
            };
            for (int k = 0; k < 6; ++k) {
                float2 candFlow;
                float candFBErr;
                if (k == 5) {
                    candFlow = float2(0.0f);
                    candFBErr = 0.0f;
                } else {
                    float2 nUV = clamp(uv + offsets[k], float2(0.0f), float2(1.0f));
                    float2 fn = inForwardFlow.sample(nearestSampler, nUV).rg * flowScale;
                    float2 bn = inBackwardFlow.sample(nearestSampler, nUV).rg * flowScale;
                    if (!isfinite(fn.x) || !isfinite(fn.y)) { continue; }
                    if (!isfinite(bn.x) || !isfinite(bn.y)) { bn = -fn; }
                    candFlow = 0.5f * (fn - bn);
                    candFBErr = length(fn + bn);
                }
                if (length(candFlow) > 0.14f) { continue; }
                float2 cuv0Raw = uv - t * candFlow;
                float2 cuv1Raw = uv + (1.0f - t) * candFlow;
                float2 cuv0 = clamp(cuv0Raw, float2(0.0f), float2(1.0f));
                float2 cuv1 = clamp(cuv1Raw, float2(0.0f), float2(1.0f));
                half cy0 = toUnitLumaH(inPrevY.sample(linearSampler, cuv0).r, u.isVideoRange);
                half cy1 = toUnitLumaH(inCurrY.sample(linearSampler, cuv1).r, u.isVideoRange);
                float candDiff = abs(float(cy0) - float(cy1));
                if (candDiff + 0.003f < bestDiff) {
                    bestDiff = candDiff;
                    bestFlow = candFlow;
                    bestUV0Raw = cuv0Raw;
                    bestUV1Raw = cuv1Raw;
                    bestUV0 = cuv0;
                    bestUV1 = cuv1;
                    bestY0 = cy0;
                    bestY1 = cy1;
                    fbErr = candFBErr;
                }
            }
        }

        // 静态背景零模糊保护：前景运动掠过导致误差高于原地静态差时，直接无损直出静态原始像素
        if (staticDiff < 0.018f && bestDiff > 0.024f) {
            return half4(yuvSampleToRGBH(nearestY, nearestUV, u.isVideoRange, u.isBT601), half(1.0h));
        }

        float flowMag = length(bestFlow);
        if (flowMag < 0.00025f) {
            return half4(yuvSampleToRGBH(nearestY, nearestUV, u.isVideoRange, u.isBT601), half(1.0h));
        }
        // 转场/极端运动保护：避免整帧撕裂重影，直接输出最近原生高分辨率参考帧
        if (flowMag > 0.14f || (fbErr > 0.025f && bestDiff > 0.08f)) {
            return half4(yuvSampleToRGBH(nearestY, nearestUV, u.isVideoRange, u.isBT601), half(1.0h));
        }

        bool oob0 = (bestUV0Raw.x < 0.0f || bestUV0Raw.x > 1.0f || bestUV0Raw.y < 0.0f || bestUV0Raw.y > 1.0f);
        bool oob1 = (bestUV1Raw.x < 0.0f || bestUV1Raw.x > 1.0f || bestUV1Raw.y < 0.0f || bestUV1Raw.y > 1.0f);
        float2 uv0 = bestUV0;
        float2 uv1 = bestUV1;
        half y0 = bestY0;
        half y1 = bestY1;
        half2 c0 = inPrevUV.sample(linearSampler, uv0).rg;
        half2 c1 = inCurrUV.sample(linearSampler, uv1).rg;

        // 严格防人物虚影：将遮挡判定收紧至像素级尺度，遮挡区硬切换至单帧清晰像素（禁止 50/50 叠影）
        float occConf = smoothstep(0.0025f, 0.0075f, fbErr) * 0.80f + smoothstep(0.022f, 0.055f, bestDiff);
        if (bestDiff > 0.055f || fbErr > 0.0075f) {
            occConf = 1.0f;
        }
        occConf = clamp(occConf, 0.0f, 1.0f);

        float w1 = t;
        if (oob0 && !oob1) {
            w1 = 1.0f;
        } else if (oob1 && !oob0) {
            w1 = 0.0f;
        } else {
            float hardPick = (t < 0.5f) ? 0.0f : 1.0f;
            w1 = mix(t, hardPick, occConf);
        }

        half hw1 = half(w1);
        half hw0 = half(1.0h) - hw1;
        half yWarp = y0 * hw0 + y1 * hw1;
        half2 cWarp = c0 * hw0 + c1 * hw1;

        if (u.deblurStrength > 0.001f || u.casStrength > 0.001f || u.lineDarken > 0.001f || u.clarityStrength > 0.001f) {
            float2 dx = float2(invWidth, 0.0f);
            float2 dy = float2(0.0f, invHeight);
            half yN = toUnitLumaH(inPrevY.sample(linearSampler, clamp(uv0 - dy, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw0
                + toUnitLumaH(inCurrY.sample(linearSampler, clamp(uv1 - dy, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw1;
            half yS = toUnitLumaH(inPrevY.sample(linearSampler, clamp(uv0 + dy, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw0
                + toUnitLumaH(inCurrY.sample(linearSampler, clamp(uv1 + dy, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw1;
            half yW = toUnitLumaH(inPrevY.sample(linearSampler, clamp(uv0 - dx, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw0
                + toUnitLumaH(inCurrY.sample(linearSampler, clamp(uv1 - dx, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw1;
            half yE = toUnitLumaH(inPrevY.sample(linearSampler, clamp(uv0 + dx, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw0
                + toUnitLumaH(inCurrY.sample(linearSampler, clamp(uv1 + dx, float2(0.0f), float2(1.0f))).r, u.isVideoRange) * hw1;

            yWarp = computeEnhancedLumaParamsH(
                yWarp, yN, yS, yW, yE, yN, yS, yW, yE,
                u.deblurStrength, u.casStrength, u.lineDarken, u.clarityStrength, u.noiseDeadzone
            );
        }

        return half4(yuvSampleToRGBH(yWarp, cWarp, u.isVideoRange, u.isBT601), half(1.0h));
    }

    kernel void enhanceLuma(
        texture2d<half, access::sample> inY [[texture(0)]],
        texture2d<half, access::write> outY [[texture(1)]],
        constant EnhanceUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = outY.get_width();
        uint height = outY.get_height();
        if (gid.x >= width || gid.y >= height) {
            return;
        }
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float invW = 1.0f / max(1.0f, float(inY.get_width()));
        float invH = 1.0f / max(1.0f, float(inY.get_height()));
        float2 uv = (float2(gid) + 0.5f) * float2(invW, invH);
        half rawCenter = inY.sample(linearSampler, uv).r;

        if (u.compareMode == 2u) {
            outY.write(half4(rawCenter, 0.0h, 0.0h, 1.0h), gid);
            return;
        }
        if (u.compareMode == 1u) {
            int splitPixelX = int(float(width) * clamp(u.splitX, 0.1f, 0.9f));
            if (abs(int(gid.x) - splitPixelX) <= 1) {
                outY.write(half4(fromUnitLumaH(0.96h, u.isVideoRange), 0.0h, 0.0h, 1.0h), gid);
                return;
            }
            if (int(gid.x) < splitPixelX) {
                outY.write(half4(rawCenter, 0.0h, 0.0h, 1.0h), gid);
                return;
            }
        }

        float2 dx = float2(invW, 0.0f);
        float2 dy = float2(0.0f, invH);
        float2 dDiagA = float2(invW * 1.35f, invH * 1.35f);
        float2 dDiagB = float2(invW * 1.35f, -invH * 1.35f);

        half yOut = computeEnhancedLumaFastH(
            toUnitLumaH(rawCenter, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv - dy).r, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv + dy).r, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv - dx).r, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv + dx).r, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv - dDiagA).r, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv + dDiagA).r, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv - dDiagB).r, u.isVideoRange),
            toUnitLumaH(inY.sample(linearSampler, uv + dDiagB).r, u.isVideoRange),
            u
        );
        outY.write(half4(fromUnitLumaH(yOut, u.isVideoRange), 0.0h, 0.0h, 1.0h), gid);
    }

    kernel void copyChroma(
        texture2d<half, access::read> inUV [[texture(0)]],
        texture2d<half, access::write> outUV [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= outUV.get_width() || gid.y >= outUV.get_height()) {
            return;
        }
        outUV.write(inUV.read(gid), gid);
    }

    kernel void enhanceBGRA(
        texture2d<half, access::sample> inColor [[texture(0)]],
        texture2d<half, access::write> outColor [[texture(1)]],
        constant EnhanceUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = outColor.get_width();
        uint height = outColor.get_height();
        if (gid.x >= width || gid.y >= height) {
            return;
        }
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float invW = 1.0f / max(1.0f, float(inColor.get_width()));
        float invH = 1.0f / max(1.0f, float(inColor.get_height()));
        float2 uv = (float2(gid) + 0.5f) * float2(invW, invH);
        half4 centerRGBA = inColor.sample(linearSampler, uv);

        if (u.compareMode == 2u) {
            outColor.write(centerRGBA, gid);
            return;
        }
        if (u.compareMode == 1u) {
            int splitPixelX = int(float(width) * clamp(u.splitX, 0.1f, 0.9f));
            if (abs(int(gid.x) - splitPixelX) <= 1) {
                outColor.write(half4(0.95h, 0.96h, 0.25h, 1.0h), gid);
                return;
            }
            if (int(gid.x) < splitPixelX) {
                outColor.write(centerRGBA, gid);
                return;
            }
        }

        float2 dx = float2(invW, 0.0f);
        float2 dy = float2(0.0f, invH);
        float2 dDiagA = float2(invW * 1.35f, invH * 1.35f);
        float2 dDiagB = float2(invW * 1.35f, -invH * 1.35f);

        half yC = rgbLumaH(centerRGBA.rgb);
        half yOut = computeEnhancedLumaFastH(
            yC,
            rgbLumaH(inColor.sample(linearSampler, uv - dy).rgb),
            rgbLumaH(inColor.sample(linearSampler, uv + dy).rgb),
            rgbLumaH(inColor.sample(linearSampler, uv - dx).rgb),
            rgbLumaH(inColor.sample(linearSampler, uv + dx).rgb),
            rgbLumaH(inColor.sample(linearSampler, uv - dDiagA).rgb),
            rgbLumaH(inColor.sample(linearSampler, uv + dDiagA).rgb),
            rgbLumaH(inColor.sample(linearSampler, uv - dDiagB).rgb),
            rgbLumaH(inColor.sample(linearSampler, uv + dDiagB).rgb),
            u
        );
        half3 finalRGB = clamp(centerRGBA.rgb + half3(yOut - yC), half(0.0h), half(1.0h));
        outColor.write(half4(finalRGB, centerRGBA.a), gid);
    }

    kernel void yuvToBGRAClean(
        texture2d<half, access::read> inY [[texture(0)]],
        texture2d<half, access::sample> inUV [[texture(1)]],
        texture2d<half, access::write> outColor [[texture(2)]],
        constant EnhanceUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= outColor.get_width() || gid.y >= outColor.get_height()) {
            return;
        }
        constexpr sampler chromaSampler(address::clamp_to_edge, filter::linear);
        half yUnit = toUnitLumaH(inY.read(gid).r, u.isVideoRange);
        float2 normCoord = (float2(gid) + 0.5f) / float2(float(outColor.get_width()), float(outColor.get_height()));
        half2 uvRaw = inUV.sample(chromaSampler, normCoord).rg;
        half3 rgb = yuvSampleToRGBH(yUnit, uvRaw, u.isVideoRange, u.isBT601);
        outColor.write(half4(rgb, 1.0h), gid);
    }

    inline float catmullRomWeight(float x) {
        float ax = abs(x);
        if (ax <= 1.0f) {
            return (1.5f * ax - 2.5f) * ax * ax + 1.0f;
        }
        if (ax < 2.0f) {
            return ((-0.5f * ax + 2.5f) * ax - 4.0f) * ax + 2.0f;
        }
        return 0.0f;
    }

    kernel void bicubicUpscaleBGRA(
        texture2d<float, access::read> inColor [[texture(0)]],
        texture2d<float, access::write> outColor [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint outW = outColor.get_width();
        uint outH = outColor.get_height();
        if (gid.x >= outW || gid.y >= outH) {
            return;
        }
        int inW = int(inColor.get_width());
        int inH = int(inColor.get_height());
        float srcX = (float(gid.x) + 0.5f) * (float(inW) / float(outW)) - 0.5f;
        float srcY = (float(gid.y) + 0.5f) * (float(inH) / float(outH)) - 0.5f;
        int ix = int(floor(srcX));
        int iy = int(floor(srcY));
        float fx = srcX - float(ix);
        float fy = srcY - float(iy);

        float3 accum = float3(0.0f);
        float weightSum = 0.0f;
        for (int dy = -1; dy <= 2; dy++) {
            float wy = catmullRomWeight(float(dy) - fy);
            int sy = clamp(iy + dy, 0, inH - 1);
            for (int dx = -1; dx <= 2; dx++) {
                float wx = catmullRomWeight(float(dx) - fx);
                float w = wx * wy;
                int sx = clamp(ix + dx, 0, inW - 1);
                accum += inColor.read(uint2(sx, sy)).rgb * w;
                weightSum += w;
            }
        }
        float3 outRGB = clamp(accum / max(weightSum, 0.0001f), 0.0f, 1.0f);
        outColor.write(float4(outRGB, 1.0f), gid);
    }
    """

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        if let dev {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.textureCache = cache
            do {
                let library = try dev.makeLibrary(source: Self.shaderSource, options: nil)
                if let fn = library.makeFunction(name: "enhanceLuma") {
                    self.enhanceLumaPipeline = try dev.makeComputePipelineState(function: fn)
                }
                if let fn = library.makeFunction(name: "copyChroma") {
                    self.copyChromaPipeline = try dev.makeComputePipelineState(function: fn)
                }
                if let fn = library.makeFunction(name: "enhanceBGRA") {
                    self.enhanceBGRAPipeline = try dev.makeComputePipelineState(function: fn)
                }
                if let fn = library.makeFunction(name: "yuvToBGRAClean") {
                    self.yuvToBGRAPipeline = try dev.makeComputePipelineState(function: fn)
                }
                if let fn = library.makeFunction(name: "bicubicUpscaleBGRA") {
                    self.bicubicBGRAPipeline = try dev.makeComputePipelineState(function: fn)
                }

                if let vertexFn = library.makeFunction(name: "fullscreenQuadVertex") {
                    if let yuvFrag = library.makeFunction(name: "displayEnhanceYUVFragment") {
                        let desc = MTLRenderPipelineDescriptor()
                        desc.vertexFunction = vertexFn
                        desc.fragmentFunction = yuvFrag
                        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                        self.displayYUVRenderPipeline = try dev.makeRenderPipelineState(descriptor: desc)
                    }
                    if let bgraFrag = library.makeFunction(name: "displayEnhanceBGRAFragment") {
                        let desc = MTLRenderPipelineDescriptor()
                        desc.vertexFunction = vertexFn
                        desc.fragmentFunction = bgraFrag
                        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                        self.displayBGRARenderPipeline = try dev.makeRenderPipelineState(descriptor: desc)
                    }
                    if let warpFrag = library.makeFunction(name: "displayFlowWarpYUVFragment") {
                        let desc = MTLRenderPipelineDescriptor()
                        desc.vertexFunction = vertexFn
                        desc.fragmentFunction = warpFrag
                        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                        self.displayFlowWarpYUVRenderPipeline = try dev.makeRenderPipelineState(descriptor: desc)
                    }
                }
            } catch {
                self.shaderInitError = error.localizedDescription
                self.enhanceLumaPipeline = nil
                self.copyChromaPipeline = nil
                self.enhanceBGRAPipeline = nil
                self.yuvToBGRAPipeline = nil
                self.bicubicBGRAPipeline = nil
                self.displayYUVRenderPipeline = nil
                self.displayBGRARenderPipeline = nil
                self.displayFlowWarpYUVRenderPipeline = nil
            }
        }
    }

    func reset() {
        outputPool = nil
        outputPoolSignature = ""
#if canImport(MetalFX) && !targetEnvironment(simulator)
        spatialScaler = nil
#endif
        scalerInputTexture = nil
        scalerOutputTexture = nil
        scalerSignature = ""
        isUsingHardwareMetalFX = false
        activePipelineLabel = "关闭"
        averageProcessMs = 0
        enhancedFrameCount = 0
        gpuTimingTracker.reset()
        inFlightCounter.reset()
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    /// 计算将原始视频帧铺满或等比嵌入 CAMetalLayer 的顶点缩放系数
    nonisolated static func aspectVertexScale(
        videoWidth: Int,
        videoHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int,
        aspectFill: Bool
    ) -> SIMD2<Float> {
        let vw = Float(max(1, videoWidth))
        let vh = Float(max(1, videoHeight))
        let dw = Float(max(1, drawableWidth))
        let dh = Float(max(1, drawableHeight))
        let videoAspect = vw / vh
        let viewAspect = dw / dh
        if aspectFill {
            if videoAspect > viewAspect {
                return SIMD2<Float>(videoAspect / viewAspect, 1.0)
            }
            return SIMD2<Float>(1.0, viewAspect / videoAspect)
        } else {
            if videoAspect > viewAspect {
                return SIMD2<Float>(1.0, viewAspect / videoAspect)
            }
            return SIMD2<Float>(videoAspect / viewAspect, 1.0)
        }
    }

    /// 判断原画模式下是否对降采样后的光流帧自动启用硬件 MetalFX 空间重建
    nonisolated static func shouldAutoMetalFXUpscaleOpticalFlow(
        preset: VideoEnhancementPreset,
        allowPassthrough: Bool,
        isDownsampledOpticalFlow: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        preset == .off
            && allowPassthrough
            && isDownsampledOpticalFlow
            && thermalState != .serious
            && thermalState != .critical
    }

    /// 针对光流降采样帧的轻量无光晕纹理恢复参数（零黑边、仅轻微补偿下采样细节）
    nonisolated static func opticalFlowDownsampleRestoreParameters() -> VideoEnhancementParameters {
        VideoEnhancementParameters(
            denoiseStrength: 0,
            denoiseThreshold: 0.028,
            casStrength: 0.38,
            lineDarken: 0.0,
            clarityStrength: 0.10,
            wantsSpatialUpscale: false,
            deblurStrength: 0.30,
            noiseDeadzone: 0.018
        )
    }

    nonisolated static func flowMetalPixelFormat(for pixelFormat: OSType) -> MTLPixelFormat? {
        switch pixelFormat {
        case kCVPixelFormatType_TwoComponent16Half:
            return .rg16Float
        case kCVPixelFormatType_TwoComponent32Float:
            return .rg32Float
        default:
            return nil
        }
    }

    /// 零拷贝原生全分辨率双向遮挡感知光流变形直绘：
    /// 使用 ANE 生成的低分辨率双向位移场直接在 GPU 采样前后两帧原始 4K YUV 纹理，零降采样模糊、零中间 4K 分配。
    func renderFlowWarpedToLayerStatus(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer,
        forwardFlow: CVPixelBuffer,
        backwardFlow: CVPixelBuffer,
        phase: Float,
        flowSignX: Float = 1.0,
        flowSignY: Float = 1.0,
        isNormalizedUV: Bool = false,
        on metalLayer: CAMetalLayer,
        preset: VideoEnhancementPreset,
        strength: VideoEnhancementStrength,
        aspectFill: Bool,
        compareMode: VideoEnhancementCompareMode = .off,
        outputFPS: Double = 120.0,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) -> MetalDirectRenderResult {
        guard let textureCache else {
            return .unavailable
        }
        guard let fwdMetalFmt = Self.flowMetalPixelFormat(for: CVPixelBufferGetPixelFormatType(forwardFlow)),
              let bwdMetalFmt = Self.flowMetalPixelFormat(for: CVPixelBufferGetPixelFormatType(backwardFlow)),
              let fwdTex = makeTexture(from: forwardFlow, pixelFormat: fwdMetalFmt, plane: 0, cache: textureCache),
              let bwdTex = makeTexture(from: backwardFlow, pixelFormat: bwdMetalFmt, plane: 0, cache: textureCache) else {
            return .unavailable
        }
        return renderFlowWarpedTexturesToLayerStatus(
            prevBuffer: prevBuffer,
            currBuffer: currBuffer,
            forwardFlowTexture: fwdTex,
            backwardFlowTexture: bwdTex,
            phase: phase,
            flowSignX: flowSignX,
            flowSignY: flowSignY,
            isNormalizedUV: isNormalizedUV,
            isSceneCut: false,
            pipelinePrefix: nil,
            on: metalLayer,
            preset: preset,
            strength: strength,
            aspectFill: aspectFill,
            compareMode: compareMode,
            outputFPS: outputFPS,
            thermalState: thermalState
        )
    }

    /// 原生全分辨率双向遮挡感知 GPU 光流变形直绘（直接消费 MetalPyramidOpticalFlowEngine 归一化 UV 位移纹理）
    func renderFlowWarpedToLayerStatus(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer,
        forwardFlowTexture: MTLTexture,
        backwardFlowTexture: MTLTexture,
        phase: Float,
        isSceneCut: Bool,
        on metalLayer: CAMetalLayer,
        preset: VideoEnhancementPreset,
        strength: VideoEnhancementStrength,
        aspectFill: Bool,
        compareMode: VideoEnhancementCompareMode = .off,
        outputFPS: Double = 120.0,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) -> MetalDirectRenderResult {
        renderFlowWarpedTexturesToLayerStatus(
            prevBuffer: prevBuffer,
            currBuffer: currBuffer,
            forwardFlowTexture: forwardFlowTexture,
            backwardFlowTexture: backwardFlowTexture,
            phase: phase,
            flowSignX: 1.0,
            flowSignY: 1.0,
            isNormalizedUV: true,
            isSceneCut: isSceneCut,
            pipelinePrefix: max(CVPixelBufferGetWidth(currBuffer), CVPixelBufferGetHeight(currBuffer)) >= 3000 ? "4K原生GPU光流变形" : "原生GPU光流变形",
            on: metalLayer,
            preset: preset,
            strength: strength,
            aspectFill: aspectFill,
            compareMode: compareMode,
            outputFPS: outputFPS,
            thermalState: thermalState
        )
    }

    private func renderFlowWarpedTexturesToLayerStatus(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer,
        forwardFlowTexture fwdTex: MTLTexture,
        backwardFlowTexture bwdTex: MTLTexture,
        phase: Float,
        flowSignX: Float,
        flowSignY: Float,
        isNormalizedUV: Bool,
        isSceneCut: Bool,
        pipelinePrefix: String?,
        on metalLayer: CAMetalLayer,
        preset: VideoEnhancementPreset,
        strength: VideoEnhancementStrength,
        aspectFill: Bool,
        compareMode: VideoEnhancementCompareMode,
        outputFPS: Double,
        thermalState: ProcessInfo.ThermalState
    ) -> MetalDirectRenderResult {
        _ = outputFPS
        _ = thermalState
        guard let commandQueue,
              let textureCache,
              let displayFlowWarpYUVRenderPipeline else {
            return .unavailable
        }

        let prevFmt = CVPixelBufferGetPixelFormatType(prevBuffer)
        let currFmt = CVPixelBufferGetPixelFormatType(currBuffer)
        let isPrev8Bit = (prevFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || prevFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isCurr8Bit = (currFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || currFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        guard isPrev8Bit, isCurr8Bit else {
            return .unavailable
        }

        let srcW = CVPixelBufferGetWidth(currBuffer)
        let srcH = CVPixelBufferGetHeight(currBuffer)
        let flowW = fwdTex.width
        let flowH = fwdTex.height
        guard srcW >= 2, srcH >= 2, flowW >= 2, flowH >= 2 else {
            return .unavailable
        }

        guard inFlightCounter.tryAcquire(maxInFlight: 3) else {
            return .skippedBusy
        }
        var didCommit = false
        defer {
            if !didCommit {
                inFlightCounter.release()
            }
        }

        guard let drawable = metalLayer.nextDrawable() else {
            return .skippedBusy
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return .unavailable
        }

        guard let prevY = makeTexture(from: prevBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
              let prevUV = makeTexture(from: prevBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache),
              let currY = makeTexture(from: currBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
              let currUV = makeTexture(from: currBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache) else {
            return .unavailable
        }

        let params = (preset != .off && compareMode != .original)
            ? VideoEnhancementPlanner.parameters(for: preset, strength: strength)
            : VideoEnhancementPlanner.parameters(for: .off, strength: strength)
        let isVideoRange: UInt32 = (currFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 0 : 1
        let isBT601: UInt32 = Self.isBT601Matrix(on: currBuffer) ? 1 : 0
        let texelW = 1.0 / Float(max(1, flowW))
        let texelH = 1.0 / Float(max(1, flowH))
        let scaleX = flowSignX * (isNormalizedUV ? 1.0 : texelW)
        let scaleY = flowSignY * (isNormalizedUV ? 1.0 : texelH)
        var warpUniforms = MetalFlowWarpUniforms(
            phase: max(0.0, min(1.0, phase)),
            flowScaleX: scaleX,
            flowScaleY: scaleY,
            flowTexelX: texelW,
            flowTexelY: texelH,
            deblurStrength: params.deblurStrength,
            casStrength: params.casStrength,
            lineDarken: params.lineDarken,
            clarityStrength: params.clarityStrength,
            noiseDeadzone: params.noiseDeadzone,
            isVideoRange: isVideoRange,
            isBT601: isBT601,
            compareMode: compareMode.uniformValue,
            splitX: 0.5,
            isSceneCut: isSceneCut ? 1 : 0
        )

        let scaleVec = Self.aspectVertexScale(
            videoWidth: srcW,
            videoHeight: srcH,
            drawableWidth: drawable.texture.width,
            drawableHeight: drawable.texture.height,
            aspectFill: aspectFill
        )
        var vertexUniforms = MetalDisplayVertexUniforms(scaleX: scaleVec.x, scaleY: scaleVec.y)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return .unavailable
        }

        renderEncoder.setRenderPipelineState(displayFlowWarpYUVRenderPipeline)
        renderEncoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<MetalDisplayVertexUniforms>.size, index: 0)
        renderEncoder.setFragmentTexture(prevY, index: 0)
        renderEncoder.setFragmentTexture(prevUV, index: 1)
        renderEncoder.setFragmentTexture(currY, index: 2)
        renderEncoder.setFragmentTexture(currUV, index: 3)
        renderEncoder.setFragmentTexture(fwdTex, index: 4)
        renderEncoder.setFragmentTexture(bwdTex, index: 5)
        renderEncoder.setFragmentBytes(&warpUniforms, length: MemoryLayout<MetalFlowWarpUniforms>.size, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        let commitHost = CACurrentMediaTime()
        let tracker = gpuTimingTracker
        let counter = inFlightCounter
        commandBuffer.addCompletedHandler { cb in
            counter.release()
            tracker.record(gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime, fallbackStart: commitHost)
        }
        commandBuffer.present(drawable)
        didCommit = true
        commandBuffer.commit()

        let defaultPrefix = max(srcW, srcH) >= 3000 ? "4K原生光流变形" : "原生光流变形"
        let resolvedPrefix = pipelinePrefix ?? defaultPrefix
        activePipelineLabel = preset != .off && compareMode != .original
            ? "\(resolvedPrefix)·\(preset.rawValue) \(srcW)×\(srcH)"
            : "\(resolvedPrefix) \(srcW)×\(srcH)"
        enhancedFrameCount += 1
        let snapMs = gpuTimingTracker.snapshotAverageMs()
        if snapMs > 0 {
            averageProcessMs = snapMs
        }
        if enhancedFrameCount % 60 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        return .rendered
    }

    /// 离屏渲染 Flow-Warp 着色器并返回 BGRA8 像素字节（专用于 XCTest 像素级真实运动插值精度回归）
    func renderFlowWarpedOffscreenForTesting(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer,
        forwardFlowTexture: MTLTexture,
        backwardFlowTexture: MTLTexture,
        phase: Float,
        isSceneCut: Bool = false
    ) -> [UInt8]? {
        guard let device,
              let commandQueue,
              let textureCache,
              let displayFlowWarpYUVRenderPipeline else {
            return nil
        }
        let srcW = CVPixelBufferGetWidth(currBuffer)
        let srcH = CVPixelBufferGetHeight(currBuffer)
        let flowW = forwardFlowTexture.width
        let flowH = forwardFlowTexture.height
        guard srcW >= 2, srcH >= 2, flowW >= 2, flowH >= 2 else { return nil }

        let currFmt = CVPixelBufferGetPixelFormatType(currBuffer)
        let isVideoRange: UInt32 = (currFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 0 : 1
        let isBT601: UInt32 = Self.isBT601Matrix(on: currBuffer) ? 1 : 0

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: srcW,
            height: srcH,
            mipmapped: false
        )
        outDesc.usage = [.renderTarget, .shaderRead]
        outDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: outDesc),
              let prevY = makeTexture(from: prevBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
              let prevUV = makeTexture(from: prevBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache),
              let currY = makeTexture(from: currBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
              let currUV = makeTexture(from: currBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        var warpUniforms = MetalFlowWarpUniforms(
            phase: max(0.0, min(1.0, phase)),
            flowScaleX: 1.0,
            flowScaleY: 1.0,
            flowTexelX: 1.0 / Float(max(1, flowW)),
            flowTexelY: 1.0 / Float(max(1, flowH)),
            deblurStrength: 0,
            casStrength: 0,
            lineDarken: 0,
            clarityStrength: 0,
            noiseDeadzone: 0,
            isVideoRange: isVideoRange,
            isBT601: isBT601,
            compareMode: 0,
            splitX: 0.5,
            isSceneCut: isSceneCut ? 1 : 0
        )
        var vertexUniforms = MetalDisplayVertexUniforms(scaleX: 1.0, scaleY: 1.0)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = outTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return nil
        }
        renderEncoder.setRenderPipelineState(displayFlowWarpYUVRenderPipeline)
        renderEncoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<MetalDisplayVertexUniforms>.size, index: 0)
        renderEncoder.setFragmentTexture(prevY, index: 0)
        renderEncoder.setFragmentTexture(prevUV, index: 1)
        renderEncoder.setFragmentTexture(currY, index: 2)
        renderEncoder.setFragmentTexture(currUV, index: 3)
        renderEncoder.setFragmentTexture(forwardFlowTexture, index: 4)
        renderEncoder.setFragmentTexture(backwardFlowTexture, index: 5)
        renderEncoder.setFragmentBytes(&warpUniforms, length: MemoryLayout<MetalFlowWarpUniforms>.size, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = srcW * 4
        var result = [UInt8](repeating: 0, count: bytesPerRow * srcH)
        result.withUnsafeMutableBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                outTex.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, srcW, srcH), mipmapLevel: 0)
            }
        }
        return result
    }

    /// 零拷贝全异步 FP16 直绘路径：直接由 Fragment Shader 采样解码帧输出至 CAMetalLayer，消除 waitUntilCompleted 与中间像素池拷贝
    func renderToLayer(
        _ sourceBuffer: CVPixelBuffer,
        on metalLayer: CAMetalLayer,
        preset: VideoEnhancementPreset,
        strength: VideoEnhancementStrength,
        aspectFill: Bool,
        compareMode: VideoEnhancementCompareMode = .off,
        outputFPS: Double = 24.0,
        thermalState: ProcessInfo.ThermalState = .nominal,
        allowPassthrough: Bool = false,
        autoOpticalFlowUpscale: Bool = false
    ) -> Bool {
        renderToLayerStatus(
            sourceBuffer,
            on: metalLayer,
            preset: preset,
            strength: strength,
            aspectFill: aspectFill,
            compareMode: compareMode,
            outputFPS: outputFPS,
            thermalState: thermalState,
            allowPassthrough: allowPassthrough,
            autoOpticalFlowUpscale: autoOpticalFlowUpscale
        ) != .unavailable
    }

    /// 零拷贝全异步 FP16 直绘路径（带三缓冲并发背压状态，防止 120Hz + Liquid Glass 下 `nextDrawable()` 阻塞主线程）
    func renderToLayerStatus(
        _ sourceBuffer: CVPixelBuffer,
        on metalLayer: CAMetalLayer,
        preset: VideoEnhancementPreset,
        strength: VideoEnhancementStrength,
        aspectFill: Bool,
        compareMode: VideoEnhancementCompareMode = .off,
        outputFPS: Double = 24.0,
        thermalState: ProcessInfo.ThermalState = .nominal,
        allowPassthrough: Bool = false,
        autoOpticalFlowUpscale: Bool = false
    ) -> MetalDirectRenderResult {
        let isPassthroughDraw = allowPassthrough && (preset == .off || compareMode == .original)
        let useHighFPSNeutralCubic = isPassthroughDraw && preset == .off && compareMode != .original && outputFPS > 65.0
        let wantsAutoMetalFX = Self.shouldAutoMetalFXUpscaleOpticalFlow(
            preset: preset,
            allowPassthrough: allowPassthrough,
            isDownsampledOpticalFlow: autoOpticalFlowUpscale,
            thermalState: thermalState
        )
        guard isPassthroughDraw || (preset != .off && compareMode != .original) else {
            activePipelineLabel = compareMode == .original ? "原画对比" : "关闭"
            return .unavailable
        }
        guard let device,
              let commandQueue,
              let textureCache,
              let displayYUVRenderPipeline,
              let displayBGRARenderPipeline else {
            return .unavailable
        }

        let pixFmt = CVPixelBufferGetPixelFormatType(sourceBuffer)
        let is8BitBiPlanar = (pixFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isBGRA = (pixFmt == kCVPixelFormatType_32BGRA)
        guard is8BitBiPlanar || isBGRA else {
            return .unavailable
        }

        let srcW = CVPixelBufferGetWidth(sourceBuffer)
        let srcH = CVPixelBufferGetHeight(sourceBuffer)
        guard srcW >= 2, srcH >= 2 else { return .unavailable }

        guard inFlightCounter.tryAcquire(maxInFlight: 3) else {
            return .skippedBusy
        }
        var didCommit = false
        defer {
            if !didCommit {
                inFlightCounter.release()
            }
        }

        guard let drawable = metalLayer.nextDrawable() else {
            return .skippedBusy
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return .unavailable
        }

        let params = VideoEnhancementPlanner.parameters(for: preset, strength: strength)
        let isVideoRange: UInt32 = (pixFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 0 : 1
        let isBT601: UInt32 = Self.isBT601Matrix(on: sourceBuffer) ? 1 : 0
        let effectiveCompareUniform: UInt32 = useHighFPSNeutralCubic ? 3 : (isPassthroughDraw ? 2 : compareMode.uniformValue)
        var uniforms = makeUniforms(
            params: params,
            isVideoRange: isVideoRange,
            isBT601: isBT601,
            compareUniform: effectiveCompareUniform
        )

        let scaleVec = Self.aspectVertexScale(
            videoWidth: srcW,
            videoHeight: srcH,
            drawableWidth: drawable.texture.width,
            drawableHeight: drawable.texture.height,
            aspectFill: aspectFill
        )
        var vertexUniforms = MetalDisplayVertexUniforms(scaleX: scaleVec.x, scaleY: scaleVec.y)

        let upscaleBudget = VideoEnhancementPlanner.effectiveUpscaleBudget(
            outputFPS: outputFPS,
            thermalState: thermalState
        )

        var renderedBGRAInput: MTLTexture?
        var nextLabel = useHighFPSNeutralCubic
            ? "原画高刷直绘"
            : (isPassthroughDraw
                ? (preset == .off ? "原画直绘" : "原画对比直绘")
                : "\(preset.rawValue) 直绘")

        if !isPassthroughDraw,
           params.wantsSpatialUpscale,
           upscaleBudget.allowSpatialUpscale,
           let yuvToBGRAPipeline,
           let outDims = VideoEnhancementPlanner.recommendedUpscaleDimensions(
               inputWidth: srcW,
               inputHeight: srcH,
               maxLongSide: upscaleBudget.maxLongSide,
               maxShortSide: upscaleBudget.maxShortSide
           ) {
            ensureScalerResources(device: device, inW: srcW, inH: srcH, outW: outDims.width, outH: outDims.height)
            if let upscaledTex = scalerOutputTexture {
                let upscaleInputTex: MTLTexture?
                if is8BitBiPlanar {
                    if let preBGRATex = scalerInputTexture,
                       let yTex = makeTexture(from: sourceBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
                       let uvTex = makeTexture(from: sourceBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache),
                       let preEncoder = commandBuffer.makeComputeCommandEncoder() {
                        var preUniforms = makeUniforms(
                            params: params,
                            isVideoRange: isVideoRange,
                            isBT601: isBT601,
                            compareUniform: 0
                        )
                        preEncoder.setComputePipelineState(yuvToBGRAPipeline)
                        preEncoder.setTexture(yTex, index: 0)
                        preEncoder.setTexture(uvTex, index: 1)
                        preEncoder.setTexture(preBGRATex, index: 2)
                        preEncoder.setBytes(&preUniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
                        dispatch2D(encoder: preEncoder, pipeline: yuvToBGRAPipeline, width: srcW, height: srcH)
                        preEncoder.endEncoding()
                        upscaleInputTex = preBGRATex
                    } else {
                        upscaleInputTex = nil
                    }
                } else {
                    upscaleInputTex = makeTexture(from: sourceBuffer, pixelFormat: .bgra8Unorm, plane: 0, cache: textureCache)
                }

                if let upscaleInputTex {
                    var encodedScale = false
#if canImport(MetalFX) && !targetEnvironment(simulator)
                    if let spatialScaler, isUsingHardwareMetalFX {
                        spatialScaler.colorTexture = upscaleInputTex
                        spatialScaler.outputTexture = upscaledTex
                        spatialScaler.encode(commandBuffer: commandBuffer)
                        encodedScale = true
                    } else if let bicubicBGRAPipeline,
                              let upEncoder = commandBuffer.makeComputeCommandEncoder() {
                        upEncoder.setComputePipelineState(bicubicBGRAPipeline)
                        upEncoder.setTexture(upscaleInputTex, index: 0)
                        upEncoder.setTexture(upscaledTex, index: 1)
                        dispatch2D(encoder: upEncoder, pipeline: bicubicBGRAPipeline, width: outDims.width, height: outDims.height)
                        upEncoder.endEncoding()
                        encodedScale = true
                    }
#else
                    if let bicubicBGRAPipeline,
                       let upEncoder = commandBuffer.makeComputeCommandEncoder() {
                        upEncoder.setComputePipelineState(bicubicBGRAPipeline)
                        upEncoder.setTexture(upscaleInputTex, index: 0)
                        upEncoder.setTexture(upscaledTex, index: 1)
                        dispatch2D(encoder: upEncoder, pipeline: bicubicBGRAPipeline, width: outDims.width, height: outDims.height)
                        upEncoder.endEncoding()
                        encodedScale = true
                    }
#endif
                    if encodedScale {
                        renderedBGRAInput = upscaledTex
                        uniforms.isVideoRange = 0
                        let prefix = isUsingHardwareMetalFX ? "MetalFX直绘" : "超分直绘"
                        nextLabel = "\(prefix) \(srcW)×\(srcH)→\(outDims.width)×\(outDims.height)"
                    }
                }
            }
        } else if wantsAutoMetalFX,
                  let yuvToBGRAPipeline {
#if canImport(MetalFX) && !targetEnvironment(simulator)
            let autoMaxLong = (outputFPS > 105.0) ? 1920 : 2560
            let autoMaxShort = (outputFPS > 105.0) ? 1080 : 1440
            if let outDims = VideoEnhancementPlanner.recommendedUpscaleDimensions(
                inputWidth: srcW,
                inputHeight: srcH,
                maxLongSide: autoMaxLong,
                maxShortSide: autoMaxShort
            ) {
                ensureScalerResources(device: device, inW: srcW, inH: srcH, outW: outDims.width, outH: outDims.height)
                if let spatialScaler,
                   isUsingHardwareMetalFX,
                   let upscaledTex = scalerOutputTexture {
                    let upscaleInputTex: MTLTexture?
                    if is8BitBiPlanar {
                        if let preBGRATex = scalerInputTexture,
                           let yTex = makeTexture(from: sourceBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
                           let uvTex = makeTexture(from: sourceBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache),
                           let preEncoder = commandBuffer.makeComputeCommandEncoder() {
                            var preUniforms = makeUniforms(
                                params: params,
                                isVideoRange: isVideoRange,
                                isBT601: isBT601,
                                compareUniform: 0
                            )
                            preEncoder.setComputePipelineState(yuvToBGRAPipeline)
                            preEncoder.setTexture(yTex, index: 0)
                            preEncoder.setTexture(uvTex, index: 1)
                            preEncoder.setTexture(preBGRATex, index: 2)
                            preEncoder.setBytes(&preUniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
                            dispatch2D(encoder: preEncoder, pipeline: yuvToBGRAPipeline, width: srcW, height: srcH)
                            preEncoder.endEncoding()
                            upscaleInputTex = preBGRATex
                        } else {
                            upscaleInputTex = nil
                        }
                    } else {
                        upscaleInputTex = makeTexture(from: sourceBuffer, pixelFormat: .bgra8Unorm, plane: 0, cache: textureCache)
                    }

                    if let upscaleInputTex {
                        spatialScaler.colorTexture = upscaleInputTex
                        spatialScaler.outputTexture = upscaledTex
                        spatialScaler.encode(commandBuffer: commandBuffer)
                        renderedBGRAInput = upscaledTex
                        let restoreParams = Self.opticalFlowDownsampleRestoreParameters()
                        uniforms = makeUniforms(
                            params: restoreParams,
                            isVideoRange: 0,
                            isBT601: isBT601,
                            compareUniform: 0
                        )
                        nextLabel = "原画高刷·MetalFX \(srcW)×\(srcH)→\(outDims.width)×\(outDims.height)"
                    }
                }
            }
#endif
        }

        if renderedBGRAInput == nil, wantsAutoMetalFX, compareMode != .original {
            let restoreParams = Self.opticalFlowDownsampleRestoreParameters()
            uniforms = makeUniforms(
                params: restoreParams,
                isVideoRange: isVideoRange,
                isBT601: isBT601,
                compareUniform: 0
            )
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return .unavailable
        }

        if let bgraTex = renderedBGRAInput {
            renderEncoder.setRenderPipelineState(displayBGRARenderPipeline)
            renderEncoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<MetalDisplayVertexUniforms>.size, index: 0)
            renderEncoder.setFragmentTexture(bgraTex, index: 0)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else if is8BitBiPlanar,
                  let yTex = makeTexture(from: sourceBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
                  let uvTex = makeTexture(from: sourceBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache) {
            renderEncoder.setRenderPipelineState(displayYUVRenderPipeline)
            renderEncoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<MetalDisplayVertexUniforms>.size, index: 0)
            renderEncoder.setFragmentTexture(yTex, index: 0)
            renderEncoder.setFragmentTexture(uvTex, index: 1)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if wantsAutoMetalFX && compareMode != .original {
                nextLabel = "原画高刷·超清直绘 \(srcW)×\(srcH)"
            } else if useHighFPSNeutralCubic {
                nextLabel = "原画高刷直绘 \(srcW)×\(srcH)"
            } else if isPassthroughDraw {
                nextLabel = preset == .off ? "原画直绘 \(srcW)×\(srcH)" : "原画对比 \(srcW)×\(srcH)"
            } else if params.wantsSpatialUpscale && !upscaleBudget.allowSpatialUpscale {
                let tag = (thermalState == .serious || thermalState == .critical) ? "温控直绘" : "省电直绘"
                nextLabel = "\(tag) \(srcW)×\(srcH)"
            } else {
                nextLabel = "\(preset.rawValue)直绘 \(srcW)×\(srcH)"
            }
        } else if isBGRA,
                  let bgraTex = makeTexture(from: sourceBuffer, pixelFormat: .bgra8Unorm, plane: 0, cache: textureCache) {
            renderEncoder.setRenderPipelineState(displayBGRARenderPipeline)
            renderEncoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<MetalDisplayVertexUniforms>.size, index: 0)
            renderEncoder.setFragmentTexture(bgraTex, index: 0)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if wantsAutoMetalFX && compareMode != .original {
                nextLabel = "原画高刷·超清直绘 \(srcW)×\(srcH)"
            } else if useHighFPSNeutralCubic {
                nextLabel = "原画高刷直绘 \(srcW)×\(srcH)"
            } else if isPassthroughDraw {
                nextLabel = preset == .off ? "原画直绘 \(srcW)×\(srcH)" : "原画对比 \(srcW)×\(srcH)"
            } else {
                nextLabel = "\(preset.rawValue)直绘 \(srcW)×\(srcH)"
            }
        } else {
            renderEncoder.endEncoding()
            return .unavailable
        }

        renderEncoder.endEncoding()
        let commitHost = CACurrentMediaTime()
        let tracker = gpuTimingTracker
        let counter = inFlightCounter
        commandBuffer.addCompletedHandler { cb in
            counter.release()
            tracker.record(gpuStart: cb.gpuStartTime, gpuEnd: cb.gpuEndTime, fallbackStart: commitHost)
        }
        commandBuffer.present(drawable)
        didCommit = true
        commandBuffer.commit()

        activePipelineLabel = nextLabel
        enhancedFrameCount += 1
        let snapMs = gpuTimingTracker.snapshotAverageMs()
        if snapMs > 0 {
            averageProcessMs = snapMs
        }
        if enhancedFrameCount % 60 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        return .rendered
    }

    func process(
        _ sourceBuffer: CVPixelBuffer,
        preset: VideoEnhancementPreset,
        strength: VideoEnhancementStrength,
        isHDRContent: Bool,
        isDolbyVision: Bool,
        bypassForComparison: Bool = false,
        compareMode: VideoEnhancementCompareMode = .off,
        outputFPS: Double = 24.0,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) -> CVPixelBuffer {
        if bypassForComparison || compareMode == .original {
            activePipelineLabel = "原画对比"
            return sourceBuffer
        }
        guard preset != .off else {
            activePipelineLabel = "关闭"
            return sourceBuffer
        }
        if VideoEnhancementPlanner.shouldBypassForDolbyVision(isDolbyVision: isDolbyVision) {
            activePipelineLabel = "杜比视界直通"
            return sourceBuffer
        }
        guard let device,
              let commandQueue,
              let textureCache,
              let enhanceLumaPipeline,
              let copyChromaPipeline,
              let enhanceBGRAPipeline,
              let yuvToBGRAPipeline else {
            activePipelineLabel = "Metal不可用"
            return sourceBuffer
        }

        let startHost = CACurrentMediaTime()
        let params = VideoEnhancementPlanner.parameters(for: preset, strength: strength)
        let pixFmt = CVPixelBufferGetPixelFormatType(sourceBuffer)
        let srcW = CVPixelBufferGetWidth(sourceBuffer)
        let srcH = CVPixelBufferGetHeight(sourceBuffer)
        guard srcW >= 2, srcH >= 2 else { return sourceBuffer }

        let is10BitBiPlanar = (pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let is8BitBiPlanar = (pixFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isBiPlanarYUV = is8BitBiPlanar || is10BitBiPlanar
        let isBGRA = (pixFmt == kCVPixelFormatType_32BGRA)
        let isVideoRange: UInt32 = (pixFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) ? 0 : 1
        let isBT601: UInt32 = Self.isBT601Matrix(on: sourceBuffer) ? 1 : 0
        let compareUniform = compareMode.uniformValue

        let upscaleBudget = VideoEnhancementPlanner.effectiveUpscaleBudget(
            outputFPS: outputFPS,
            thermalState: thermalState
        )

        if params.wantsSpatialUpscale,
           upscaleBudget.allowSpatialUpscale,
           !isHDRContent,
           (is8BitBiPlanar || isBGRA),
           let outDims = VideoEnhancementPlanner.recommendedUpscaleDimensions(
               inputWidth: srcW,
               inputHeight: srcH,
               maxLongSide: upscaleBudget.maxLongSide,
               maxShortSide: upscaleBudget.maxShortSide
           ),
           let result = runSpatialUpscalePass(
               sourceBuffer: sourceBuffer,
               srcW: srcW,
               srcH: srcH,
               outW: outDims.width,
               outH: outDims.height,
               isYUV: is8BitBiPlanar,
               isVideoRange: isVideoRange,
               isBT601: isBT601,
               compareUniform: compareUniform,
               params: params,
               device: device,
               commandQueue: commandQueue,
               textureCache: textureCache,
               yuvToBGRAPipeline: yuvToBGRAPipeline,
               enhanceBGRAPipeline: enhanceBGRAPipeline
           ) {
            let prefix = isUsingHardwareMetalFX ? "MetalFX" : "Metal超分"
            activePipelineLabel = "\(prefix) \(srcW)×\(srcH)→\(outDims.width)×\(outDims.height)"
            recordTiming(startHost: startHost)
            return result
        }

        if isBiPlanarYUV,
           let result = runBiPlanarLumaPass(
               sourceBuffer: sourceBuffer,
               pixelFormat: pixFmt,
               srcW: srcW,
               srcH: srcH,
               is10Bit: is10BitBiPlanar,
               isVideoRange: isVideoRange,
               isBT601: isBT601,
               compareUniform: compareUniform,
               params: params,
               commandQueue: commandQueue,
               textureCache: textureCache,
               enhanceLumaPipeline: enhanceLumaPipeline,
               copyChromaPipeline: copyChromaPipeline
           ) {
            if params.wantsSpatialUpscale && !upscaleBudget.allowSpatialUpscale {
                let tag = (thermalState == .serious || thermalState == .critical) ? "温控直锐" : "超分·省电直锐"
                activePipelineLabel = "\(tag) \(srcW)×\(srcH)"
            } else {
                activePipelineLabel = "\(preset.rawValue) \(srcW)×\(srcH)"
            }
            recordTiming(startHost: startHost)
            return result
        }

        if isBGRA,
           let result = runBGRAPass(
               sourceBuffer: sourceBuffer,
               srcW: srcW,
               srcH: srcH,
               compareUniform: compareUniform,
               params: params,
               commandQueue: commandQueue,
               textureCache: textureCache,
               enhanceBGRAPipeline: enhanceBGRAPipeline
           ) {
            if params.wantsSpatialUpscale && !upscaleBudget.allowSpatialUpscale {
                let tag = (thermalState == .serious || thermalState == .critical) ? "温控直锐" : "超分·省电直锐"
                activePipelineLabel = "\(tag) \(srcW)×\(srcH)"
            } else {
                activePipelineLabel = "\(preset.rawValue) \(srcW)×\(srcH)"
            }
            recordTiming(startHost: startHost)
            return result
        }

        return sourceBuffer
    }

    private func recordTiming(startHost: CFTimeInterval) {
        let elapsedMs = max(0, (CACurrentMediaTime() - startHost) * 1000.0)
        enhancedFrameCount += 1
        if enhancedFrameCount == 1 {
            averageProcessMs = elapsedMs
        } else {
            averageProcessMs = averageProcessMs * 0.85 + elapsedMs * 0.15
        }
        if enhancedFrameCount % 60 == 0, let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    private func makeUniforms(
        params: VideoEnhancementParameters,
        isVideoRange: UInt32,
        isBT601: UInt32,
        compareUniform: UInt32
    ) -> MetalEnhanceUniforms {
        MetalEnhanceUniforms(
            deblurStrength: params.deblurStrength,
            casStrength: params.casStrength,
            lineDarken: params.lineDarken,
            clarityStrength: params.clarityStrength,
            noiseDeadzone: params.noiseDeadzone,
            isVideoRange: isVideoRange,
            isBT601: isBT601,
            compareMode: compareUniform,
            splitX: 0.5,
            padding: 0
        )
    }

    private func runSpatialUpscalePass(
        sourceBuffer: CVPixelBuffer,
        srcW: Int,
        srcH: Int,
        outW: Int,
        outH: Int,
        isYUV: Bool,
        isVideoRange: UInt32,
        isBT601: UInt32,
        compareUniform: UInt32,
        params: VideoEnhancementParameters,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        textureCache: CVMetalTextureCache,
        yuvToBGRAPipeline: MTLComputePipelineState,
        enhanceBGRAPipeline: MTLComputePipelineState
    ) -> CVPixelBuffer? {
        ensureScalerResources(device: device, inW: srcW, inH: srcH, outW: outW, outH: outH)
        guard let upscaledTex = scalerOutputTexture,
              let dstBuffer = allocateOutputBuffer(width: outW, height: outH, pixelFormat: kCVPixelFormatType_32BGRA),
              let dstTex = makeTexture(from: dstBuffer, pixelFormat: .bgra8Unorm, plane: 0, cache: textureCache),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let upscaleInputTex: MTLTexture
        if isYUV {
            guard let preBGRATex = scalerInputTexture,
                  let yTex = makeTexture(from: sourceBuffer, pixelFormat: .r8Unorm, plane: 0, cache: textureCache),
                  let uvTex = makeTexture(from: sourceBuffer, pixelFormat: .rg8Unorm, plane: 1, cache: textureCache),
                  let preEncoder = commandBuffer.makeComputeCommandEncoder() else {
                return nil
            }
            var preUniforms = makeUniforms(
                params: params,
                isVideoRange: isVideoRange,
                isBT601: isBT601,
                compareUniform: 0
            )
            preEncoder.setComputePipelineState(yuvToBGRAPipeline)
            preEncoder.setTexture(yTex, index: 0)
            preEncoder.setTexture(uvTex, index: 1)
            preEncoder.setTexture(preBGRATex, index: 2)
            preEncoder.setBytes(&preUniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
            dispatch2D(encoder: preEncoder, pipeline: yuvToBGRAPipeline, width: srcW, height: srcH)
            preEncoder.endEncoding()
            upscaleInputTex = preBGRATex
        } else {
            guard let bgraTex = makeTexture(from: sourceBuffer, pixelFormat: .bgra8Unorm, plane: 0, cache: textureCache) else {
                return nil
            }
            upscaleInputTex = bgraTex
        }

#if canImport(MetalFX) && !targetEnvironment(simulator)
        if let spatialScaler, isUsingHardwareMetalFX {
            spatialScaler.colorTexture = upscaleInputTex
            spatialScaler.outputTexture = upscaledTex
            spatialScaler.encode(commandBuffer: commandBuffer)
        } else if let bicubicBGRAPipeline,
                  let upEncoder = commandBuffer.makeComputeCommandEncoder() {
            upEncoder.setComputePipelineState(bicubicBGRAPipeline)
            upEncoder.setTexture(upscaleInputTex, index: 0)
            upEncoder.setTexture(upscaledTex, index: 1)
            dispatch2D(encoder: upEncoder, pipeline: bicubicBGRAPipeline, width: outW, height: outH)
            upEncoder.endEncoding()
        } else {
            return nil
        }
#else
        if let bicubicBGRAPipeline,
           let upEncoder = commandBuffer.makeComputeCommandEncoder() {
            upEncoder.setComputePipelineState(bicubicBGRAPipeline)
            upEncoder.setTexture(upscaleInputTex, index: 0)
            upEncoder.setTexture(upscaledTex, index: 1)
            dispatch2D(encoder: upEncoder, pipeline: bicubicBGRAPipeline, width: outW, height: outH)
            upEncoder.endEncoding()
        } else {
            return nil
        }
#endif

        guard let finishEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        var finishUniforms = makeUniforms(
            params: params,
            isVideoRange: 0,
            isBT601: isBT601,
            compareUniform: compareUniform
        )
        finishEncoder.setComputePipelineState(enhanceBGRAPipeline)
        finishEncoder.setTexture(upscaledTex, index: 0)
        finishEncoder.setTexture(dstTex, index: 1)
        finishEncoder.setBytes(&finishUniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
        dispatch2D(encoder: finishEncoder, pipeline: enhanceBGRAPipeline, width: outW, height: outH)
        finishEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        CVBufferPropagateAttachments(sourceBuffer, dstBuffer)
        CVBufferRemoveAttachment(dstBuffer, kCVImageBufferYCbCrMatrixKey)
        if CVBufferCopyAttachment(dstBuffer, kCVImageBufferColorPrimariesKey, nil) == nil {
            CVBufferSetAttachment(dstBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        }
        if CVBufferCopyAttachment(dstBuffer, kCVImageBufferTransferFunctionKey, nil) == nil {
            CVBufferSetAttachment(dstBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        return dstBuffer
    }

    private func runBiPlanarLumaPass(
        sourceBuffer: CVPixelBuffer,
        pixelFormat: OSType,
        srcW: Int,
        srcH: Int,
        is10Bit: Bool,
        isVideoRange: UInt32,
        isBT601: UInt32,
        compareUniform: UInt32,
        params: VideoEnhancementParameters,
        commandQueue: MTLCommandQueue,
        textureCache: CVMetalTextureCache,
        enhanceLumaPipeline: MTLComputePipelineState,
        copyChromaPipeline: MTLComputePipelineState
    ) -> CVPixelBuffer? {
        let yFmt: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvFmt: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm
        guard let dstBuffer = allocateOutputBuffer(width: srcW, height: srcH, pixelFormat: pixelFormat),
              let srcY = makeTexture(from: sourceBuffer, pixelFormat: yFmt, plane: 0, cache: textureCache),
              let srcUV = makeTexture(from: sourceBuffer, pixelFormat: uvFmt, plane: 1, cache: textureCache),
              let dstY = makeTexture(from: dstBuffer, pixelFormat: yFmt, plane: 0, cache: textureCache),
              let dstUV = makeTexture(from: dstBuffer, pixelFormat: uvFmt, plane: 1, cache: textureCache),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        if let yEncoder = commandBuffer.makeComputeCommandEncoder() {
            var uniforms = makeUniforms(
                params: params,
                isVideoRange: isVideoRange,
                isBT601: isBT601,
                compareUniform: compareUniform
            )
            yEncoder.setComputePipelineState(enhanceLumaPipeline)
            yEncoder.setTexture(srcY, index: 0)
            yEncoder.setTexture(dstY, index: 1)
            yEncoder.setBytes(&uniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
            dispatch2D(encoder: yEncoder, pipeline: enhanceLumaPipeline, width: srcW, height: srcH)
            yEncoder.endEncoding()
        }

        if let uvEncoder = commandBuffer.makeComputeCommandEncoder() {
            let uvW = CVPixelBufferGetWidthOfPlane(dstBuffer, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(dstBuffer, 1)
            uvEncoder.setComputePipelineState(copyChromaPipeline)
            uvEncoder.setTexture(srcUV, index: 0)
            uvEncoder.setTexture(dstUV, index: 1)
            dispatch2D(encoder: uvEncoder, pipeline: copyChromaPipeline, width: uvW, height: uvH)
            uvEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        CVBufferPropagateAttachments(sourceBuffer, dstBuffer)
        return dstBuffer
    }

    private func runBGRAPass(
        sourceBuffer: CVPixelBuffer,
        srcW: Int,
        srcH: Int,
        compareUniform: UInt32,
        params: VideoEnhancementParameters,
        commandQueue: MTLCommandQueue,
        textureCache: CVMetalTextureCache,
        enhanceBGRAPipeline: MTLComputePipelineState
    ) -> CVPixelBuffer? {
        guard let dstBuffer = allocateOutputBuffer(width: srcW, height: srcH, pixelFormat: kCVPixelFormatType_32BGRA),
              let srcTex = makeTexture(from: sourceBuffer, pixelFormat: .bgra8Unorm, plane: 0, cache: textureCache),
              let dstTex = makeTexture(from: dstBuffer, pixelFormat: .bgra8Unorm, plane: 0, cache: textureCache),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var uniforms = makeUniforms(
            params: params,
            isVideoRange: 0,
            isBT601: 0,
            compareUniform: compareUniform
        )
        encoder.setComputePipelineState(enhanceBGRAPipeline)
        encoder.setTexture(srcTex, index: 0)
        encoder.setTexture(dstTex, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<MetalEnhanceUniforms>.size, index: 0)
        dispatch2D(encoder: encoder, pipeline: enhanceBGRAPipeline, width: srcW, height: srcH)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        CVBufferPropagateAttachments(sourceBuffer, dstBuffer)
        return dstBuffer
    }

    private func ensureScalerResources(device: MTLDevice, inW: Int, inH: Int, outW: Int, outH: Int) {
        let sig = "\(inW)x\(inH)->\(outW)x\(outH)"
        guard sig != scalerSignature || scalerOutputTexture == nil else { return }
        scalerSignature = sig

        let inDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: inW,
            height: inH,
            mipmapped: false
        )
        inDesc.usage = [.shaderRead, .shaderWrite]
        inDesc.storageMode = .private
        scalerInputTexture = device.makeTexture(descriptor: inDesc)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outW,
            height: outH,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .private
        scalerOutputTexture = device.makeTexture(descriptor: outDesc)

#if canImport(MetalFX) && !targetEnvironment(simulator)
        if MTLFXSpatialScalerDescriptor.supportsDevice(device) {
            let fxDesc = MTLFXSpatialScalerDescriptor()
            fxDesc.colorTextureFormat = .bgra8Unorm
            fxDesc.outputTextureFormat = .bgra8Unorm
            fxDesc.inputWidth = inW
            fxDesc.inputHeight = inH
            fxDesc.outputWidth = outW
            fxDesc.outputHeight = outH
            fxDesc.colorProcessingMode = .perceptual
            if let scaler = fxDesc.makeSpatialScaler(device: device) {
                spatialScaler = scaler
                isUsingHardwareMetalFX = true
                return
            }
        }
        spatialScaler = nil
#endif
        isUsingHardwareMetalFX = false
    }

    private func allocateOutputBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        let sig = "\(width)x\(height):\(pixelFormat)"
        if sig != outputPoolSignature || outputPool == nil {
            let poolAttrs: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 2
            ]
            let bufferAttrs: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttrs as CFDictionary,
                bufferAttrs as CFDictionary,
                &pool
            )
            if status == kCVReturnSuccess, let pool {
                outputPool = pool
                outputPoolSignature = sig
            } else {
                outputPool = nil
                outputPoolSignature = ""
                return nil
            }
        }
        guard let outputPool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        plane: Int,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
        let width = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func dispatch2D(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let tw = max(1, min(16, pipeline.threadExecutionWidth))
        let th = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tw))
        let tgSize = MTLSize(width: tw, height: th, depth: 1)
        let gridSize = MTLSize(
            width: (width + tw - 1) / tw,
            height: (height + th - 1) / th,
            depth: 1
        )
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
    }

    private static func isBT601Matrix(on pixelBuffer: CVPixelBuffer) -> Bool {
        guard let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else {
            return false
        }
        return matrix.contains("601")
    }
}
