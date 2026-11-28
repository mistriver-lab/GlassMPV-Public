import CoreVideo
import Foundation
import Metal
import QuartzCore

struct SendableMetalTexture: @unchecked Sendable {
    let texture: MTLTexture
}

struct MetalOpticalFlowResult: Sendable {
    let forwardFlow: SendableMetalTexture
    let backwardFlow: SendableMetalTexture
    let flowWidth: Int
    let flowHeight: Int
    let isSceneCut: Bool
    let rawSAD: Float
    let warpedSAD: Float
    let elapsedMs: Double
}

private struct PyramidBuildUniforms {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var isVideoRange: UInt32
}

private struct PyramidMatchUniforms {
    var width: UInt32
    var height: UInt32
    var coarseWidth: UInt32
    var coarseHeight: UInt32
    var searchRadius: Int32
    var levelIndex: UInt32
    var outputNormalizedUV: UInt32
    var patchStep: Float
}

private struct PyramidStatsUniforms {
    var width: UInt32
    var height: UInt32
}

/// Pure-Metal 4-level GPU optical flow pyramid engine (256x144 L3 + precomputed RGBA16F (Y, Gx, Gy) feature pyramid -> normalized UV RG16F fields).
/// Compiles and runs on both real iOS devices (iphoneos) and macOS iOS Simulator.
final class MetalPyramidOpticalFlowEngine: @unchecked Sendable {
    private(set) var shaderInitError: String?

    private let lock = NSLock()
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?

    private var buildLumaPipeline: MTLComputePipelineState?
    private var downsampleLumaPipeline: MTLComputePipelineState?
    private var buildFeatureFromLumaPipeline: MTLComputePipelineState?
    private var estimateCoarsePipeline: MTLComputePipelineState?
    private var refineFlowPipeline: MTLComputePipelineState?
    private var bilateralSmoothPipeline: MTLComputePipelineState?
    private var sceneCutStatsPipeline: MTLComputePipelineState?

    private var allocatedFlowW: Int = 0
    private var allocatedFlowH: Int = 0
    private var prevPyramid: [MTLTexture] = []
    private var currPyramid: [MTLTexture] = []
    private var prevFeaturePyramid: [MTLTexture] = []
    private var currFeaturePyramid: [MTLTexture] = []
    private var fwdScratch: [MTLTexture] = []
    private var bwdScratch: [MTLTexture] = []
    private var flowRing: [(fwd: MTLTexture, bwd: MTLTexture)] = []
    private var ringCursor: Int = 0
    private var statsBuffer: MTLBuffer?

    private static let ringCapacity = 16

    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct PyramidBuildUniforms {
        uint srcWidth;
        uint srcHeight;
        uint dstWidth;
        uint dstHeight;
        uint isVideoRange;
    };

    struct PyramidMatchUniforms {
        uint width;
        uint height;
        uint coarseWidth;
        uint coarseHeight;
        int searchRadius;
        uint levelIndex;
        uint outputNormalizedUV;
        float patchStep;
    };

    struct PyramidStatsUniforms {
        uint width;
        uint height;
    };

    inline float toUnitLuma(half raw, uint isVideoRange) {
        if (isVideoRange == 0u) {
            return clamp(float(raw), 0.0f, 1.0f);
        }
        return clamp((float(raw) - 0.0627451f) * 1.1643836f, 0.0f, 1.0f);
    }

    kernel void buildLumaLevel3(
        texture2d<half, access::sample> inY [[texture(0)]],
        texture2d<float, access::write> outLuma [[texture(1)]],
        constant PyramidBuildUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.dstWidth || gid.y >= u.dstHeight) {
            return;
        }
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 invDst = float2(1.0f / max(1.0f, float(u.dstWidth)), 1.0f / max(1.0f, float(u.dstHeight)));
        float2 centerUV = (float2(gid) + 0.5f) * invDst;
        float2 sub = invDst * 0.25f;

