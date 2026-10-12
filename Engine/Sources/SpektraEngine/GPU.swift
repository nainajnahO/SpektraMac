import Foundation
import Metal

/// The Metal device, queue and compiled kernels every stage runs on.
///
/// Images live on the GPU as `rgba32Float` textures (RGB in `.xyz`, alpha unused). On Apple
/// silicon memory is unified, so textures use shared storage and upload/download are plain copies.
public final class GPU: Sendable {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    private let pipelines: [String: any MTLComputePipelineState]

    public enum SetupError: Error {
        case noDevice
        case noQueue
        case missingKernel(String)
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SetupError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.noQueue }

        // Compiled at runtime from the bundled sources: `swift build` doesn't compile .metal files.
        // IEEE-safe maths and precise functions so results track the f64 Python reference.
        let shaders = Bundle.module.resourceURL!.appending(component: "Shaders")
        let source = try FileManager.default.contentsOfDirectory(at: shaders, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(source: source, options: options)

        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in library.functionNames {
            pipelines[name] = try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        self.device = device
        self.queue = queue
        self.pipelines = pipelines
    }

    /// An empty image-sized texture the kernels can read and write.
    public func makeTexture(width: Int, height: Int) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    /// Uploads interleaved RGB floats (row-major, `height × width × 3`, NumPy's layout).
    public func upload(rgb: [Float], width: Int, height: Int) -> any MTLTexture {
        precondition(rgb.count == width * height * 3)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = rgb[pixel * 3]
            rgba[pixel * 4 + 1] = rgb[pixel * 3 + 1]
            rgba[pixel * 4 + 2] = rgb[pixel * 3 + 2]
        }
        let texture = makeTexture(width: width, height: height)
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: rgba, bytesPerRow: width * 16)
        return texture
    }

    /// Downloads a texture as interleaved RGB floats (`height × width × 3`).
    public func download(_ texture: any MTLTexture) -> [Float] {
        let (width, height) = (texture.width, texture.height)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        texture.getBytes(&rgba, bytesPerRow: width * 16,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return rgb
    }

    /// Encodes one kernel over every pixel of `grid`. `setArguments` binds anything beyond the
    /// textures (constants with `setBytes`, buffers); textures bind at indices 0, 1, … in order.
    public func encode(
        _ kernel: String,
        on encoder: any MTLComputeCommandEncoder,
        textures: [any MTLTexture],
        grid: any MTLTexture,
        setArguments: (any MTLComputeCommandEncoder) -> Void = { _ in }
    ) {
        guard let pipeline = pipelines[kernel] else { preconditionFailure("No Metal kernel named \(kernel)") }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        setArguments(encoder)
        let width = pipeline.threadExecutionWidth
        let height = pipeline.maxTotalThreadsPerThreadgroup / width
        encoder.dispatchThreads(MTLSize(width: grid.width, height: grid.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }

    /// Runs `body` in one command buffer and waits for the GPU to finish.
    public func run(_ body: (any MTLComputeCommandEncoder) -> Void) throws {
        let commandBuffer = queue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        body(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
    }
}
