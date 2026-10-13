import Metal
import Testing
@testable import SpektraEngine

private func blurDifference(_ name: String, exponential: Bool = false) throws -> Difference {
    let gpu = try GPU()
    let x = try golden("primitives", "\(name)_x")
    let reference = try golden("primitives", "\(name)_out")
    let s = try golden("primitives", "\(name)_sigma").values.map(Double.init)
    let sigma = SIMD3(s[0], s[1], s[2])
    let input = gpu.upload(rgb: x.values, width: x.shape[1], height: x.shape[0])
    let output = gpu.makeTexture(width: x.shape[1], height: x.shape[0])
    try gpu.run { encoder in
        if exponential {
            gpu.encodeExponentialBlur(on: encoder, input: input, output: output, decay: sigma)
        } else {
            gpu.encodeGaussianBlur(on: encoder, input: input, output: output, sigma: sigma)
        }
    }
    let difference = Difference(gpu.download(output), reference.values, floor: 1)
    print("\(name) σ=\(s): \(difference)")
    return difference
}

// Inputs are uniform random pixels in [0, 1], so absolute errors are relative to the signal range.
@Test(arguments: ["blur_fir", "blur_iir", "blur_mixed", "blur_tiny"])
func gaussianBlurMatchesPython(name: String) throws {
    #expect(try blurDifference(name).maxAbsolute < 1e-6)
}

/// One σ ≥ 3 for every channel is Apple's blur, against an exact Gaussian (Python's recursive filter
/// is up to 0.2 off it at the borders): at σ 3 and at σ 100, wider than the image.
@Test(arguments: ["blur_equal", "blur_wide"])
func equalSigmasBlurAsAnExactGaussian(name: String) throws {
    #expect(try blurDifference(name).maxAbsolute < 2e-3)
}

@Test func exponentialBlurMatchesPython() throws {
    #expect(try blurDifference("blur_exponential", exponential: true).maxAbsolute < 1e-6)
}
