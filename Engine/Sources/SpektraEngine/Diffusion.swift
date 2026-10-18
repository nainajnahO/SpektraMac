import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Host side of `Shaders/Diffusion.metal`: Spektrafilm's diffusion filter
/// (`apply_diffusion_filter_um`), on the camera's lens and the enlarger's.
extension GPU {
    /// `apply_diffusion_filter_um` when `filter.active`: (1 − p) · image + p · (image ⊛ PSF), p the
    /// light the filter deflects at its strength (``Parameters/DiffusionFilter/scatterFraction``),
    /// the PSF its family's core, halo and bloom of exponentials, sampled within a square `radius`
    /// and normalised per channel. In place in `input`.
    ///
    /// Convolved by FFT, as Python does: the exponentials' cusp at the centre and long tails are
    /// what Spektrafilm convolves exactly here, where its other blurs approximate an exponential
    /// by three Gaussians (off by 0.05–0.24 EV around bright edges at the 99th percentile, and
    /// 27 blurs a filter). One channel at a time: MPSGraph's FFT needs about 15× its signal's
    /// memory while it runs (3.8 GB for a 24 MP channel padded, 11.5 GB for all three at once).
    public func encodeDiffusionFilter(on encoder: Encoder, input: any MTLTexture,
                                      filter: Parameters.DiffusionFilter, pixelSizeUm: Double) -> any MTLTexture {
        var amount = Float(filter.scatterFraction)
        guard filter.active, filter.spatialScale > 0, amount > 0 else { return input }
        let shape = filter.filterFamily.shape
        // Python's kernel radius: 8 of the widest bloom's decay lengths, which hold 99.95 % of its
        // light, and under half the image, which it's padded by on each side (mirrored).
        let bloomMaxPx = shape.bloom.lambdaUm * shape.bloom.spread * filter.spatialScale / pixelSizeUm
        var radius = Int32(min(Int(max(8 * bloomMaxPx, 5).rounded(.up)), max(min(input.width, input.height) / 2 - 1, 1)))
        // The padded image fits as is: the pixels kept read no further than `radius` away, so the
        // FFT's wrap-around never reaches them.
        var size = SIMD2<UInt32>(UInt32(Self.fftSize(atLeast: input.width + 2 * Int(radius))),
                                 UInt32(Self.fftSize(atLeast: input.height + 2 * Int(radius))))
        let grid = MTLSize(width: Int(size.x), height: Int(size.y), depth: 1)
        let length = Int(size.x) * Int(size.y) * MemoryLayout<Float>.stride
        let (signal, psf, blurred) = (device.makeBuffer(length: length, options: .storageModePrivate)!,
                                      device.makeBuffer(length: length, options: .storageModePrivate)!,
                                      device.makeBuffer(length: length, options: .storageModePrivate)!)
        let components = filter.components(pixelSizeUm: pixelSizeUm)
        for channel in 0..<3 {
            // (1/λ, weight / (2πλ²)) per exponential.
            let terms = components.map { SIMD2<Float>(Float(1 / $0.lambda), Float($0.weight[channel] / (2 * .pi * $0.lambda * $0.lambda))) }
            var (count, channel) = (UInt32(terms.count), UInt32(channel))
            encode("diffusion_psf", on: encoder, textures: [], grid: grid) {
                $0.setBuffer(psf, offset: 0, index: 0)
                $0.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
                $0.setBytes(&radius, length: 4, index: 2)
                $0.setBytes(terms, length: terms.count * MemoryLayout<SIMD2<Float>>.stride, index: 3)
                $0.setBytes(&count, length: 4, index: 4)
            }
            encode("diffusion_pad", on: encoder, textures: [input], grid: grid) {
                $0.setBuffer(signal, offset: 0, index: 0)
                $0.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
                $0.setBytes(&radius, length: 4, index: 2)
                $0.setBytes(&channel, length: 4, index: 3)
            }
            let convolution = fftConvolution(width: Int(size.x), height: Int(size.y))
            encoder.encodeCommands {
                convolution.encode(to: $0, signal: signal, kernel: psf, result: blurred, width: Int(size.x), height: Int(size.y))
            }
            encode("diffusion_blend", on: encoder, textures: [input], grid: input.size) {
                $0.setBuffer(blurred, offset: 0, index: 0)
                $0.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
                $0.setBytes(&radius, length: 4, index: 2)
                $0.setBytes(&channel, length: 4, index: 3)
                $0.setBytes(&amount, length: 4, index: 4)
            }
        }
        return input
    }

