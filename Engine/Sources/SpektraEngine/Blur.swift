import Foundation
import Metal
import MetalPerformanceShaders

/// Host side of `Shaders/Blur.metal`. Sigmas are in pixels, one per channel.
extension GPU {
    /// Spektrafilm's `fast_gaussian_filter`: per channel, σ ≤ 0 leaves the channel alone, σ < 3
    /// runs a separable FIR (radius `Int(truncate·σ + 0.5)`, reflected edges), σ ≥ 3 the Young–van
    /// Vliet recursive filter (replicated edges). Channels on another path pass through unchanged.
    ///
    /// When every channel takes the same σ ≥ 3 (halation's bounces, the couplers' diffusion), Apple's
    /// Gaussian blur (`MPSImageGaussianBlur`, edges clamped) runs instead: 6–13 ms at 24 MP against
    /// the recursive filter's 22 ms, which makes four full passes over memory whatever σ. It's the
    /// closer of the two to an exact Gaussian (within 0.002 on random pixels, where the recursive
    /// filter is up to 0.2 off at the borders and 0.01 inside), so renders part from Python's: by up
    /// to 5 of 255 levels inside the image and 20 on the rows at the border, with no difference to
    /// see side by side at 100 %.
    public func encodeGaussianBlur(on encoder: Encoder, input: any MTLTexture,
                                   output: any MTLTexture, sigma: SIMD3<Double>, truncate: Double = 3) {
        let onFIR = (0..<3).map { sigma[$0] > 0 && sigma[$0] < 3 }
        let onIIR = (0..<3).map { sigma[$0] >= 3 }
        guard onFIR.contains(true) || onIIR.contains(true) else {
            encodeScale(on: encoder, input: input, output: output, by: 1)
            return
        }
        if onIIR.allSatisfy({ $0 }) && sigma.x == sigma.y && sigma.y == sigma.z {
            let blur = MPSImageGaussianBlur(device: device, sigma: Float(sigma.x))
            blur.edgeMode = .clamp
            // It can't write over its input: blurred elsewhere and copied back.
            let destination = input === output ? makeTexture(width: input.width, height: input.height) : output
            encoder.encodeCommands { blur.encode(commandBuffer: $0, sourceTexture: input, destinationTexture: destination) }
            if destination !== output {
                encodeScale(on: encoder, input: destination, output: output, by: 1)
            }
            return
        }
        // One scratch texture for every pass, so `output` may be `input`: the FIR runs input →
        // scratch → output, then the recursive filter output → scratch → output → scratch → output.
        let scratch = makeTexture(width: input.width, height: input.height)
        var source = input
        if onFIR.contains(true) {
            encodeFIR(on: encoder, input: source, scratch: scratch, output: output, sigma: sigma, channels: onFIR,
                      truncate: truncate)
            source = output
        }
        if onIIR.contains(true) {
            encodeYoungVanVliet(on: encoder, input: source, scratch: scratch, output: output, sigma: sigma,
                                channels: onIIR)
        }
    }

    /// Spektrafilm's `fast_exponential_filter` (3 Gaussians): approximates convolving each channel
    /// with exp(−r/λ)/(2πλ²) by a fixed mixture of Gaussians with σ_k = ratio_k · λ.
    public func encodeExponentialBlur(on encoder: Encoder, input: any MTLTexture,
                                      output: any MTLTexture, decay: SIMD3<Double>, truncate: Double = 3) {
        // (amplitude, σ/λ), copied from _EXPONENTIAL_GAUSSIAN_FITS[3]; amplitudes sum to 1.
        let mixture: [(amplitude: Double, ratio: Double)] = [(0.1633, 0.5360), (0.6496, 1.5236), (0.1870, 2.7684)]
        let component = makeTexture(width: input.width, height: input.height)
        let sum = input === output ? makeTexture(width: input.width, height: input.height) : output
        for (index, term) in mixture.enumerated() {
            encodeGaussianBlur(on: encoder, input: input, output: component, sigma: decay * term.ratio, truncate: truncate)
            if index == 0 {
                encodeScale(on: encoder, input: component, output: sum, by: term.amplitude)
            } else {
                encodeAddScaled(on: encoder, accumulator: sum, input: component, output: sum,
                                weight: SIMD3(repeating: term.amplitude))
            }
        }
        if sum !== output {
            encodeScale(on: encoder, input: sum, output: output, by: 1)
        }
    }

