import Foundation
import simd

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
        return white + ray.direction * (reinhardKnee(ray.normalized, knee) * ray.boundary)
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

/// Spektrafilm's output gamut compression, default `"cam16ucs"` algorithm
/// (`compress_rgb_cam16ucs_chroma`): in CAM16-UCS around the output space's white, lightness above
/// white rolls off toward it, then chroma is knee-compressed against the largest chroma the output
/// RGB cube holds at that lightness and hue, C_max(J', h'), a table built once per space.
struct OutputGamutCompression {
    /// The table's J' grid, `np.linspace(1, 110, 64)`: J' ≈ 100 at white, a little headroom above.
    static let lightnessGrid = (0..<64).map { $0 == 63 ? 110 : Double($0) * (109.0 / 63) + 1 }
    /// The table's h' grid in radians, `np.linspace(-π, π, 720, endpoint=False)`.
    static let hueGrid = (0..<720).map { Double($0) * (2 * .pi / 720) - .pi }

    let spec: Parameters.OutputGamutCompressSpec
    let model: CAM16UCS
    // colour's RGB↔XYZ around the space's own white also applies a CAT02 adaptation from that
    // white to itself: the identity up to rounding, so left out.
    let rgbToXYZ: simd_double3x3
    let xyzToRGB: simd_double3x3
    /// J' of the output white, which the lightness knee is relative to.
    let whiteLightness: Double
    /// C_max over ``lightnessGrid`` × ``hueGrid``, row-major.
    let maxChroma: [Double]

    init(spec: Parameters.OutputGamutCompressSpec, space: Tables.ColourSpace, cat16: [SIMD3<Double>]) {
        self.spec = spec
        model = CAM16UCS(white: space.whitepoint, cat16: cat16)
        rgbToXYZ = simd_double3x3(rows: space.rgbToXYZ)
        xyzToRGB = simd_double3x3(rows: space.xyzToRGB)
        whiteLightness = model.jab(fromXYZ: model.white).x

        // `_build_polar_perceptual_c_max_table`: 18 bisection steps on [0, 150] per cell for the
        // largest chroma whose RGB stays within [0, 1] (± 1e-6 of slack). Rows in parallel.
        let (model, xyzToRGB) = (model, xyzToRGB)
        var table = [Double](repeating: 0, count: 64 * 720)
        table.withUnsafeMutableBufferPointer { table in
            // Each iteration writes only its own row.
            nonisolated(unsafe) let table = table
            DispatchQueue.concurrentPerform(iterations: 64) { row in
                let lightness = Self.lightnessGrid[row]
                for (column, hue) in Self.hueGrid.enumerated() {
                    var (low, high) = (0.0, 150.0)
                    for _ in 0..<18 {
                        let middle = (low + high) * 0.5
                        let rgb = xyzToRGB * model.xyz(fromJab: SIMD3(lightness, middle * cos(hue), middle * sin(hue)))
                        let inGamut = all((rgb .>= -1e-6) .& (rgb .<= 1 + 1e-6))
                        if inGamut { low = middle } else { high = middle }
                    }
                    table[row * 720 + column] = low
                }
            }
        }
        maxChroma = table
    }

    /// `compress_rgb_cam16ucs_chroma` on one linear RGB value of the output space.
    func compress(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let jab = model.jab(fromXYZ: rgbToXYZ * rgb)
        var lightness = jab.x
        if let knee = spec.lightnessCompression {
            lightness = reinhardKnee(lightness / whiteLightness, knee) * whiteLightness
        }
        let (chroma, hue) = (hypot(jab.y, jab.z), atan2(jab.z, jab.y))
        // fmax: a NaN lookup gives the floor, as in Python.
        let limit = Double.maximum(maxChroma(lightness: lightness, hue: hue), 1e-9)
        let compressed = reinhardKnee(chroma / limit, spec.knee) * limit
        return xyzToRGB * model.xyz(fromJab: SIMD3(lightness, compressed * cos(hue), compressed * sin(hue)))
    }

    /// `_c_max_lookup`: bilinear in the table, J' clamped to the grid, h' wrapping around.
    func maxChroma(lightness: Double, hue: Double) -> Double {
        guard !lightness.isNaN, !hue.isNaN else { return .nan }
        let (lightnessGrid, hueGrid) = (Self.lightnessGrid, Self.hueGrid)
        let clamped = min(max(lightness, lightnessGrid[0]), lightnessGrid[63])
        let hueIndex = (hue - hueGrid[0]) / (hueGrid[1] - hueGrid[0])
        let hueLow = (Int(hueIndex.rounded(.down)) % 720 + 720) % 720
        let hueHigh = (hueLow + 1) % 720
        let hueFraction = hueIndex - hueIndex.rounded(.down)
        let lightnessIndex = (clamped - lightnessGrid[0]) / (lightnessGrid[63] - lightnessGrid[0]) * 63
        let lightnessLow = min(max(Int(lightnessIndex.rounded(.down)), 0), 62)
        let lightnessFraction = lightnessIndex - Double(lightnessLow)
        func value(_ i: Int, _ j: Int) -> Double { maxChroma[i * 720 + j] }
        return value(lightnessLow, hueLow) * (1 - lightnessFraction) * (1 - hueFraction)
            + value(lightnessLow, hueHigh) * (1 - lightnessFraction) * hueFraction
            + value(lightnessLow + 1, hueLow) * lightnessFraction * (1 - hueFraction)
            + value(lightnessLow + 1, hueHigh) * lightnessFraction * hueFraction
    }
}

