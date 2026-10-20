import Accelerate
import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders

/// The Metal device, queue and compiled kernels every stage runs on.
///
/// Images live on the GPU as `rgba32Float` textures, or `rgba16Float` where a stage chooses it
/// (RGB in `.xyz`, alpha unused). On Apple silicon memory is unified, so textures use shared
/// storage and upload/download are plain copies.
/// Holds the memory set aside for renders, so it isn't Sendable: the Engine actor owns one.
public final class GPU {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    private let pipelines: [String: any MTLComputePipelineState]
    /// Where intermediates are made while it has room: memory set aside for renders of their size
    /// (``reservedMemory(width:height:keeping:)``). Without it, each is allocated fresh.
    public var heap: (any MTLHeap)?
    /// The diffusion filter's convolutions (``encodeDiffusionFilter(on:input:filter:pixelSizeUm:)``),
    /// one per FFT size, the most recently used last (``fftConvolution(width:height:)``).
    var fftConvolutions: [(size: SIMD2<Int>, convolution: FFTConvolution)] = []

    public enum SetupError: LocalizedError {
        case noDevice
        case noQueue

        public var errorDescription: String? {
            switch self {
            case .noDevice: "This Mac has no Metal device"
            case .noQueue: "Metal couldn't make a command queue"
            }
        }
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SetupError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.noQueue }

        // Compiled at runtime from the bundled sources: `swift build` doesn't compile .metal files.
        // Fast maths functions: the spectral and colour kernels spend their time in exp, pow and
        // log, which run 2–3× faster, and renders move by under 0.005 of an 8-bit level. IEEE-safe
        // arithmetic, though: the recursive blur's float pairs need it evaluated as written.
        let source = try FileManager.default.contentsOfDirectory(at: shaders, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .fast
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
    public func makeTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba32Float) -> any MTLTexture {
        let descriptor = Self.textureDescriptor(width: width, height: height, pixelFormat: pixelFormat)
        return heap?.makeTexture(descriptor: descriptor) ?? device.makeTexture(descriptor: descriptor)!
    }