    /// `accumulator + weight · input`, per channel.
    public func encodeAddScaled(on encoder: Encoder, accumulator: any MTLTexture,
                                input: any MTLTexture, output: any MTLTexture, weight: SIMD3<Double>) {
        var weight = SIMD3<Float>(weight)
        encode("add_scaled", on: encoder, textures: [accumulator, input, output], grid: output.size) {
            $0.setBytes(&weight, length: MemoryLayout<SIMD3<Float>>.size, index: 0)
        }
    }

    private func encodeFIR(on encoder: Encoder, input: any MTLTexture, scratch: any MTLTexture,
                           output: any MTLTexture, sigma: SIMD3<Double>, channels: [Bool], truncate: Double) {
        // _gaussian_kernel_1d in f64; a channel off this path gets the identity (one tap of 1).
        let radii = (0..<3).map { channels[$0] ? Int(truncate * sigma[$0] + 0.5) : 0 }
        var radius = Int32(radii.max()!)
        var taps = [SIMD4<Float>](repeating: .zero, count: 2 * Int(radius) + 1)
        for channel in 0..<3 {
            let r = radii[channel]
            let weights = channels[channel]
                ? (-r...r).map { exp(-0.5 * pow(Double($0) / sigma[channel], 2)) }
                : [1.0]
            let total = weights.reduce(0, +)
            for (index, weight) in weights.enumerated() {
                taps[Int(radius) - r + index][channel] = Float(weight / total)
            }
        }
        for (kernel, source, destination) in [("fir_vertical", input, scratch), ("fir_horizontal", scratch, output)] {
            encode(kernel, on: encoder, textures: [source, destination], grid: destination.size) {
                $0.setBytes(taps, length: taps.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
                $0.setBytes(&radius, length: 4, index: 1)
            }
        }
    }

    private func encodeYoungVanVliet(on encoder: Encoder, input: any MTLTexture, scratch: any MTLTexture,
                                     output: any MTLTexture, sigma: SIMD3<Double>, channels: [Bool]) {
        // _yvv_coeffs in f64, split into float hi/lo pairs; a channel off this path gets
        // B = 1, B1 = B2 = B3 = 0, which copies it exactly.
        var coefficients = [SIMD4<Float>](repeating: .zero, count: 8)
        for channel in 0..<3 {
            var values = [1.0, 0, 0, 0]
            if channels[channel] {
                let s = sigma[channel]
                let q = s >= 2.5 ? 0.98711 * s - 0.96330 : 3.97156 - 4.14554 * (1 - 0.26891 * s).squareRoot()
                let (q2, q3) = (q * q, q * q * q)
                let b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3
                let b1 = 2.44413 * q + 2.85619 * q2 + 1.26661 * q3
                let b2 = -(1.4281 * q2 + 1.26661 * q3)
                let b3 = 0.422205 * q3
                values = [1 - (b1 + b2 + b3) / b0, b1 / b0, b2 / b0, b3 / b0]
            }
            for (index, value) in values.enumerated() {
                let hi = Float(value)
                coefficients[2 * index][channel] = hi
                coefficients[2 * index + 1][channel] = Float(value - Double(hi))
            }
        }
        let sweeps = [("yvv_rows_forward", input, scratch, input.height), ("yvv_rows_backward", scratch, output, input.height),
                      ("yvv_columns_forward", output, scratch, input.width), ("yvv_columns_backward", scratch, output, input.width)]
        for (kernel, source, destination, lines) in sweeps {
            encode(kernel, on: encoder, textures: [source, destination], grid: MTLSize(width: lines, height: 1, depth: 1)) {
                $0.setBytes(coefficients, length: coefficients.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            }
        }
    }
}
