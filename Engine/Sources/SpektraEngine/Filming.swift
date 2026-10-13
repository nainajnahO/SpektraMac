import Metal
import simd

/// Host side of the spatial filming effects in `Shaders/Filming.metal` (diffusion.py).
extension GPU {
    /// `boost_highlights` (boost_ev > 0): reconstructs pre-clip irradiance above
    /// midgray·2^protect_ev, normalised by the image's maximum raw value.
    public func encodeBoostHighlights(on encoder: Encoder, input: any MTLTexture,
                                      boostEv: Double, boostRange: Double, protectEv: Double) -> any MTLTexture {
        precondition(boostEv >= 0 && (0...1).contains(boostRange) && protectEv >= 0)
        let maxima = device.makeBuffer(length: (input.height + 1) * 4, options: .storageModePrivate)!
        var rows = UInt32(input.height)
        encode("row_max", on: encoder, textures: [input], grid: MTLSize(width: input.height, height: 1, depth: 1)) {
            $0.setBuffer(maxima, offset: 0, index: 0)
        }
        encode("total_max", on: encoder, textures: [], grid: MTLSize(width: 1, height: 1, depth: 1)) {
            $0.setBuffer(maxima, offset: 0, index: 0)
            $0.setBytes(&rows, length: 4, index: 1)
        }
        let output = makeTexture(like: input)
        var settings = SIMD3<Float>(Float(boostEv), Float(boostRange), Float(protectEv))
        encode("boost_highlights", on: encoder, textures: [input, output], grid: output.size) {
            $0.setBuffer(maxima, offset: 0, index: 0)
            $0.setBytes(&settings, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
        }
        return output
    }

    /// `apply_halation_um` when `halation.active`: in-emulsion scatter (Gaussian core +
    /// exponential tail, energy-preserving, blended by scatter_amount), then back-reflection
    /// halation (Σ_k a_k G(σ_h √k), ρ-decaying weights), optionally renormalised.
    public func encodeHalation(on encoder: Encoder, input: any MTLTexture,
                               halation h: Parameters.Halation, pixelSizeUm: Double) -> any MTLTexture {
        func texture() -> any MTLTexture { makeTexture(like: input) }
        let floor = SIMD3<Double>(repeating: 1e-6)
        var raw = input

        let amount = h.scatterAmount
        let tailWeight = SIMD3(h.scatterTailWeight)
        let coreSigma = SIMD3(h.scatterCoreUm) * h.scatterSpatialScale / pixelSizeUm
        let tailDecay = SIMD3(h.scatterTailUm) * h.scatterSpatialScale / pixelSizeUm
        if amount > 0 && (any(coreSigma .> 0) || any(tailDecay .> 0)) {
            let (core, tail) = (texture(), texture())
            encodeGaussianBlur(on: encoder, input: raw, output: core, sigma: pointwiseMax(coreSigma, floor))
            encodeExponentialBlur(on: encoder, input: raw, output: tail, decay: pointwiseMax(tailDecay, floor))
            // The scattered light into core, then the blend with raw into tail.
            encodeScale(on: encoder, input: core, output: core, by: 1 - tailWeight)
            encodeAddScaled(on: encoder, accumulator: core, input: tail, output: core, weight: tailWeight)
            encodeScale(on: encoder, input: raw, output: tail, by: 1 - amount)
            encodeAddScaled(on: encoder, accumulator: tail, input: core, output: tail, weight: SIMD3(repeating: amount))
            raw = tail
        }

        let strength = SIMD3(h.halationStrength) * h.halationAmount
        let firstSigma = SIMD3(h.halationFirstSigmaUm) * h.halationSpatialScale / pixelSizeUm
        let bounces = h.halationNBounces
        if bounces >= 1 && any(strength .> 0) && any(firstSigma .> 0) {
            var weights = (0..<bounces).map { pow(h.halationBounceDecay, Double($0)) }
            let total = weights.reduce(0, +)
            weights = weights.map { $0 / total }
            let (blurred, sum) = (texture(), texture())
            for (index, weight) in weights.enumerated() {
                let sigma = pointwiseMax(firstSigma * Double(index + 1).squareRoot(), floor)
                encodeGaussianBlur(on: encoder, input: raw, output: blurred, sigma: sigma)
                if index == 0 {
                    encodeScale(on: encoder, input: blurred, output: sum, by: weight)
                } else {
                    encodeAddScaled(on: encoder, accumulator: sum, input: blurred, output: sum, weight: SIMD3(repeating: weight))
                }
            }
            encodeAddScaled(on: encoder, accumulator: raw, input: sum, output: sum, weight: strength)
            if h.halationRenormalize {
                encodeScale(on: encoder, input: sum, output: sum, by: 1 / (1 + strength))
            }
            raw = sum
        }
        return raw
    }
}