    /// A texture of `texture`'s size and pixel format: for a step's intermediates, which keep the
    /// precision it's given.
    public func makeTexture(like texture: any MTLTexture) -> any MTLTexture {
        makeTexture(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
    }

    /// How many textures of a render's size ``reservedMemory(width:height:keeping:)`` sets aside:
    /// what the whole chain holds at once with auto-exposure, halation, grain and glare on, and the
    /// steps the engine keeps for the next render (measured; fewer and some intermediates are
    /// allocated fresh, more and the memory goes unused).
    public static let reservedTextures = 10

    /// The most ``reservedMemory(width:height:keeping:)`` sets aside: a quarter of the Mac's
    /// memory. More and the system compresses and pages memory: at 48 MP on 16 GB, 10 textures
    /// (7.7 GB) rendered slower than 5.
    static let reserveLimit = Int(ProcessInfo.processInfo.physicalMemory / 4)

    /// GPU memory for the intermediates of renders up to `width × height`, for ``heap``: `textures`
    /// textures of that size, as many as fit in ``reserveLimit`` (3.8 GB for ten at 24 MP), or
    /// `kept` if that's as large. A fresh texture costs more than the kernel writing it — the
    /// system clears its pages on first use, 14 ms for 24 MP — and a render makes dozens; from this
    /// memory (an automatic heap) they reuse what earlier ones released. Textures that don't fit
    /// are allocated fresh. All its pages become resident as the first texture is made in it.
    public func reservedMemory(width: Int, height: Int, textures: Int = reservedTextures,
                               keeping kept: (any MTLHeap)? = nil) -> (any MTLHeap)? {
        let slot = device.heapTextureSizeAndAlign(descriptor: Self.textureDescriptor(width: width, height: height))
        let textures = min(textures, Self.reserveLimit / slot.size)
        guard textures > 0 else { return nil }
        if let kept, kept.size >= textures * slot.size { return kept }
        let descriptor = MTLHeapDescriptor()
        descriptor.size = textures * slot.size
        descriptor.storageMode = .shared
        descriptor.type = .automatic
        descriptor.hazardTrackingMode = .tracked
        return device.makeHeap(descriptor: descriptor)
    }

    /// GPU memory in use: what's allocated, less what's free in ``heap`` (other memory set aside
    /// counts as in use).
    var allocatedSize: Int {
        device.currentAllocatedSize - (heap.map { $0.size - $0.usedSize } ?? 0)
    }

    private static func textureDescriptor(width: Int, height: Int,
                                          pixelFormat: MTLPixelFormat = .rgba32Float) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
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
        let rgba = rgba(fromRGB: rgb, width: width, height: height, alpha: 0)
        let texture = device.makeTexture(descriptor: Self.textureDescriptor(width: width, height: height))!
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: rgba, bytesPerRow: width * 16)
        return texture
    }

    /// Downloads a texture (`rgba32Float` or `rgba16Float`) as interleaved RGB floats
    /// (`height × width × 3`).
    public func download(_ texture: any MTLTexture) -> [Float] {
        let (width, height) = (texture.width, texture.height)
        let region = MTLRegionMake2D(0, 0, width, height)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        if texture.pixelFormat == .rgba16Float {
            var half = [Float16](repeating: 0, count: width * height * 4)
            texture.getBytes(&half, bytesPerRow: width * 8, from: region, mipmapLevel: 0)
            // vImage converts planar data, so a row of RGBA is width × 4 values.
            half.withUnsafeBytes { source in
                rgba.withUnsafeMutableBytes { destination in
                    var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                                               height: vImagePixelCount(height), width: vImagePixelCount(width * 4),
                                               rowBytes: width * 8)
                    var destination = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height),
                                                    width: vImagePixelCount(width * 4), rowBytes: width * 16)
                    precondition(vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
                                 == kvImageNoError)
                }
            }
        } else {
            precondition(texture.pixelFormat == .rgba32Float)
            texture.getBytes(&rgba, bytesPerRow: width * 16, from: region, mipmapLevel: 0)
        }
        return rgb(fromRGBA: rgba, width: width, height: height)
    }

    /// `texture`'s RGB, already encoded in `colorSpace`, as an image file stores it: `bits` (16
    /// or 8) per channel, three channels, clipped to [0, 1], NaN as black and rounded as vImage
    /// rounds (`pack_rgb16`, `pack_rgb8`). The GPU makes the integers in memory the image reads in
    /// place, so no float copy of the photo comes back.
    public func image(of texture: any MTLTexture, bits: Int, colorSpace: CGColorSpace) throws -> CGImage {
        precondition(bits == 16 || bits == 8)
        let bytesPerRow = texture.width * 3 * bits / 8
        let buffer = device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared)!
        try run { encoder in
            encode(bits == 16 ? "pack_rgb16" : "pack_rgb8", on: encoder, textures: [texture], grid: texture.size) {
                $0.setBuffer(buffer, offset: 0, index: 0)
            }
        }
        // The image keeps the buffer until it's released.
        let provider = CGDataProvider(dataInfo: Unmanaged.passRetained(buffer).toOpaque(), data: buffer.contents(),
                                      size: buffer.length) { info, _, _ in
            Unmanaged<AnyObject>.fromOpaque(info!).release()
        }!
        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: bits, bitsPerPixel: 3 * bits,
                       bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bits == 16 ? .byteOrder16Little : [],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
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
/// (``GPU/heap``) for the textures made after. (A heap with aliasing would
/// reuse memory within one command buffer, but needs every texture's last use marked by hand.)
public final class Encoder {
    /// Allocation that triggers a new command buffer: under one 24 MP texture (384 MB), so dead
    /// intermediates don't pile up; waiting between command buffers costs little next to kernels
    /// that run for milliseconds at that size.
    static let budget = 256 << 20

    private let gpu: GPU
    private var commandBuffer: any MTLCommandBuffer
    /// Command buffers Metal Performance Shaders committed, continuing in a new one: their errors
    /// are checked as the current one completes.
    private var committedByShaders: [any MTLCommandBuffer] = []
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

    /// Encodes Metal Performance Shaders work between kernels, MPSGraph's too. MPSGraph may commit
    /// the command buffer and continue in a new one (it does for a 24 MP FFT): encoding continues
    /// in that one.
    func encodeCommands(_ body: (MPSCommandBuffer) -> Void) {
        flushIfOverBudget()
        guard !isCancelled else { return }
        compute.endEncoding()
        let commands = MPSCommandBuffer(commandBuffer: commandBuffer)
        body(commands)
        if commands.rootCommandBuffer !== commandBuffer {
            committedByShaders.append(commandBuffer)
            commandBuffer = commands.rootCommandBuffer
        }
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
        for completed in committedByShaders + [commandBuffer] where error == nil {
            error = completed.error
        }
        committedByShaders = []
    }
}

/// The bundled Metal sources (`Shaders/`), concatenated in file-name order into one library.
let shaders = Bundle.module.resourceURL!.appending(component: "Shaders")

extension MTLTexture {
    /// One thread per pixel.
    public var size: MTLSize { MTLSize(width: width, height: height, depth: 1) }
}
