import Metal
import CoreVideo

/// Errors related to Metal setup and operations.
enum MetalError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case noLibrary
    case functionNotFound(String)
    case pipelineFailed(String)
    case textureCacheCreationFailed

    var description: String {
        switch self {
        case .noDevice: return "No Metal device available"
        case .noCommandQueue: return "Failed to create Metal command queue"
        case .noLibrary: return "Failed to load Metal shader library"
        case .functionNotFound(let name): return "Metal function '\(name)' not found"
        case .pipelineFailed(let name): return "Failed to create pipeline state for '\(name)'"
        case .textureCacheCreationFailed: return "Failed to create CVMetalTextureCache"
        }
    }
}

/// Holds the Metal device, command queue, and pre-compiled pipeline states for all shaders.
/// Created once at app launch and shared across the pipeline.
final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    // Pre-compiled compute pipeline states
    let grayscalePipeline: MTLComputePipelineState
    let downsamplePipeline: MTLComputePipelineState
    let sadPipeline: MTLComputePipelineState
    let warpPipeline: MTLComputePipelineState
    let mergeWeightPipeline: MTLComputePipelineState
    let accumulatePipeline: MTLComputePipelineState
    let normalizePipeline: MTLComputePipelineState
    let tonemapPipeline: MTLComputePipelineState
    let clearPipeline: MTLComputePipelineState
    let superResWarpPipeline: MTLComputePipelineState
    let superResWeightPipeline: MTLComputePipelineState
    let hdrFusionWeightPipeline: MTLComputePipelineState

    // Texture cache for zero-copy CVPixelBuffer -> MTLTexture conversion
    let textureCache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalError.noDevice
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw MetalError.noCommandQueue
        }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            throw MetalError.noLibrary
        }
        self.library = library

        // Compile all pipeline states at init time
        self.grayscalePipeline = try Self.makePipeline(device: device, library: library,
                                                        name: "grayscale_kernel")
        self.downsamplePipeline = try Self.makePipeline(device: device, library: library,
                                                         name: "downsample_kernel")
        self.sadPipeline = try Self.makePipeline(device: device, library: library,
                                                  name: "compute_sad_kernel")
        self.warpPipeline = try Self.makePipeline(device: device, library: library,
                                                   name: "warp_translate_kernel")
        self.mergeWeightPipeline = try Self.makePipeline(device: device, library: library,
                                                          name: "compute_merge_weight_kernel")
        self.accumulatePipeline = try Self.makePipeline(device: device, library: library,
                                                         name: "accumulate_kernel")
        self.normalizePipeline = try Self.makePipeline(device: device, library: library,
                                                        name: "normalize_kernel")
        self.tonemapPipeline = try Self.makePipeline(device: device, library: library,
                                                      name: "tonemap_kernel")
        self.clearPipeline = try Self.makePipeline(device: device, library: library,
                                                    name: "clear_kernel")
        self.superResWarpPipeline = try Self.makePipeline(device: device, library: library,
                                                           name: "superres_warp_kernel")
        self.superResWeightPipeline = try Self.makePipeline(device: device, library: library,
                                                             name: "superres_weight_kernel")
        self.hdrFusionWeightPipeline = try Self.makePipeline(device: device, library: library,
                                                              name: "hdr_fusion_weight_kernel")

        // Create texture cache
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            throw MetalError.textureCacheCreationFailed
        }
        self.textureCache = textureCache

        Log.metal.info("MetalContext initialized: \(device.name)")
    }

    private static func makePipeline(
        device: MTLDevice, library: MTLLibrary, name: String
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw MetalError.functionNotFound(name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw MetalError.pipelineFailed(name)
        }
    }

    /// Helper: calculate optimal threadgroup size for a given pipeline and texture dimensions.
    func threadgroupSize(for pipeline: MTLComputePipelineState,
                         width: Int, height: Int) -> (MTLSize, MTLSize) {
        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let threadgroups = MTLSize(
            width: (width + w - 1) / w,
            height: (height + h - 1) / h,
            depth: 1
        )
        return (threadgroups, threadsPerGroup)
    }
}
