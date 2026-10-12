import Foundation

/// Spektrafilm's input gamut compression, default `"xy"` algorithm (`compress_xy_radial`): radial
/// in CIE xy from the film's reference white toward the visible spectral locus, where hanatos2025
/// spectral upsampling is defined. Geometry first; the knee and the LUT bake follow.
enum InputGamutCompression {
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

/// `_quad2tri`: the hanatos2025 LUT's square coordinates (tc) → CIE xy.
func quadToTri(_ tc: SIMD2<Double>) -> SIMD2<Double> {
    let root = tc.x.squareRoot()
    return SIMD2(1 - root, tc.y * root)
}
