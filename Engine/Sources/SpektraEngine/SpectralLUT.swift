import Accelerate
import Foundation
import simd

/// The tc LUT a film is exposed through (`SpectralLUTService.get_filming_tc_lut`): its raw
/// response to the hanatos2025 spectra with the input gamut compression baked in. Of the
/// parameters it reads only those in ``SimulationCache/FilmingLUTKey``, which caches it.
func filmingTCLUT(film: Profile, parameters: Parameters, tables: Tables, spectra: NPYArray) -> [SIMD3<Double>] {
    let referenceIlluminant = tables.illuminants[film.info.referenceIlluminant]!
    let raw = hanatos2025RawLUT(
        spectra: spectra, sensitivity: film.data.sensitivity,
        windowParams: parameters.settings.applyHanatos2025AdaptationWindow ? film.data.hanatos2025AdaptationWindowParams : nil,
        referenceIlluminant: referenceIlluminant, wavelengths: tables.wavelengths)
    return InputGamutCompression.remap(raw, size: spectra.shape[0], white: tables.chromaticity(of: referenceIlluminant),
                                       spec: parameters.io.inputGamutCompress, locus: tables.spectralLocus)
}

/// The film's response to the hanatos2025 spectra: Spektrafilm's `compute_hanatos2025_tc_lut`
/// before input gamut compression, in f64 on the CPU. Entry (i, j) is the film's raw R, G, B
/// exposure for the spectrum of triangular chromaticity coordinates (i, j), 192 × 192, row-major.
///
/// `sensitivity` is 10^log_sensitivity with NaN as 0 (as FilmingStage builds it); with
/// `window`, the profile's erf band-pass is applied, renormalised so a neutral under the
/// reference illuminant keeps its exposure.
func hanatos2025RawLUT(spectra: NPYArray, sensitivity: [SIMD3<Double>], windowParams: [Double]?,
                       referenceIlluminant: [Double], wavelengths: [Double]) -> [SIMD3<Double>] {
    var effective = sensitivity
    if let windowParams {
        let window = erf4BandPass(windowParams, wavelengths: wavelengths)
        var withWindow = SIMD3<Double>.zero, without = SIMD3<Double>.zero
        for (index, illuminant) in referenceIlluminant.enumerated() {
            withWindow += sensitivity[index] * illuminant * window[index]
            without += sensitivity[index] * illuminant
        }
        let normalization = withWindow / without
        effective = zip(sensitivity, window).map { $0 * ($1 / normalization) }
    }

    // contract('ijl,lm->ijm'): (192·192 × 81) · (81 × 3), row-major.
    let bands = wavelengths.count
    let points = spectra.values.count / bands
    let spectraMatrix = spectra.values.map(Double.init)
    let sensitivityMatrix = effective.flatMap { [$0.x, $0.y, $0.z] }
    var raw = [Double](repeating: 0, count: points * 3)
    vDSP_mmulD(spectraMatrix, 1, sensitivityMatrix, 1, &raw, 1, vDSP_Length(points), 3, vDSP_Length(bands))
    return stride(from: 0, to: raw.count, by: 3).map { SIMD3(raw[$0], raw[$0 + 1], raw[$0 + 2]) }
}

/// `eval_erf4_spectral_bandpass`: (c_uv, σ_uv, c_ir, σ_ir) → one window shared by all channels.
private func erf4BandPass(_ params: [Double], wavelengths: [Double]) -> [Double] {
    let (cUV, sigmaUV, cIR, sigmaIR) = (params[0], params[1], params[2], params[3])
    return wavelengths.map { wavelength in
        let edgeUV = 0.5 * (1 + erf((wavelength - cUV) / (sigmaUV * 2.0.squareRoot())))
        let edgeIR = 0.5 * (1 - erf((wavelength - cIR) / (sigmaIR * 2.0.squareRoot())))
        return edgeUV * edgeIR
    }
}

/// The f64 CPU twin of the `hanatos2025_raw` kernel for single colours (the mid-grey references):
/// linear RGB → film-adapted XYZ → tc → Mitchell lookup in the tc LUT, × (X + Y + Z).
func hanatos2025Raw(_ rgb: SIMD3<Double>, toXYZ: simd_double3x3, lut: [SIMD3<Double>], size: Int) -> SIMD3<Double> {
    let xyz = toXYZ * rgb
    let b = xyz.sum()
    let tc = triToQuad(SIMD2(xyz.x, xyz.y) / max(b, 1e-10))
    return cubicLookup(lut, size: size, at: tc * Double(size - 1)) * (b.isNaN ? 0 : b)
}

/// `_cubic_interp_lut_at_2d`: Mitchell–Netravali (B = C = 1/3) over 4 × 4 entries around the
/// clamped coordinate, reflected indices, normalised by the weight sum.
func cubicLookup(_ lut: [SIMD3<Double>], size: Int, at coordinate: SIMD2<Double>) -> SIMD3<Double> {
    func mitchell(_ t: Double) -> Double {
        let (b, c, x) = (1.0 / 3, 1.0 / 3, abs(t))
        if x < 1 { return ((12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)) / 6 }
        if x < 2 { return ((-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x + (8 * b + 24 * c)) / 6 }
        return 0
    }
    func baseAndFraction(_ value: Double) -> (Int, Double) {
        let c = min(max(value, 0), Double(size - 1))
        return c >= Double(size - 1) ? (size - 2, 1) : (Int(c.rounded(.down)), c - c.rounded(.down))
    }
    func reflect(_ i: Int) -> Int { i < 0 ? -i : (i >= size ? 2 * (size - 1) - i : i) }
    let (xBase, xFraction) = baseAndFraction(coordinate.x)
    let (yBase, yFraction) = baseAndFraction(coordinate.y)
    var sum = SIMD3<Double>.zero, weightSum = 0.0
    for i in 0..<4 {
        let wx = mitchell(xFraction + 1 - Double(i))
        let xi = reflect(xBase - 1 + i)
        for j in 0..<4 {
            let weight = wx * mitchell(yFraction + 1 - Double(j))
            weightSum += weight
            sum += weight * lut[xi * size + reflect(yBase - 1 + j)]
        }
    }
    return weightSum != 0 ? sum / weightSum : sum
}