/// `reinhard_knee` with `knee` = (threshold, limit, power): identity up to the threshold, then a
/// smooth approach to the limit.
func reinhardKnee(_ d: Double, _ knee: [Double]) -> Double {
    let (threshold, limit, power) = (knee[0], knee[1], knee[2])
    guard d > threshold else { return d }
    let scale = limit - threshold
    let x = (d - threshold) / scale
    return threshold + scale * (x / pow(1 + pow(x, power), 1 / power))
}

/// CIECAM16-UCS (Li et al. 2017) under the output gamut compression's fixed viewing conditions
/// (`compress_rgb_cam16ucs_chroma`): adapting luminance 64 cd/m², background Y_b 20, Average
/// surround, adapting white the output space's white at Y = 1. A step-for-step port of
/// colour-science 0.4.7's `XYZ_to_CAM16UCS` / `CAM16UCS_to_XYZ` in f64 (custom: no Apple framework
/// has colour appearance models). XYZ has Y = 1 at white; J'a'b' is on colour's 0–100 scale.
struct CAM16UCS {
    // Average surround (F, c, N_c) and the CAM02-UCS coefficients (c1, c2) of Luo et al. 2006.
    private static let surroundF = 1.0, c = 0.69, nC = 1.0
    private static let c1 = 0.007, c2 = 0.0228
    private static let adaptingLuminance = 64.0, background = 20.0

    /// The adapting white's XYZ at Y = 1 (`_output_cs_whitepoint_xyz`).
    let white: SIMD3<Double>
    private let m16: simd_double3x3
    private let m16Inverse: simd_double3x3
    private let dRGB: SIMD3<Double>
    private let fL: Double
    private let n: Double
    /// N_bb, which equals N_cb.
    private let nBB: Double
    private let z: Double
    private let whiteA: Double

    /// `white` is the output colour space's xy whitepoint; `cat16` the CAT16 matrix rows.
    init(white: SIMD2<Double>, cat16: [SIMD3<Double>]) {
        m16 = simd_double3x3(rows: cat16)
        m16Inverse = m16.inverse
        let y = max(white.y, 1e-12)
        self.white = SIMD3(white.x / y, 1, (1 - white.x - white.y) / y)
        // ×100: colour's reference domain.
        let whiteXYZ = self.white * 100
        let whiteRGB = m16 * whiteXYZ
        let luminance = Self.adaptingLuminance
        let d = min(max(Self.surroundF * (1 - (1 / 3.6) * exp((-luminance - 42) / 92)), 0), 1)
        n = sdiv(Self.background, whiteXYZ.y)
        let k4 = pow(1 / (5 * luminance + 1), 4)
        fL = 0.2 * k4 * (5 * luminance) + 0.1 * ((1 - k4) * (1 - k4)) * spow(5 * luminance, 1.0 / 3)
        nBB = 0.725 * spow(sdiv(1, n), 0.2)
        z = 1.48 + n.squareRoot()
        dRGB = d * whiteXYZ.y / whiteRGB + 1 - d
        whiteA = Self.achromaticResponse(Self.compress(dRGB * whiteRGB, fL: fL), nBB: nBB)
    }

    /// `XYZ_to_CAM16UCS`: XYZ → J'a'b'.
    func jab(fromXYZ xyz: SIMD3<Double>) -> SIMD3<Double> {
        let rgbA = Self.compress(dRGB * (m16 * (xyz * 100)), fL: fL)
        let (r, g, b) = (rgbA.x, rgbA.y, rgbA.z)
        let opponentA = r - 12 * g / 11 + b / 11
        let opponentB = (r + g - 2 * b) / 9
        let h = degrees(atan2(opponentB, opponentA))
        let lightness = 100 * spow(sdiv(Self.achromaticResponse(rgbA, nBB: nBB), whiteA), Self.c * z)
        let t = (50000 / 13 * Self.nC * nBB)
            * sdiv(eccentricity(h) * spow(opponentA * opponentA + opponentB * opponentB, 0.5), r + g + 21 * b / 20)
        let chroma = spow(t, 0.9) * spow(lightness / 100, 0.5) * spow(1.64 - pow(0.29, n), 0.73)
        let colourfulness = chroma * spow(fL, 0.25)

        let jp = (1 + 100 * Self.c1) * lightness / (1 + Self.c1 * lightness)
        let mp = (1 / Self.c2) * log1p(Self.c2 * colourfulness)
        let hr = h * (.pi / 180)
        return SIMD3(jp, mp * cos(hr), mp * sin(hr))
    }

