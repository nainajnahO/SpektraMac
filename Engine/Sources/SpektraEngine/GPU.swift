import Foundation
import Metal

/// The Metal device, queue and compiled kernels every stage runs on.
///
/// Images live on the GPU as `rgba32Float` textures (RGB in `.xyz`, alpha unused). On Apple
/// silicon memory is unified, so textures use shared storage and upload/download are plain copies.
/// Holds the memory set aside for renders, so it isn't Sendable: the Engine actor owns one.
public final class GPU {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    private let pipelines: [String: any MTLComputePipelineState]
    /// Memory set aside by ``reserveMemory(width:height:)``, where intermediates are made.
    private var heap: (any MTLHeap)?

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

    /// An image-sized texture the kernels can read and write, from the reserved memory while it
    /// has room. Its contents are undefined until written: every kernel writes its whole output.
    public func makeTexture(width: Int, height: Int) -> any MTLTexture {
        let descriptor = Self.textureDescriptor(width: width, height: height)
        return heap?.makeTexture(descriptor: descriptor) ?? device.makeTexture(descriptor: descriptor)!
    }

    /// How many full-size textures ``reserveMemory(width:height:)`` sets aside: what the whole
    /// chain holds at once with auto-exposure, halation, grain and glare on, and the steps the
    /// engine keeps for the next render (measured; fewer and some intermediates are allocated
    /// fresh, more and the memory goes unused).
    static let reservedTextures = 10

    /// The most ``reserveMemory(width:height:)`` sets aside: a quarter of the Mac's memory. More
    /// and the system compresses and pages memory: at 48 MP on 16 GB, 10 textures (7.7 GB)
    /// rendered slower than 5.
    static let reserveLimit = Int(ProcessInfo.processInfo.physicalMemory / 4)

    /// Sets aside GPU memory for the intermediates of renders up to `width × height`
    /// (``reservedTextures`` textures, as many as fit in ``reserveLimit``: 3.8 GB at 24 MP),
    /// replacing what was set aside before. A fresh texture costs more than the kernel writing
    /// it — the system clears its pages on first use, 14 ms for 24 MP — and a render makes
    /// dozens; from this memory (an automatic heap) they reuse what earlier ones released.
    /// Textures that don't fit are allocated fresh.
    public func reserveMemory(width: Int, height: Int) {
        let slot = device.heapTextureSizeAndAlign(descriptor: Self.textureDescriptor(width: width, height: height))
        let textures = min(Self.reservedTextures, Self.reserveLimit / slot.size)
        guard textures > 0 else {
            heap = nil
            return
        }
        let descriptor = MTLHeapDescriptor()
        descriptor.size = textures * slot.size
        descriptor.storageMode = .shared
        descriptor.type = .automatic
        descriptor.hazardTrackingMode = .tracked
        heap = device.makeHeap(descriptor: descriptor)
    }

    /// GPU memory in use: what's allocated, less what's reserved and free.
    var allocatedSize: Int {
        device.currentAllocatedSize - (heap.map { $0.size - $0.usedSize } ?? 0)
    }

    private static func textureDescriptor(width: Int, height: Int) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return descriptor
    }

    /// An image-sized texture whose pixels live in a shared buffer, rows `bufferBytesPerRow` apart,
    /// so the CPU reads them in place (memory is unified): for the open photo, which Core Image
    /// renders and auto-exposure measures. Not from the reserved memory: it outlives renders.
    public func makeReadableTexture(width: Int, height: Int) -> any MTLTexture {
        let alignment = device.minimumLinearTextureAlignment(for: .rgba32Float)
        let bytesPerRow = (width * 16 + alignment - 1) / alignment * alignment
        let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared)!
        return buffer.makeTexture(descriptor: Self.textureDescriptor(width: width, height: height), offset: 0,
                                  bytesPerRow: bytesPerRow)!
    }

    /// Uploads interleaved RGB floats (row-major, `height × width × 3`, NumPy's layout). Uploads
    /// outlive renders (tables, images opened by tests and the CLI), so they don't take reserved
    /// memory.
    public func upload(rgb: [Float], width: Int, height: Int) -> any MTLTexture {
        precondition(rgb.count == width * height * 3)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = rgb[pixel * 3]
            rgba[pixel * 4 + 1] = rgb[pixel * 3 + 1]
            rgba[pixel * 4 + 2] = rgb[pixel * 3 + 2]
        }
        let texture = device.makeTexture(descriptor: Self.textureDescriptor(width: width, height: height))!
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

    /// Encodes one kernel over `grid` threads (usually a texture's ``MTLTexture/size``: one per
    /// pixel). `setArguments` binds anything beyond the textures (constants with `setBytes`,
    /// buffers); textures bind at indices 0, 1, … in order.
    public func encode(
        _ kernel: String,
        on encoder: Encoder,
        textures: [any MTLTexture],
        grid: MTLSize,
        setArguments: (any MTLComputeCommandEncoder) -> Void = { _ in }
    ) {
        guard let pipeline = pipelines[kernel] else { preconditionFailure("No Metal kernel named \(kernel)") }
        encoder.flushIfOverBudget()
        guard !encoder.isCancelled else { return }
        let compute = encoder.compute
        compute.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            compute.setTexture(texture, index: index)
        }
        setArguments(compute)
        let width = pipeline.threadExecutionWidth
        let height = grid.height > 1 ? pipeline.maxTotalThreadsPerThreadgroup / width : 1
        compute.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }

    /// Runs what `body` encodes, waits for the GPU to finish and returns `body`'s result
    /// (typically the output texture, complete by then). Throws `CancellationError` if the
    /// task is cancelled meanwhile.
    public func run<Result>(_ body: (Encoder) -> Result) throws -> Result {
        let encoder = Encoder(gpu: self)
        let result = body(encoder)
        try encoder.finish()
        return result
    }
}