    /// The convolution for FFTs of `width × height`. An MPSGraph keeps memory for each size it has
    /// run until it's released (40 MB at the preview's, 0.5 GB at 24 MP's), and every window size
    /// is a new one, so each size has its own and only the last four used stay: the preview's,
    /// the thumbnails', the screen size's and the whole photo's. A new size costs 0.05–0.45 s the
    /// first time, as MPSGraph compiles for it.
    func fftConvolution(width: Int, height: Int) -> FFTConvolution {
        let size = SIMD2(width, height)
        if let index = fftConvolutions.firstIndex(where: { $0.size == size }) {
            fftConvolutions.append(fftConvolutions.remove(at: index))
        } else {
            if fftConvolutions.count == 4 {
                fftConvolutions.removeFirst()
            }
            fftConvolutions.append((size, FFTConvolution()))
        }
        return fftConvolutions.last!.convolution
    }

    /// The smallest even number ≥ `n` with no prime factor but 2, 3 and 5. MPSGraph's FFT is
    /// slow on other sizes: a 1894-row signal (2 × 947) took 192 ms and 1.7 GB where 1920 rows
    /// took 12 ms and 0.9 GB. Python's `fftconvolve` pads to such sizes too.
    static func fftSize(atLeast n: Int) -> Int {
        var size = max(n, 2)
        while true {
            var rest = size
            for factor in [2, 3, 5] {
                while rest % factor == 0 { rest /= factor }
            }
            if rest == 1 && size % 2 == 0 { return size }
            size += 1
        }
    }
}

/// Circular convolution of a real signal with a real kernel, both `height × width` row-major, by
/// FFT, divided by the kernel's sum.
final class FFTConvolution {
    private let graph = MPSGraph()
    private let signal: MPSGraphTensor
    private let kernel: MPSGraphTensor
    private let result: MPSGraphTensor

    init() {
        signal = graph.placeholder(shape: nil, dataType: .float32, name: nil)
        kernel = graph.placeholder(shape: nil, dataType: .float32, name: nil)
        let axes: [NSNumber] = [0, 1]
        let forward = MPSGraphFFTDescriptor()
        let inverse = MPSGraphFFTDescriptor()
        inverse.inverse = true
        inverse.scalingMode = .size
        let product = graph.multiplication(graph.realToHermiteanFFT(signal, axes: axes, descriptor: forward, name: nil),
                                           graph.realToHermiteanFFT(kernel, axes: axes, descriptor: forward, name: nil),
                                           name: nil)
        result = graph.division(graph.HermiteanToRealFFT(product, axes: axes, descriptor: inverse, name: nil),
                                graph.reductionSum(with: kernel, axes: axes, name: nil), name: nil)
    }

    func encode(to commandBuffer: MPSCommandBuffer, signal: any MTLBuffer, kernel: any MTLBuffer, result: any MTLBuffer,
                width: Int, height: Int) {
        let shape: [NSNumber] = [NSNumber(value: height), NSNumber(value: width)]
        graph.encode(to: commandBuffer,
                     feeds: [self.signal: MPSGraphTensorData(signal, shape: shape, dataType: .float32),
                             self.kernel: MPSGraphTensorData(kernel, shape: shape, dataType: .float32)],
                     targetOperations: nil,
                     resultsDictionary: [self.result: MPSGraphTensorData(result, shape: shape, dataType: .float32)],
                     executionDescriptor: nil)
    }
}

extension Parameters.DiffusionFilter {
    /// `_strength_to_scatter`: the fraction of the light the filter deflects, from the strength's
    /// commercial stop (interpolated on log2 of the strength, held at the ends) × the family's
    /// gain. 0 at no strength.
    var scatterFraction: Double {
        guard strength > 0 else { return 0 }
        let stops = [0.125, 0.25, 0.5, 1, 2].map(log2)
        let fractions = [0.10, 0.20, 0.35, 0.55, 0.75]
        let fraction = interp(log2(max(strength, 1e-6)), stops, fractions)
        return min(max(fraction * filterFamily.shape.gain, 0), 0.99)
    }

    /// `_radial_components`: the PSF's exponentials, exp(−r/λ)/(2πλ²) with λ in pixels, and their
    /// weights per channel (the family's group weight times the exponential's share of its
    /// group). The halo's shares differ per channel (``Family/haloChannelWeights(_:warmth:)``).
    func components(pixelSizeUm: Double) -> [(lambda: Double, weight: SIMD3<Double>)] {
        let shape = filterFamily.shape
        let scale = max(spatialScale, 1e-6) / pixelSizeUm
        let core = shape.core.expanded(bloom: false), halo = shape.halo.expanded(bloom: false)
        let bloom = shape.bloom.expanded(bloom: true)
        let haloChannels = Family.haloChannelWeights(halo.weights, warmth: shape.haloWarmthBase + haloWarmth)
        func lambda(_ um: Double) -> Double { max(um * scale, 1e-6) }
        return zip(core.lambdas, core.weights).map { (lambda($0), SIMD3(repeating: shape.coreWeight * $1)) }
            + zip(halo.lambdas, haloChannels).map { (lambda($0), shape.haloWeight * $1) }
            + zip(bloom.lambdas, bloom.weights).map { (lambda($0), SIMD3(repeating: shape.bloomWeight * $1)) }
    }
}

