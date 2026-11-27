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

/// 零第三方依赖的实时 Metal + MetalFX GPU 画质增强引擎（单遍多尺度亮度去糊 + 防光晕 CAS + 低清超分 + 分屏对比）
@MainActor
final class MetalVideoEnhancer {
    private(set) var activePipelineLabel: String = "关闭"
    private(set) var averageProcessMs: Double = 0
    private(set) var enhancedFrameCount: Int = 0

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?

    private var enhanceLumaPipeline: MTLComputePipelineState?
    private var copyChromaPipeline: MTLComputePipelineState?
    private var enhanceBGRAPipeline: MTLComputePipelineState?
    private var yuvToBGRAPipeline: MTLComputePipelineState?
    private var bicubicBGRAPipeline: MTLComputePipelineState?

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

    inline float toUnitLuma(float raw, uint isVideoRange) {
        if (isVideoRange == 0u) {
            return clamp(raw, 0.0f, 1.0f);
        }
        return clamp((raw - 0.0627451f) * 1.1643836f, 0.0f, 1.0f);
    }

    inline float fromUnitLuma(float unitVal, uint isVideoRange) {
        float clamped = clamp(unitVal, 0.0f, 1.0f);
        if (isVideoRange == 0u) {
            return clamped;
        }
        return clamp(clamped * 0.8588235f + 0.0627451f, 0.004f, 0.996f);
    }

    inline float rgbLuma(float3 c) {
        return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    }

    inline float3 yuvSampleToRGB(float yRaw, float2 uvRaw, uint isVideoRange, uint isBT601) {
        float y = isVideoRange != 0u ? (yRaw - 0.0627451f) * 1.1643836f : yRaw;
        float cb = uvRaw.x - 0.5019608f;
        float cr = uvRaw.y - 0.5019608f;
        if (isVideoRange != 0u) {
            cb *= 1.1383929f;
            cr *= 1.1383929f;
        }
        float3 rgb;
        if (isBT601 != 0u) {
            rgb.r = y + 1.402f * cr;
            rgb.g = y - 0.344136f * cb - 0.714136f * cr;
            rgb.b = y + 1.772f * cb;
        } else {
            rgb.r = y + 1.5748f * cr;
            rgb.g = y - 0.187324f * cb - 0.468124f * cr;
            rgb.b = y + 1.8556f * cb;
        }
        return clamp(rgb, 0.0f, 1.0f);
    }

    inline float sampleUnitLuma(texture2d<float, access::read> tex, int x, int y, int maxX, int maxY, uint isVideoRange) {
        uint2 pos = uint2(clamp(x, 0, maxX), clamp(y, 0, maxY));
        return toUnitLuma(tex.read(pos).r, isVideoRange);
    }

    inline float sampleRGBLuma(texture2d<float, access::read> tex, int x, int y, int maxX, int maxY) {
        uint2 pos = uint2(clamp(x, 0, maxX), clamp(y, 0, maxY));
        return rgbLuma(tex.read(pos).rgb);
    }

