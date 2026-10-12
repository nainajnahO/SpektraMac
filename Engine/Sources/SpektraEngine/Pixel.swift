import Metal
import simd

/// Host side of the kernels in `Shaders/Pixel.metal`: each binds its constants and encodes one
/// pass from `input` to `output` (which may be the same texture).
extension GPU {
    /// Per-channel linear interpolation through a curve (Spektrafilm's `fast_interp` with a K × 3
    /// axis): density curves, exposure curves. `axis` and `values` have one row per curve point.
    public func encodeInterpolate(on encoder: any MTLComputeCommandEncoder, input: any MTLTexture,
                                  output: any MTLTexture, axis: [SIMD3<Double>], values: [SIMD3<Double>]) {
        precondition(axis.count == values.count && axis.count >= 2)
        // Reciprocal steps in f64 like Python; a zero step gives 0, as fast_interp does.
        let inverseDx = zip(axis, axis.dropFirst()).map { a, b in
            let dx = b - a
            return SIMD3(dx.x != 0 ? 1 / dx.x : 0, dx.y != 0 ? 1 / dx.y : 0, dx.z != 0 ? 1 / dx.z : 0)
        }
        func floats(_ rows: [SIMD3<Double>]) -> [Float] { rows.flatMap { [Float($0.x), Float($0.y), Float($0.z)] } }
        var count = UInt32(axis.count)
        encode("interpolate_curves", on: encoder, textures: [input, output], grid: output.size) {
            $0.setBytes(floats(axis), length: axis.count * 12, index: 0)
            $0.setBytes(floats(values), length: values.count * 12, index: 1)
            $0.setBytes(floats(inverseDx), length: inverseDx.count * 12, index: 2)
            $0.setBytes(&count, length: 4, index: 3)
        }
    }

    /// `input * factor`.
    public func encodeScale(on encoder: any MTLComputeCommandEncoder, input: any MTLTexture,
                            output: any MTLTexture, by factor: Double) {
        encodeScale(on: encoder, input: input, output: output, by: SIMD3(repeating: factor))
    }

    /// `input * factor`, per channel.
    public func encodeScale(on encoder: any MTLComputeCommandEncoder, input: any MTLTexture,
                            output: any MTLTexture, by factor: SIMD3<Double>) {
        var factor = SIMD3<Float>(factor)
        encode("scale_rgb", on: encoder, textures: [input, output], grid: output.size) {
            $0.setBytes(&factor, length: MemoryLayout<SIMD3<Float>>.size, index: 0)
        }
    }

    /// `log10(max(input, 0) + 1e-10)`.
    public func encodeLogExposure(on encoder: any MTLComputeCommandEncoder, input: any MTLTexture,
                                  output: any MTLTexture) {
        encode("log_exposure", on: encoder, textures: [input, output], grid: output.size)
    }

    /// `10 ** input`.
    public func encodeExp10(on encoder: any MTLComputeCommandEncoder, input: any MTLTexture,
                            output: any MTLTexture) {
        encode("exp10_rgb", on: encoder, textures: [input, output], grid: output.size)
    }

    /// `matrix · rgb + offset` per pixel; `rows` is the matrix as NumPy writes it.
    public func encodeMatrix(on encoder: any MTLComputeCommandEncoder, input: any MTLTexture,
                             output: any MTLTexture, rows: [SIMD3<Double>], offset: SIMD3<Double> = .zero) {
        var matrix = simd_float3x3(rows: rows.map { SIMD3<Float>($0) })
        var offset = SIMD3<Float>(offset)
        encode("matrix_rgb", on: encoder, textures: [input, output], grid: output.size) {
            $0.setBytes(&matrix, length: MemoryLayout<simd_float3x3>.size, index: 0)
            $0.setBytes(&offset, length: MemoryLayout<SIMD3<Float>>.size, index: 1)
        }
    }
}

/// `numpy.interp` for an increasing `xp`, in f64: end values outside, exact at the nodes.
func interp(_ x: Double, _ xp: [Double], _ fp: [Double]) -> Double {
    if x < xp[0] { return fp[0] }
    if x >= xp[xp.count - 1] { return fp[fp.count - 1] }
    var low = 0, high = xp.count - 1
    while high - low > 1 {
        let mid = (low + high) / 2
        if xp[mid] <= x { low = mid } else { high = mid }
    }
    if x == xp[low] { return fp[low] }
    let slope = (fp[low + 1] - fp[low]) / (xp[low + 1] - xp[low])
    let value = slope * (x - xp[low]) + fp[low]
    // numpy's fallbacks for non-finite slopes.
    guard value.isNaN else { return value }
    let fromRight = slope * (x - xp[low + 1]) + fp[low + 1]
    return fromRight.isNaN && fp[low] == fp[low + 1] ? fp[low] : fromRight
}