extension Parameters.DiffusionFilter.Family {
    /// `_DIFFUSION_FILTER_SHAPES` and `_DIFFUSION_FAMILY_TOTAL_GAIN`: the PSF a family spreads its
    /// deflected light by, as three groups of exponentials (core, halo and bloom) and their
    /// weights, and the share of light it deflects relative to the strength's table.
    struct Shape {
        let core: Group
        let halo: Group
        let bloom: Group
        let coreWeight: Double
        let haloWeight: Double
        let bloomWeight: Double
        let haloWarmthBase: Double
        let gain: Double
    }

    /// A group's decay lengths: `count` on a geometric progression from `lambdaUm / spread` to
    /// `lambdaUm · spread`; a bloom's weighted by λ^(2 − alpha), so it falls off as r^−alpha.
    struct Group {
        let lambdaUm: Double
        let spread: Double
        let count: Int
        var alpha = 3.0

        /// `_expand_group`: the decay lengths in µm and their weights, summing to 1.
        func expanded(bloom: Bool) -> (lambdas: [Double], weights: [Double]) {
            guard count > 1 && spread > 1 else { return ([lambdaUm], [1]) }
            let (low, high) = (log(lambdaUm / spread), log(lambdaUm * spread))
            let lambdas = (0..<count).map { exp(low + (high - low) * Double($0) / Double(count - 1)) }
            let weights = bloom ? lambdas.map { pow($0, 2 - alpha) } : Array(repeating: 1.0, count: count)
            let total = weights.reduce(0, +)
            return (lambdas, weights.map { $0 / total })
        }
    }

    var shape: Shape {
        switch self {
        case .glimmerglass:
            Shape(core: Group(lambdaUm: 10, spread: 1.5, count: 2), halo: Group(lambdaUm: 50, spread: 2, count: 3),
                  bloom: Group(lambdaUm: 260, spread: 2.5, count: 4, alpha: 3.2),
                  coreWeight: 0.60, haloWeight: 0.30, bloomWeight: 0.10, haloWarmthBase: 0, gain: 0.65)
        case .blackProMist:
            Shape(core: Group(lambdaUm: 16, spread: 1.5, count: 2), halo: Group(lambdaUm: 95, spread: 2, count: 3),
                  bloom: Group(lambdaUm: 380, spread: 2.5, count: 4, alpha: 3.5),
                  coreWeight: 0.40, haloWeight: 0.47, bloomWeight: 0.13, haloWarmthBase: 0.65, gain: 0.75)
        case .proMist:
            Shape(core: Group(lambdaUm: 14, spread: 1.5, count: 2), halo: Group(lambdaUm: 150, spread: 2, count: 3),
                  bloom: Group(lambdaUm: 650, spread: 2.5, count: 4, alpha: 2.9),
                  coreWeight: 0.28, haloWeight: 0.42, bloomWeight: 0.30, haloWarmthBase: 0.40, gain: 1.05)
        case .cinebloom:
            Shape(core: Group(lambdaUm: 20, spread: 1.5, count: 2), halo: Group(lambdaUm: 200, spread: 2, count: 3),
                  bloom: Group(lambdaUm: 1000, spread: 2.5, count: 4, alpha: 2.5),
                  coreWeight: 0.22, haloWeight: 0.30, bloomWeight: 0.48, haloWarmthBase: 0.85, gain: 1.00)
        }
    }

    /// `_halo_channel_weights`: the halo's weights per channel, warm light moved to its outer
    /// exponentials and cool light to its inner ones (the reverse below 0) along the warmth axis
    /// (R +1.30, G +0.15, B −1.45), keeping each channel's total. Warmth is clamped to ±1.5.
    static func haloChannelWeights(_ weights: [Double], warmth: Double) -> [SIMD3<Double>] {
        guard weights.count > 1 else { return weights.map { SIMD3(repeating: $0) } }
        let warmth = min(max(warmth, -1.5), 1.5)
        let axis = SIMD3(1.30, 0.15, -1.45)
        let total = weights.reduce(0, +)
        // From −1 at the innermost to +1 at the outermost, centred on the weights.
        let gradient = weights.indices.map { -1 + 2 * Double($0) / Double(weights.count - 1) }
        let centre = zip(gradient, weights).map(*).reduce(0, +) / total
        var channels = [[Double]](repeating: [], count: 3)
        for channel in 0..<3 {
            let raw = zip(weights, gradient).map { max($0 * (1 + warmth * axis[channel] * ($1 - centre)), 0) }
            let sum = raw.reduce(0, +)
            channels[channel] = sum > 0 ? raw.map { $0 * total / sum } : weights
        }
        return weights.indices.map { SIMD3(channels[0][$0], channels[1][$0], channels[2][$0]) }
    }
}