    inline float computeEnhancedLuma(
        float c,
        float n,
        float s,
        float w,
        float e,
        float nw,
        float ne,
        float sw,
        float se,
        float n2,
        float s2,
        float w2,
        float e2,
        constant EnhanceUniforms& u
    ) {
        float mn1 = min(min(c, n), min(s, min(w, e)));
        float mx1 = max(max(c, n), max(s, max(w, e)));
        float mnAll = min(mn1, min(min(nw, ne), min(sw, se)));
        float mxAll = max(mx1, max(max(nw, ne), max(sw, se)));
        float working = c;

        // 1. 多尺度假 4K 去糊 (1px + 2px USM) + 死区门控与邻域极值限幅（零光晕、零 exp 高能耗运算）
        if (u.deblurStrength > 0.001f) {
            float blurFine = 0.25f * (n + s + w + e);
            float blurWide = 0.125f * (n + s + w + e + n2 + s2 + w2 + e2);
            float detailFine = c - blurFine;
            float detailWide = c - blurWide;
            float signF = detailFine >= 0.0f ? 1.0f : -1.0f;
            float signW = detailWide >= 0.0f ? 1.0f : -1.0f;
            float gatedFine = signF * max(0.0f, abs(detailFine) - u.noiseDeadzone * 0.65f);
            float gatedWide = signW * max(0.0f, abs(detailWide) - u.noiseDeadzone);
            float rawUnsharp = working + u.deblurStrength * (0.55f * gatedFine + 0.70f * gatedWide);
            float haloMargin = 0.025f;
            working = clamp(rawUnsharp, mnAll - haloMargin, mxAll + haloMargin);
        }

        // 2. Contrast Adaptive Sharpening (CAS) 微反差与局部边缘重建
        if (u.casStrength > 0.001f) {
            float mn = 0.5f * (mn1 + mnAll);
            float mx = 0.5f * (mx1 + mxAll);
            float peakAmp = sqrt(clamp(min(mn, 1.0f - mx) / max(mx, 0.001f), 0.0f, 1.0f));
            float sharpenWeight = peakAmp * (-0.125f - 0.075f * clamp(u.casStrength, 0.0f, 1.0f));
            float sharpened = (working + (n + s + w + e) * sharpenWeight) / (1.0f + 4.0f * sharpenWeight);
            working = clamp(sharpened, max(0.0f, mnAll - 0.02f), min(1.0f, mxAll + 0.02f));
        }

        // 3. 深色描边线条压实（动漫/漫画/字幕边缘黑位收紧）
        if (u.lineDarken > 0.001f) {
            float avgLocal = 0.25f * (n + s + w + e);
            float darkDelta = max(0.0f, avgLocal - working);
            float gatedDark = max(0.0f, darkDelta - u.noiseDeadzone * 0.5f);
            working = max(0.0f, working - gatedDark * (u.lineDarken * 1.55f));
        }

        // 4. 老片去灰 S 曲线微反差
        if (u.clarityStrength > 0.001f) {
            float midOffset = working - 0.5f;
            working = clamp(working + u.clarityStrength * (working * (1.0f - working) * (midOffset * 1.85f)), 0.0f, 1.0f);
        }

        return clamp(working, 0.0f, 1.0f);
    }

    kernel void enhanceLuma(
        texture2d<float, access::read> inY [[texture(0)]],
        texture2d<float, access::write> outY [[texture(1)]],
        constant EnhanceUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = outY.get_width();
        uint height = outY.get_height();
        if (gid.x >= width || gid.y >= height) {
            return;
        }
        float rawCenter = inY.read(gid).r;
        if (u.compareMode == 2u) {
            outY.write(float4(rawCenter, 0.0f, 0.0f, 1.0f), gid);
            return;
        }
        if (u.compareMode == 1u) {
            int splitPixelX = int(float(width) * clamp(u.splitX, 0.1f, 0.9f));
            if (abs(int(gid.x) - splitPixelX) <= 1) {
                outY.write(float4(fromUnitLuma(0.96f, u.isVideoRange), 0.0f, 0.0f, 1.0f), gid);
                return;
            }
            if (int(gid.x) < splitPixelX) {
                outY.write(float4(rawCenter, 0.0f, 0.0f, 1.0f), gid);
                return;
            }
        }

        int maxX = int(inY.get_width()) - 1;
        int maxY = int(inY.get_height()) - 1;
        int x = int(gid.x);
        int y = int(gid.y);

        float enhanced = computeEnhancedLuma(
            toUnitLuma(rawCenter, u.isVideoRange),
            sampleUnitLuma(inY, x, y - 1, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x, y + 1, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x - 1, y, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x + 1, y, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x - 1, y - 1, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x + 1, y - 1, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x - 1, y + 1, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x + 1, y + 1, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x, y - 2, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x, y + 2, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x - 2, y, maxX, maxY, u.isVideoRange),
            sampleUnitLuma(inY, x + 2, y, maxX, maxY, u.isVideoRange),
            u
        );
        outY.write(float4(fromUnitLuma(enhanced, u.isVideoRange), 0.0f, 0.0f, 1.0f), gid);
    }

