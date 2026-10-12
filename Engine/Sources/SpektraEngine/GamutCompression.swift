import Foundation

/// Spektrafilm's input gamut compression, default `"xy"` algorithm (`compress_xy_radial`): radial
/// in CIE xy from the film's reference white toward the visible spectral locus, where hanatos2025
/// spectral upsampling is defined. Baked into the film's tc LUT, so the per-pixel path never sees it.
enum InputGamutCompression {
    /// `remap_tc_lut_for_compression`: the LUT whose entry at a chromaticity is the raw LUT's
    /// value at that chromaticity compressed (`new[xy] = old[compress(xy)]`), bilinearly sampled
    /// as scipy's `map_coordinates(order=1, mode="nearest")`. `lut` is row-major `size × size`.
    static func remap(_ lut: [SIMD3<Double>], size: Int, white: SIMD2<Double>,
                      spec: Parameters.InputGamutCompressSpec, locus: [SIMD2<Double>]) -> [SIMD3<Double>] {
        guard spec.active else { return lut }
        let last = Double(size - 1)
        return (0..<(size * size)).map { cell in
            let xy = quadToTri(SIMD2(Double(cell / size) / last, Double(cell % size) / last))
            let tc = triToQuad(compress(xy, white: white, knee: spec.knee, locus: locus)) * last
            // Clamped neighbours: tc is within [0, 1] after triToQuad, so only the far edge needs it.
            let (i0, j0) = (min(Int(tc.x.rounded(.down)), size - 1), min(Int(tc.y.rounded(.down)), size - 1))
            let (i1, j1) = (min(i0 + 1, size - 1), min(j0 + 1, size - 1))
            let (fi, fj) = (tc.x - tc.x.rounded(.down), tc.y - tc.y.rounded(.down))
            return lut[i0 * size + j0] * ((1 - fi) * (1 - fj)) + lut[i0 * size + j1] * ((1 - fi) * fj)
                + lut[i1 * size + j0] * (fi * (1 - fj)) + lut[i1 * size + j1] * (fi * fj)
        }
    }

    /// `compress_xy_radial`: moves `xy` along the ray from `white`, its normalised distance to the
    /// locus passed through the Reinhard knee. Points at the white stay put.
    static func compress(_ xy: SIMD2<Double>, white: SIMD2<Double>, knee: [Double], locus: [SIMD2<Double>]) -> SIMD2<Double> {
        let ray = normalizedDistance(of: xy, white: white, locus: locus)
        guard ray.distance >= 1e-9 else { return xy }
        let compressed = reinhardKnee(ray.normalized, threshold: knee[0], limit: knee[1], power: knee[2])
        return white + ray.direction * (compressed * ray.boundary)
    }

    /// `reinhard_knee`: identity up to `threshold`, then a smooth approach to `limit`.
    static func reinhardKnee(_ d: Double, threshold: Double, limit: Double, power: Double) -> Double {
        guard d > threshold else { return d }
        let scale = limit - threshold
        let x = (d - threshold) / scale
        return threshold + scale * (x / pow(1 + pow(x, power), 1 / power))
    }

    /// `_ray_polygon_distance`: how far from `origin` along the unit `direction` the ray first
    /// meets the closed `polygon` (∞ if it misses), with Python's epsilons.
    static func boundaryDistance(from origin: SIMD2<Double>, along direction: SIMD2<Double>,
                                 polygon: [SIMD2<Double>]) -> Double {
        var nearest = Double.infinity
        for (a, b) in zip(polygon, polygon.dropFirst()) {
            let edge = b - a
            let denominator = direction.x * edge.y - direction.y * edge.x
            guard abs(denominator) > 1e-12 else { continue }
            let o = origin - a
            let t = (-o.x * edge.y + o.y * edge.x) / denominator
            let s = (-o.x * direction.y + o.y * direction.x) / denominator
            if t > 1e-9, s >= 0, s <= 1, t < nearest {
                nearest = t
            }
        }
        return nearest
    }

    /// Distance of `xy` from `white` as a fraction of the way to the locus along the same ray:
    /// below 1 is inside the visible gamut, 1 on the locus. Also the white-point direction, which
    /// the compression moves along. Python's `fmax(…, 1e-12)` guards included.
    static func normalizedDistance(of xy: SIMD2<Double>, white: SIMD2<Double>, locus: [SIMD2<Double>])
    -> (distance: Double, normalized: Double, direction: SIMD2<Double>, boundary: Double) {
        let delta = xy - white
        let distance = (delta * delta).sum().squareRoot()
        let direction = delta / max(distance, 1e-12)
        let boundary = boundaryDistance(from: white, along: direction, polygon: locus)
        return (distance, distance / max(boundary, 1e-12), direction, boundary)
    }
}

/// `_tri2quad`: CIE xy → the hanatos2025 LUT's square coordinates (tc), clamped to [0, 1].
func triToQuad(_ xy: SIMD2<Double>) -> SIMD2<Double> {
    let y = xy.y / max(1 - xy.x, 1e-10)
    let x = (1 - xy.x) * (1 - xy.x)
    return SIMD2(min(max(x, 0), 1), min(max(y, 0), 1))
}

/// `_quad2tri`: the hanatos2025 LUT's square coordinates (tc) → CIE xy.
func quadToTri(_ tc: SIMD2<Double>) -> SIMD2<Double> {
    let root = tc.x.squareRoot()
    return SIMD2(1 - root, tc.y * root)
}