    /// `CAM16UCS_to_XYZ`: J'a'b' → XYZ.
    func xyz(fromJab jab: SIMD3<Double>) -> SIMD3<Double> {
        let lightness = -jab.x / (Self.c1 * jab.x - 1 - 100 * Self.c1)
        let colourfulness = expm1(hypot(jab.y, jab.z) / (1 / Self.c2)) / Self.c2
        let h = degrees(atan2(jab.z, jab.y))
        let chroma = colourfulness / spow(fL, 0.25)
        let t = spow(chroma / ((max(lightness, .ulpOfOne) / 100).squareRoot() * spow(1.64 - pow(0.29, n), 0.73)),
                     1 / 0.9)
        let achromatic = whiteA * spow(lightness / 100, 1 / (Self.c * z))
        let p1 = sdiv(50000 / 13 * Self.nC * nBB * eccentricity(h), t)
        let p2 = achromatic / nBB + 0.305
        let p3 = 21.0 / 20

        // opponent_colour_dimensions_inverse: solve along whichever of sin h, cos h is larger
        // (neither for a NaN hue, which leaves a = b = 0).
        let hr = h * (.pi / 180)
        let (sinH, cosH) = (sin(hr), cos(hr))
        let scaled = p2 * (2 + p3) * (460 / 1403)
        var (a, b) = (0.0, 0.0)
        if abs(sinH) >= abs(cosH) {
            b = scaled / (sdiv(p1, sinH) + (2 + p3) * (220 / 1403) * sdiv(cosH, sinH) - (27 / 1403) + p3 * (6300 / 1403))
            a = b * sdiv(cosH, sinH)
        } else if abs(sinH) < abs(cosH) {
            a = scaled / (sdiv(p1, cosH) + (2 + p3) * (220 / 1403) - ((27 / 1403) - p3 * (6300 / 1403)) * sdiv(sinH, cosH))
            b = a * sdiv(sinH, cosH)
        }
        let achromaticOnly: Double = t == 0 ? 0 : 1
        (a, b) = (a * achromaticOnly, b * achromaticOnly)

        let rgbA = simd_double3x3(rows: [SIMD3(460, 451, 288), SIMD3(460, -891, -261), SIMD3(460, -220, -6300)])
            * SIMD3(p2, a, b) / 1403
        func expand(_ x: Double) -> Double {
            sign(x - 0.1) * 100 / fL * spow(27.13 * abs(x - 0.1) / (400 - abs(x - 0.1)), 1 / 0.42)
        }
        let rgb = SIMD3(expand(rgbA.x), expand(rgbA.y), expand(rgbA.z)) / dRGB
        return m16Inverse * rgb / 100
    }

    /// Post-adaptation non-linear response compression (forward).
    private static func compress(_ rgb: SIMD3<Double>, fL: Double) -> SIMD3<Double> {
        func response(_ x: Double) -> Double {
            let f = spow(fL * abs(x) / 100, 0.42)
            return 400 * sign(x) * f / (27.13 + f) + 0.1
        }
        return SIMD3(response(rgb.x), response(rgb.y), response(rgb.z))
    }

    private static func achromaticResponse(_ rgbA: SIMD3<Double>, nBB: Double) -> Double {
        (2 * rgbA.x + rgbA.y + (1 / 20) * rgbA.z - 0.305) * nBB
    }

    private func eccentricity(_ h: Double) -> Double {
        1 / 4 * (cos(2 + h * .pi / 180) + 3.8)
    }

    /// Radians → degrees in [0, 360), as `np.degrees(…) % 360`.
    private func degrees(_ radians: Double) -> Double {
        let h = (radians * (180 / .pi)).truncatingRemainder(dividingBy: 360)
        return h < 0 ? h + 360 : h
    }
}

/// colour's `spow`: the power of |x| with the sign of x kept.
func spow(_ x: Double, _ p: Double) -> Double { sign(x) * pow(abs(x), p) }

/// colour's default `sdiv` ("Ignore Zero Conversion"): a / b with NaN and ±∞ results as 0.
func sdiv(_ a: Double, _ b: Double) -> Double {
    let quotient = a / b
    return quotient.isFinite ? quotient : 0
}

/// NumPy's `sign`: −1, 0 or 1.
private func sign(_ x: Double) -> Double { x > 0 ? 1 : x < 0 ? -1 : 0 }