    kernel void copyChroma(
        texture2d<float, access::read> inUV [[texture(0)]],
        texture2d<float, access::write> outUV [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= outUV.get_width() || gid.y >= outUV.get_height()) {
            return;
        }
        outUV.write(inUV.read(gid), gid);
    }

    kernel void enhanceBGRA(
        texture2d<float, access::read> inColor [[texture(0)]],
        texture2d<float, access::write> outColor [[texture(1)]],
        constant EnhanceUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = outColor.get_width();
        uint height = outColor.get_height();
        if (gid.x >= width || gid.y >= height) {
            return;
        }
        float4 centerRGBA = inColor.read(gid);
        if (u.compareMode == 2u) {
            outColor.write(centerRGBA, gid);
            return;
        }
        if (u.compareMode == 1u) {
            int splitPixelX = int(float(width) * clamp(u.splitX, 0.1f, 0.9f));
            if (abs(int(gid.x) - splitPixelX) <= 1) {
                outColor.write(float4(0.95f, 0.96f, 0.25f, 1.0f), gid);
                return;
            }
            if (int(gid.x) < splitPixelX) {
                outColor.write(centerRGBA, gid);
                return;
            }
        }

        int maxX = int(inColor.get_width()) - 1;
        int maxY = int(inColor.get_height()) - 1;
        int x = int(gid.x);
        int y = int(gid.y);

        float yCenter = rgbLuma(centerRGBA.rgb);
        float yOut = computeEnhancedLuma(
            yCenter,
            sampleRGBLuma(inColor, x, y - 1, maxX, maxY),
            sampleRGBLuma(inColor, x, y + 1, maxX, maxY),
            sampleRGBLuma(inColor, x - 1, y, maxX, maxY),
            sampleRGBLuma(inColor, x + 1, y, maxX, maxY),
            sampleRGBLuma(inColor, x - 1, y - 1, maxX, maxY),
            sampleRGBLuma(inColor, x + 1, y - 1, maxX, maxY),
            sampleRGBLuma(inColor, x - 1, y + 1, maxX, maxY),
            sampleRGBLuma(inColor, x + 1, y + 1, maxX, maxY),
            sampleRGBLuma(inColor, x, y - 2, maxX, maxY),
            sampleRGBLuma(inColor, x, y + 2, maxX, maxY),
            sampleRGBLuma(inColor, x - 2, y, maxX, maxY),
            sampleRGBLuma(inColor, x + 2, y, maxX, maxY),
            u
        );
        float3 finalRGB = clamp(centerRGBA.rgb + float3(yOut - yCenter), 0.0f, 1.0f);
        outColor.write(float4(finalRGB, centerRGBA.a), gid);
    }

    kernel void yuvToBGRAClean(
        texture2d<float, access::read> inY [[texture(0)]],
        texture2d<float, access::sample> inUV [[texture(1)]],
        texture2d<float, access::write> outColor [[texture(2)]],
        constant EnhanceUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= outColor.get_width() || gid.y >= outColor.get_height()) {
            return;
        }
        constexpr sampler chromaSampler(address::clamp_to_edge, filter::linear);
        float yRaw = inY.read(gid).r;
        float2 normCoord = (float2(gid) + 0.5f) / float2(float(outColor.get_width()), float(outColor.get_height()));
        float2 uvRaw = inUV.sample(chromaSampler, normCoord).rg;
        float3 rgb = yuvSampleToRGB(yRaw, uvRaw, u.isVideoRange, u.isBT601);
        outColor.write(float4(rgb, 1.0f), gid);
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
            } catch {
                self.enhanceLumaPipeline = nil
                self.copyChromaPipeline = nil
                self.enhanceBGRAPipeline = nil
                self.yuvToBGRAPipeline = nil
                self.bicubicBGRAPipeline = nil
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
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
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