/// Where the kernels of one ``GPU/run(_:)`` are encoded. A command buffer keeps every texture its
/// commands use alive until it completes, which for the whole chain on a 24 MP image is tens of
/// gigabytes of intermediates. So once the commands encoded so far have allocated ``budget``,
/// they are committed and waited for, and encoding continues in a new command buffer: the
/// intermediates only that work used are freed, back to the reserved memory
/// (``GPU/reserveMemory(width:height:)``) for the textures made after. (A heap with aliasing would
/// reuse memory within one command buffer, but needs every texture's last use marked by hand.)
public final class Encoder {
    /// Allocation that triggers a new command buffer: under one 24 MP texture (384 MB), so dead
    /// intermediates don't pile up; waiting between command buffers costs little next to kernels
    /// that run for milliseconds at that size.
    static let budget = 256 << 20

    private let gpu: GPU
    private var commandBuffer: any MTLCommandBuffer
    /// The current command buffer's encoder, for kernels encoded outside ``GPU``.
    public private(set) var compute: any MTLComputeCommandEncoder
    private var allocatedAtStart: Int
    private var error: (any Error)?
    /// The most GPU memory in use at any kernel encoded so far.
    public private(set) var peakAllocatedSize: Int
    /// Set once the task is cancelled: from then on kernels aren't encoded, so the work stops at
    /// the next commit, and ``finish()`` throws.
    private(set) var isCancelled = false

    init(gpu: GPU) {
        self.gpu = gpu
        commandBuffer = gpu.queue.makeCommandBuffer()!
        compute = commandBuffer.makeComputeCommandEncoder()!
        allocatedAtStart = gpu.allocatedSize
        peakAllocatedSize = allocatedAtStart
    }

    func flushIfOverBudget() {
        isCancelled = isCancelled || Task.isCancelled
        let allocated = gpu.allocatedSize
        peakAllocatedSize = max(peakAllocatedSize, allocated)
        guard allocated - allocatedAtStart > Self.budget else { return }
        complete()
        commandBuffer = gpu.queue.makeCommandBuffer()!
        compute = commandBuffer.makeComputeCommandEncoder()!
        allocatedAtStart = gpu.allocatedSize
    }

    /// Encodes work that needs the command buffer itself (Metal Performance Shaders) between kernels.
    func encodeCommands(_ body: (any MTLCommandBuffer) -> Void) {
        flushIfOverBudget()
        guard !isCancelled else { return }
        compute.endEncoding()
        body(commandBuffer)
        compute = commandBuffer.makeComputeCommandEncoder()!
    }

    /// Completes the last command buffer; throws the first error any of them reported, or
    /// `CancellationError` if the task was cancelled.
    func finish() throws {
        peakAllocatedSize = max(peakAllocatedSize, gpu.allocatedSize)
        complete()
        if let error { throw error }
        if isCancelled { throw CancellationError() }
    }

    private func complete() {
        compute.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if error == nil { error = commandBuffer.error }
    }
}

/// The bundled Metal sources (`Shaders/`), concatenated in file-name order into one library.
let shaders = Bundle.module.resourceURL!.appending(component: "Shaders")

extension MTLTexture {
    /// One thread per pixel.
    public var size: MTLSize { MTLSize(width: width, height: height, depth: 1) }
}