        float y00 = toUnitLuma(inY.sample(linearSampler, centerUV + float2(-sub.x, -sub.y)).r, u.isVideoRange);
        float y10 = toUnitLuma(inY.sample(linearSampler, centerUV + float2( sub.x, -sub.y)).r, u.isVideoRange);
        float y01 = toUnitLuma(inY.sample(linearSampler, centerUV + float2(-sub.x,  sub.y)).r, u.isVideoRange);
        float y11 = toUnitLuma(inY.sample(linearSampler, centerUV + float2( sub.x,  sub.y)).r, u.isVideoRange);
        float luma = 0.25f * (y00 + y10 + y01 + y11);
        outLuma.write(float4(luma, 0.0f, 0.0f, 1.0f), gid);
    }

    kernel void downsampleLuma2x(
        texture2d<float, access::sample> inLuma [[texture(0)]],
        texture2d<float, access::write> outLuma [[texture(1)]],
        constant PyramidBuildUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.dstWidth || gid.y >= u.dstHeight) {
            return;
        }
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 invDst = float2(1.0f / max(1.0f, float(u.dstWidth)), 1.0f / max(1.0f, float(u.dstHeight)));
        float2 uv = (float2(gid) + 0.5f) * invDst;
        float2 off = float2(0.5f / max(1.0f, float(u.srcWidth)), 0.5f / max(1.0f, float(u.srcHeight)));
        float y0 = inLuma.sample(linearSampler, uv + float2(-off.x, -off.y)).r;
        float y1 = inLuma.sample(linearSampler, uv + float2( off.x, -off.y)).r;
        float y2 = inLuma.sample(linearSampler, uv + float2(-off.x,  off.y)).r;
        float y3 = inLuma.sample(linearSampler, uv + float2( off.x,  off.y)).r;
        outLuma.write(float4(0.25f * (y0 + y1 + y2 + y3), 0.0f, 0.0f, 1.0f), gid);
    }

    kernel void buildFeatureFromLuma(
        texture2d<half, access::sample> inLuma [[texture(0)]],
        texture2d<half, access::write> outFeature [[texture(1)]],
        constant PyramidStatsUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) {
            return;
        }
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 invSize = float2(1.0f / max(1.0f, float(u.width)), 1.0f / max(1.0f, float(u.height)));
        float2 uv = (float2(gid) + 0.5f) * invSize;
        half yC = inLuma.sample(linearSampler, uv).r;
        half yL = inLuma.sample(linearSampler, uv - float2(invSize.x, 0.0f)).r;
        half yR = inLuma.sample(linearSampler, uv + float2(invSize.x, 0.0f)).r;
        half yU = inLuma.sample(linearSampler, uv - float2(0.0f, invSize.y)).r;
        half yD = inLuma.sample(linearSampler, uv + float2(0.0f, invSize.y)).r;
        outFeature.write(half4(yC, yR - yL, yD - yU, half(1.0h)), gid);
    }

    inline float patchMatchFeatureCost(
        texture2d<half, access::sample> refFeat,
        texture2d<half, access::sample> tgtFeat,
        float2 uvRef,
        float2 flowUV,
        float2 invSize,
        int patchRadius,
        float patchStep
    ) {
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 uvTgt = uvRef + flowUV;
        if (uvTgt.x < -0.02f || uvTgt.x > 1.02f || uvTgt.y < -0.02f || uvTgt.y > 1.02f) {
            return 1.5f;
        }
        half sum = half(0.0h);
        float count = 0.0f;
        for (int py = -patchRadius; py <= patchRadius; ++py) {
            for (int px = -patchRadius; px <= patchRadius; ++px) {
                float2 delta = float2(float(px) * patchStep, float(py) * patchStep) * invSize;
                half3 fA = refFeat.sample(linearSampler, uvRef + delta).rgb;
                half3 fB = tgtFeat.sample(linearSampler, uvTgt + delta).rgb;
                half3 diff = abs(fA - fB);
                sum += half(0.65h) * diff.r + half(0.35h) * (diff.g + diff.b);
                count += 1.0f;
            }
        }
        return float(sum) / max(1.0f, count);
    }

    kernel void estimateFlowCoarse(
        texture2d<half, access::sample> refFeat [[texture(0)]],
        texture2d<half, access::sample> tgtFeat [[texture(1)]],
        texture2d<float, access::write> outFlow [[texture(2)]],
        constant PyramidMatchUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) {
            return;
        }
        float2 invSize = float2(1.0f / max(1.0f, float(u.width)), 1.0f / max(1.0f, float(u.height)));
        float2 uvRef = (float2(gid) + 0.5f) * invSize;

        int r = max(1, u.searchRadius);
        float bestCost = 1e9f;
        float2 bestDeltaPx = float2(0.0f);

        for (int dy = -r; dy <= r; ++dy) {
            for (int dx = -r; dx <= r; ++dx) {
                float2 deltaPx = float2(float(dx), float(dy));
                float cost = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, deltaPx * invSize, invSize, 2, 1.0f);
                if (dx != 0 || dy != 0) {
                    cost += 0.0025f + 0.0003f * length(deltaPx);
                }
                if (cost < bestCost) {
                    bestCost = cost;
                    bestDeltaPx = deltaPx;
                }
            }
        }

        outFlow.write(float4(bestDeltaPx.x, bestDeltaPx.y, 0.0f, 1.0f), gid);
    }

    kernel void refineFlowLevel(
        texture2d<half, access::sample> refFeat [[texture(0)]],
        texture2d<half, access::sample> tgtFeat [[texture(1)]],
        texture2d<float, access::sample> coarseFlow [[texture(2)]],
        texture2d<float, access::write> outFlow [[texture(3)]],
        constant PyramidMatchUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) {
            return;
        }
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 invSize = float2(1.0f / max(1.0f, float(u.width)), 1.0f / max(1.0f, float(u.height)));
        float2 uvRef = (float2(gid) + 0.5f) * invSize;

        float2 scaleFromCoarse = float2(
            float(u.width) / max(1.0f, float(u.coarseWidth)),
            float(u.height) / max(1.0f, float(u.coarseHeight))
        );
        float2 predPx = coarseFlow.sample(linearSampler, uvRef).rg * scaleFromCoarse;
        float2 basePx = round(predPx);

        int r = max(1, u.searchRadius);
        int patchRadius = 1;
        float regWeight = (u.levelIndex >= 3u) ? 0.0006f : 0.0010f;

        float bestCost = 1e9f;
        float2 bestPx = basePx;

        for (int dy = -r; dy <= r; ++dy) {
            for (int dx = -r; dx <= r; ++dx) {
                float2 candPx = basePx + float2(float(dx), float(dy));
                float cost = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, candPx * invSize, invSize, patchRadius, u.patchStep);
                cost += regWeight * length(candPx - predPx);
                if (cost < bestCost) {
                    bestCost = cost;
                    bestPx = candPx;
                }
            }
        }

        if (length(bestPx) > 0.5f) {
            float zeroCost = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, float2(0.0f), invSize, patchRadius, u.patchStep);
            if (zeroCost + 0.004f < bestCost) {
                bestCost = zeroCost;
                bestPx = float2(0.0f);
            }
        }

        float2 finalPx = bestPx;
        if (u.outputNormalizedUV != 0u && length(bestPx) > 0.25f) {
            float cC = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, bestPx * invSize, invSize, 1, 1.0f);
            float cL = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, (bestPx + float2(-1.0f,  0.0f)) * invSize, invSize, 1, 1.0f);
            float cR = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, (bestPx + float2( 1.0f,  0.0f)) * invSize, invSize, 1, 1.0f);
            float cU = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, (bestPx + float2( 0.0f, -1.0f)) * invSize, invSize, 1, 1.0f);
            float cD = patchMatchFeatureCost(refFeat, tgtFeat, uvRef, (bestPx + float2( 0.0f,  1.0f)) * invSize, invSize, 1, 1.0f);

            float denomX = 2.0f * (cL + cR - 2.0f * cC);
            if (denomX > 0.002f) {
                finalPx.x += clamp((cL - cR) / denomX, -0.45f, 0.45f);
            }
            float denomY = 2.0f * (cU + cD - 2.0f * cC);
            if (denomY > 0.002f) {
                finalPx.y += clamp((cU - cD) / denomY, -0.45f, 0.45f);
            }
        }

        if (u.outputNormalizedUV != 0u) {
            float2 uvFlow = finalPx * invSize;
            outFlow.write(float4(uvFlow.x, uvFlow.y, 0.0f, 1.0f), gid);
        } else {
            outFlow.write(float4(finalPx.x, finalPx.y, 0.0f, 1.0f), gid);
        }
    }

    kernel void bilateralSmoothFlow(
        texture2d<float, access::sample> inFlow [[texture(0)]],
        texture2d<float, access::sample> guideLuma [[texture(1)]],
        texture2d<float, access::write> outFlow [[texture(2)]],
        constant PyramidStatsUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) {
            return;
        }
        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        float2 invSize = float2(1.0f / max(1.0f, float(u.width)), 1.0f / max(1.0f, float(u.height)));
        float2 uv = (float2(gid) + 0.5f) * invSize;

        float centerY = guideLuma.sample(linearSampler, uv).r;
        float2 centerFlow = inFlow.sample(linearSampler, uv).rg;
        if (!isfinite(centerFlow.x) || !isfinite(centerFlow.y)) {
            centerFlow = float2(0.0f);
        }

        float2 accum = float2(0.0f);
        float wSum = 0.0f;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                float2 qUV = uv + float2(float(dx), float(dy)) * invSize;
                float qY = guideLuma.sample(linearSampler, qUV).r;
                float2 qF = inFlow.sample(linearSampler, qUV).rg;
                if (!isfinite(qF.x) || !isfinite(qF.y)) {
                    continue;
                }
                float wSpatial = (dx == 0 && dy == 0) ? 1.5f : ((dx == 0 || dy == 0) ? 1.0f : 0.7f);
                float wRange = exp(-abs(qY - centerY) * 28.0f);
                float w = wSpatial * wRange;
                accum += qF * w;
                wSum += w;
            }
        }
        float2 smoothed = (wSum > 0.0001f) ? (accum / wSum) : centerFlow;
        if (length(smoothed) < 0.0002f) {
            smoothed = float2(0.0f);
        }
        outFlow.write(float4(smoothed.x, smoothed.y, 0.0f, 1.0f), gid);
    }

    kernel void computeSceneCutStats(
        texture2d<float, access::sample> prevLumaL0 [[texture(0)]],
        texture2d<float, access::sample> currLumaL0 [[texture(1)]],
        texture2d<float, access::sample> forwardFlow [[texture(2)]],
        device float* outStats [[buffer(0)]],
        constant PyramidStatsUniforms& u [[buffer(1)]],
        uint tid [[thread_index_in_threadgroup]],
        uint2 tgSize [[threads_per_threadgroup]]
    ) {
        threadgroup float sharedRaw[256];
        threadgroup float sharedWarped[256];
        threadgroup float sharedCount[256];

        constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
        uint totalThreads = tgSize.x * tgSize.y;
        uint w = max(1u, u.width);
        uint h = max(1u, u.height);
        uint totalPixels = w * h;

        float rawAcc = 0.0f;
        float warpedAcc = 0.0f;
        float cnt = 0.0f;

        for (uint idx = tid; idx < totalPixels; idx += totalThreads) {
            uint x = idx % w;
            uint y = idx / w;
            float2 uv = float2((float(x) + 0.5f) / float(w), (float(y) + 0.5f) / float(h));
            float y0 = prevLumaL0.sample(linearSampler, uv).r;
            float y1Raw = currLumaL0.sample(linearSampler, uv).r;
            float2 f = forwardFlow.sample(linearSampler, uv).rg;
            if (!isfinite(f.x) || !isfinite(f.y)) {
                f = float2(0.0f);
            }
            float y1Warp = currLumaL0.sample(linearSampler, clamp(uv + f, float2(0.0f), float2(1.0f))).r;
            rawAcc += abs(y0 - y1Raw);
            warpedAcc += abs(y0 - y1Warp);
            cnt += 1.0f;
        }

        sharedRaw[tid] = rawAcc;
        sharedWarped[tid] = warpedAcc;
        sharedCount[tid] = cnt;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint stride = totalThreads >> 1; stride > 0; stride >>= 1) {
            if (tid < stride) {
                sharedRaw[tid] += sharedRaw[tid + stride];
                sharedWarped[tid] += sharedWarped[tid + stride];
                sharedCount[tid] += sharedCount[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (tid == 0) {
            float denom = max(1.0f, sharedCount[0]);
            outStats[0] = sharedRaw[0] / denom;
            outStats[1] = sharedWarped[0] / denom;
            outStats[2] = denom;
            outStats[3] = 0.0f;
        }
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
            self.statsBuffer = dev.makeBuffer(length: 4 * MemoryLayout<Float>.size, options: .storageModeShared)
            do {
                let library = try dev.makeLibrary(source: Self.shaderSource, options: nil)
                self.buildLumaPipeline = try library.makeFunction(name: "buildLumaLevel3").map {
                    try dev.makeComputePipelineState(function: $0)
                }
                self.downsampleLumaPipeline = try library.makeFunction(name: "downsampleLuma2x").map {
                    try dev.makeComputePipelineState(function: $0)
                }
                self.buildFeatureFromLumaPipeline = try library.makeFunction(name: "buildFeatureFromLuma").map {
                    try dev.makeComputePipelineState(function: $0)
                }
                self.estimateCoarsePipeline = try library.makeFunction(name: "estimateFlowCoarse").map {
                    try dev.makeComputePipelineState(function: $0)
                }
                self.refineFlowPipeline = try library.makeFunction(name: "refineFlowLevel").map {
                    try dev.makeComputePipelineState(function: $0)
                }
                self.bilateralSmoothPipeline = try library.makeFunction(name: "bilateralSmoothFlow").map {
                    try dev.makeComputePipelineState(function: $0)
                }
                self.sceneCutStatsPipeline = try library.makeFunction(name: "computeSceneCutStats").map {
                    try dev.makeComputePipelineState(function: $0)
                }
            } catch {
                self.shaderInitError = error.localizedDescription
            }
        }
    }

    static func recommendedFlowDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let safeW = max(64, sourceWidth)
        let safeH = max(64, sourceHeight)
        let isLandscape = safeW >= safeH
        let capW = isLandscape ? 256 : 144
        let capH = isLandscape ? 144 : 256
        let scale = min(1.0, min(Double(capW) / Double(safeW), Double(capH) / Double(safeH)))
        func align8(_ value: Int) -> Int {
            let clamped = max(64, value)
            return clamped - (clamped % 8)
        }
        return (align8(Int(floor(Double(safeW) * scale))), align8(Int(floor(Double(safeH) * scale))))
    }

    func reset() {
        lock.lock()
        ringCursor = 0
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        lock.unlock()
    }

    static func evaluateSceneCut(rawSAD: Float, warpedSAD: Float) -> Bool {
        guard rawSAD.isFinite, warpedSAD.isFinite else { return false }
        return rawSAD > 0.22 && warpedSAD > 0.16 && warpedSAD > rawSAD * 0.78
    }

    func estimateFlow(prevBuffer: CVPixelBuffer, currBuffer: CVPixelBuffer) async -> MetalOpticalFlowResult? {
        guard let encoded = encodeFlowCommandBuffer(prevBuffer: prevBuffer, currBuffer: currBuffer) else {
            return nil
        }
        let commandBuffer = encoded.commandBuffer
        let statsBuffer = encoded.statsBuffer
        let fwdTex = encoded.fwdTex
        let bwdTex = encoded.bwdTex
        let flowW = encoded.flowW
        let flowH = encoded.flowH
        let startHost = encoded.startHost

        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                let elapsedMs = (CACurrentMediaTime() - startHost) * 1000.0
                let statsPtr = statsBuffer.contents().assumingMemoryBound(to: Float.self)
                let rawSAD = statsPtr[0]
                let warpedSAD = statsPtr[1]
                let isCut = Self.evaluateSceneCut(rawSAD: rawSAD, warpedSAD: warpedSAD)
                continuation.resume(
                    returning: MetalOpticalFlowResult(
                        forwardFlow: SendableMetalTexture(texture: fwdTex),
                        backwardFlow: SendableMetalTexture(texture: bwdTex),
                        flowWidth: flowW,
                        flowHeight: flowH,
                        isSceneCut: isCut,
                        rawSAD: rawSAD,
                        warpedSAD: warpedSAD,
                        elapsedMs: elapsedMs
                    )
                )
            }
            commandBuffer.commit()
        }
    }

    private func encodeFlowCommandBuffer(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer
    ) -> (
        commandBuffer: MTLCommandBuffer,
        statsBuffer: MTLBuffer,
        fwdTex: MTLTexture,
        bwdTex: MTLTexture,
        flowW: Int,
        flowH: Int,
        startHost: CFTimeInterval
    )? {
        let srcW = CVPixelBufferGetWidth(currBuffer)
        let srcH = CVPixelBufferGetHeight(currBuffer)
        guard srcW >= 64, srcH >= 64 else { return nil }

        let targetDims = Self.recommendedFlowDimensions(sourceWidth: srcW, sourceHeight: srcH)

        lock.lock()
        defer { lock.unlock() }

        guard let device,
              let commandQueue,
              let textureCache,
              let statsBuffer,
              let buildLumaPipeline,
              let downsampleLumaPipeline,
              let buildFeatureFromLumaPipeline,
              let estimateCoarsePipeline,
              let refineFlowPipeline,
              let bilateralSmoothPipeline,
              let sceneCutStatsPipeline else {
            return nil
        }

        guard ensureResourcesLocked(device: device, flowW: targetDims.width, flowH: targetDims.height),
              prevPyramid.count == 4,
              currPyramid.count == 4,
              prevFeaturePyramid.count == 4,
              currFeaturePyramid.count == 4,
              fwdScratch.count == 4,
              bwdScratch.count == 4,
              !flowRing.isEmpty else {
            return nil
        }

        let fmt = CVPixelBufferGetPixelFormatType(currBuffer)
        let isVideoRange: UInt32 = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 0 : 1

        guard let prevYTex = makeLumaTexture(from: prevBuffer, cache: textureCache),
              let currYTex = makeLumaTexture(from: currBuffer, cache: textureCache),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let outPair = flowRing[ringCursor % flowRing.count]
        ringCursor &+= 1
        let startHost = CACurrentMediaTime()

        // 1. Build 4-level luma + precomputed RGBA16F (Y, Gx, Gy) feature pyramids
        encodeLumaAndFeaturePyramid(
            srcY: prevYTex,
            srcW: srcW,
            srcH: srcH,
            isVideoRange: isVideoRange,
            lumaPyramid: prevPyramid,
            featurePyramid: prevFeaturePyramid,
            commandBuffer: commandBuffer,
            buildPipeline: buildLumaPipeline,
            downsamplePipeline: downsampleLumaPipeline,
            featurePipeline: buildFeatureFromLumaPipeline
        )
        encodeLumaAndFeaturePyramid(
            srcY: currYTex,
            srcW: srcW,
            srcH: srcH,
            isVideoRange: isVideoRange,
            lumaPyramid: currPyramid,
            featurePyramid: currFeaturePyramid,
            commandBuffer: commandBuffer,
            buildPipeline: buildLumaPipeline,
            downsamplePipeline: downsampleLumaPipeline,
            featurePipeline: buildFeatureFromLumaPipeline
        )

        // 2. Forward flow (prev -> curr): curr(uv + F(uv)) ~= prev(uv)
        encodeFlowEstimation(
            refFeaturePyramid: prevFeaturePyramid,
            tgtFeaturePyramid: currFeaturePyramid,
            guideLumaL3: prevPyramid[3],
            scratchFlows: fwdScratch,
            finalFlow: outPair.fwd,
            commandBuffer: commandBuffer,
            coarsePipeline: estimateCoarsePipeline,
            refinePipeline: refineFlowPipeline,
            bilateralPipeline: bilateralSmoothPipeline
        )

        // 3. Backward flow (curr -> prev): prev(uv + B(uv)) ~= curr(uv)
        encodeFlowEstimation(
            refFeaturePyramid: currFeaturePyramid,
            tgtFeaturePyramid: prevFeaturePyramid,
            guideLumaL3: currPyramid[3],
            scratchFlows: bwdScratch,
            finalFlow: outPair.bwd,
            commandBuffer: commandBuffer,
            coarsePipeline: estimateCoarsePipeline,
            refinePipeline: refineFlowPipeline,
            bilateralPipeline: bilateralSmoothPipeline
        )

        // 4. Scene-cut SAD statistics over L0
        if let statsEnc = commandBuffer.makeComputeCommandEncoder() {
            let l0W = prevPyramid[0].width
            let l0H = prevPyramid[0].height
            var statsU = PyramidStatsUniforms(width: UInt32(l0W), height: UInt32(l0H))
            statsEnc.setComputePipelineState(sceneCutStatsPipeline)
            statsEnc.setTexture(prevPyramid[0], index: 0)
            statsEnc.setTexture(currPyramid[0], index: 1)
            statsEnc.setTexture(outPair.fwd, index: 2)
            statsEnc.setBuffer(statsBuffer, offset: 0, index: 0)
            statsEnc.setBytes(&statsU, length: MemoryLayout<PyramidStatsUniforms>.size, index: 1)
            let tgCount = min(256, max(1, sceneCutStatsPipeline.maxTotalThreadsPerThreadgroup))
            let pow2 = tgCount >= 256 ? 256 : (tgCount >= 128 ? 128 : 64)
            statsEnc.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pow2, height: 1, depth: 1)
            )
            statsEnc.endEncoding()
        }

        if ringCursor % 4 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }

        return (commandBuffer, statsBuffer, outPair.fwd, outPair.bwd, targetDims.width, targetDims.height, startHost)
    }

    private func encodeLumaAndFeaturePyramid(
        srcY: MTLTexture,
        srcW: Int,
        srcH: Int,
        isVideoRange: UInt32,
        lumaPyramid: [MTLTexture],
        featurePyramid: [MTLTexture],
        commandBuffer: MTLCommandBuffer,
        buildPipeline: MTLComputePipelineState,
        downsamplePipeline: MTLComputePipelineState,
        featurePipeline: MTLComputePipelineState
    ) {
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            let fine = lumaPyramid[3]
            var u = PyramidBuildUniforms(
                srcWidth: UInt32(srcW),
                srcHeight: UInt32(srcH),
                dstWidth: UInt32(fine.width),
                dstHeight: UInt32(fine.height),
                isVideoRange: isVideoRange
            )
            enc.setComputePipelineState(buildPipeline)
            enc.setTexture(srcY, index: 0)
            enc.setTexture(fine, index: 1)
            enc.setBytes(&u, length: MemoryLayout<PyramidBuildUniforms>.size, index: 0)
            dispatch2D(encoder: enc, pipeline: buildPipeline, width: fine.width, height: fine.height)
            enc.endEncoding()
        }

        for level in stride(from: 2, through: 0, by: -1) {
            let higher = lumaPyramid[level + 1]
            let lower = lumaPyramid[level]
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                var u = PyramidBuildUniforms(
                    srcWidth: UInt32(higher.width),
                    srcHeight: UInt32(higher.height),
                    dstWidth: UInt32(lower.width),
                    dstHeight: UInt32(lower.height),
                    isVideoRange: isVideoRange
                )
                enc.setComputePipelineState(downsamplePipeline)
                enc.setTexture(higher, index: 0)
                enc.setTexture(lower, index: 1)
                enc.setBytes(&u, length: MemoryLayout<PyramidBuildUniforms>.size, index: 0)
                dispatch2D(encoder: enc, pipeline: downsamplePipeline, width: lower.width, height: lower.height)
                enc.endEncoding()
            }
        }

        for level in 0...3 {
            let lumaTex = lumaPyramid[level]
            let featTex = featurePyramid[level]
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                var u = PyramidStatsUniforms(width: UInt32(featTex.width), height: UInt32(featTex.height))
                enc.setComputePipelineState(featurePipeline)
                enc.setTexture(lumaTex, index: 0)
                enc.setTexture(featTex, index: 1)
                enc.setBytes(&u, length: MemoryLayout<PyramidStatsUniforms>.size, index: 0)
                dispatch2D(encoder: enc, pipeline: featurePipeline, width: featTex.width, height: featTex.height)
                enc.endEncoding()
            }
        }
    }

    private func encodeFlowEstimation(
        refFeaturePyramid: [MTLTexture],
        tgtFeaturePyramid: [MTLTexture],
        guideLumaL3: MTLTexture,
        scratchFlows: [MTLTexture],
        finalFlow: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        coarsePipeline: MTLComputePipelineState,
        refinePipeline: MTLComputePipelineState,
        bilateralPipeline: MTLComputePipelineState
    ) {
        let l0Ref = refFeaturePyramid[0]
        let l0Tgt = tgtFeaturePyramid[0]
        let l0Out = scratchFlows[0]
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            var u = PyramidMatchUniforms(
                width: UInt32(l0Out.width),
                height: UInt32(l0Out.height),
                coarseWidth: UInt32(l0Out.width),
                coarseHeight: UInt32(l0Out.height),
                searchRadius: 4,
                levelIndex: 0,
                outputNormalizedUV: 0,
                patchStep: 1.0
            )
            enc.setComputePipelineState(coarsePipeline)
            enc.setTexture(l0Ref, index: 0)
            enc.setTexture(l0Tgt, index: 1)
            enc.setTexture(l0Out, index: 2)
            enc.setBytes(&u, length: MemoryLayout<PyramidMatchUniforms>.size, index: 0)
            dispatch2D(encoder: enc, pipeline: coarsePipeline, width: l0Out.width, height: l0Out.height)
            enc.endEncoding()
        }

        for level in 1...3 {
            let refL = refFeaturePyramid[level]
            let tgtL = tgtFeaturePyramid[level]
            let coarseF = scratchFlows[level - 1]
            let dstF = scratchFlows[level]
            let radius: Int32 = (level == 3) ? 1 : 2
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                var u = PyramidMatchUniforms(
                    width: UInt32(dstF.width),
                    height: UInt32(dstF.height),
                    coarseWidth: UInt32(coarseF.width),
                    coarseHeight: UInt32(coarseF.height),
                    searchRadius: radius,
                    levelIndex: UInt32(level),
                    outputNormalizedUV: (level == 3) ? 1 : 0,
                    patchStep: 1.0
                )
                enc.setComputePipelineState(refinePipeline)
                enc.setTexture(refL, index: 0)
                enc.setTexture(tgtL, index: 1)
                enc.setTexture(coarseF, index: 2)
                enc.setTexture(dstF, index: 3)
                enc.setBytes(&u, length: MemoryLayout<PyramidMatchUniforms>.size, index: 0)
                dispatch2D(encoder: enc, pipeline: refinePipeline, width: dstF.width, height: dstF.height)
                enc.endEncoding()
            }
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            var u = PyramidStatsUniforms(width: UInt32(finalFlow.width), height: UInt32(finalFlow.height))
            enc.setComputePipelineState(bilateralPipeline)
            enc.setTexture(scratchFlows[3], index: 0)
            enc.setTexture(guideLumaL3, index: 1)
            enc.setTexture(finalFlow, index: 2)
            enc.setBytes(&u, length: MemoryLayout<PyramidStatsUniforms>.size, index: 0)
            dispatch2D(encoder: enc, pipeline: bilateralPipeline, width: finalFlow.width, height: finalFlow.height)
            enc.endEncoding()
        }
    }

    private func ensureResourcesLocked(device: MTLDevice, flowW: Int, flowH: Int) -> Bool {
        if allocatedFlowW == flowW,
           allocatedFlowH == flowH,
           prevPyramid.count == 4,
           currPyramid.count == 4,
           prevFeaturePyramid.count == 4,
           currFeaturePyramid.count == 4,
           fwdScratch.count == 4,
           bwdScratch.count == 4,
           flowRing.count == Self.ringCapacity {
            return true
        }

        prevPyramid.removeAll(keepingCapacity: true)
        currPyramid.removeAll(keepingCapacity: true)
        prevFeaturePyramid.removeAll(keepingCapacity: true)
        currFeaturePyramid.removeAll(keepingCapacity: true)
        fwdScratch.removeAll(keepingCapacity: true)
        bwdScratch.removeAll(keepingCapacity: true)
        flowRing.removeAll(keepingCapacity: true)

        func makeTex(format: MTLPixelFormat, w: Int, h: Int, shared: Bool) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: max(4, w),
                height: max(4, h),
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: desc)
        }

        let dims: [(Int, Int)] = [
            (max(4, flowW / 8), max(4, flowH / 8)),
            (max(8, flowW / 4), max(8, flowH / 4)),
            (max(16, flowW / 2), max(16, flowH / 2)),
            (flowW, flowH)
        ]

        for (w, h) in dims {
            guard let pL = makeTex(format: .r16Float, w: w, h: h, shared: false),
                  let cL = makeTex(format: .r16Float, w: w, h: h, shared: false),
                  let pF = makeTex(format: .rgba16Float, w: w, h: h, shared: false),
                  let cF = makeTex(format: .rgba16Float, w: w, h: h, shared: false),
                  let fS = makeTex(format: .rg16Float, w: w, h: h, shared: false),
                  let bS = makeTex(format: .rg16Float, w: w, h: h, shared: false) else {
                allocatedFlowW = 0
                allocatedFlowH = 0
                return false
            }
            prevPyramid.append(pL)
            currPyramid.append(cL)
            prevFeaturePyramid.append(pF)
            currFeaturePyramid.append(cF)
            fwdScratch.append(fS)
            bwdScratch.append(bS)
        }

        for _ in 0..<Self.ringCapacity {
            guard let fwd = makeTex(format: .rg16Float, w: flowW, h: flowH, shared: true),
                  let bwd = makeTex(format: .rg16Float, w: flowW, h: flowH, shared: true) else {
                allocatedFlowW = 0
                allocatedFlowH = 0
                return false
            }
            flowRing.append((fwd: fwd, bwd: bwd))
        }

        allocatedFlowW = flowW
        allocatedFlowH = flowH
        ringCursor = 0
        return true
    }

    private func makeLumaTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let w = planeCount > 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let h = planeCount > 0 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .r8Unorm,
            w,
            h,
            0,
            &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTex)
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
}
