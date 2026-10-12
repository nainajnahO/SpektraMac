import Metal
import Testing
@testable import SpektraEngine

/// Runs one primitive over `primitives/<name>_x.npy` and compares with `<name>_out.npy`.
private func checkPrimitive(_ name: String, tolerance: Double,
                            encode: (GPU, any MTLComputeCommandEncoder, any MTLTexture, any MTLTexture) -> Void) throws {
    let gpu = try GPU()
    let x = try golden("primitives", "\(name)_x")
    let reference = try golden("primitives", "\(name)_out")
    let (height, width) = (x.shape[0], x.shape[1])
    let input = gpu.upload(rgb: x.values, width: width, height: height)
    let output = gpu.makeTexture(width: width, height: height)
    try gpu.run { encode(gpu, $0, input, output) }
    let difference = Difference(gpu.download(output), reference.values, floor: 1)
    print("\(name): \(difference)")
    #expect(difference.maxRelative <= tolerance, "\(name): \(difference)")
}

private func rows(_ array: NPYArray) -> [SIMD3<Double>] {
    stride(from: 0, to: array.values.count, by: 3).map {
        SIMD3(Double(array.values[$0]), Double(array.values[$0 + 1]), Double(array.values[$0 + 2]))
    }
}

// Tolerances are relative to max(|reference|, 1): relative for large values, absolute below 1.

@Test(arguments: ["interp_negative", "interp_positive"])
func interpolationMatchesFastInterp(name: String) throws {
    let axis = try rows(golden("primitives", "\(name)_axis"))
    let values = try rows(golden("primitives", "\(name)_values"))
    try checkPrimitive(name, tolerance: 1e-6) { gpu, encoder, input, output in
        gpu.encodeInterpolate(on: encoder, input: input, output: output, axis: axis, values: values)
    }
}

@Test func log10MatchesNumPy() throws {
    try checkPrimitive("log10", tolerance: 1e-6) { gpu, encoder, input, output in
        gpu.encodeLogExposure(on: encoder, input: input, output: output)
    }
}

@Test func exp10MatchesNumPy() throws {
    try checkPrimitive("pow10", tolerance: 1e-6) { gpu, encoder, input, output in
        gpu.encodeExp10(on: encoder, input: input, output: output)
    }
}

@Test func matrixMatchesNumPy() throws {
    let matrix = try rows(golden("primitives", "matmul_matrix"))
    try checkPrimitive("matmul", tolerance: 1e-6) { gpu, encoder, input, output in
        gpu.encodeMatrix(on: encoder, input: input, output: output, rows: matrix)
    }
}
