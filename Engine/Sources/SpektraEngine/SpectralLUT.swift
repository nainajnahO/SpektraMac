import Accelerate
import Foundation

/// The tc LUT a film is exposed through (`SpectralLUTService.get_filming_tc_lut`): its raw
/// response to the hanatos2025 spectra with the input gamut compression baked in.
func filmingTCLUT(film: Profile, parameters: Parameters, tables: Tables, spectra: NPYArray) -> [SIMD3<Double>] {
    let sensitivity = film.data.logSensitivity.map { log in
        let linear = SIMD3(pow(10, log.x), pow(10, log.y), pow(10, log.z))
        return linear.replacing(with: 0, where: .!(linear .== linear))  // np.nan_to_num
    }
    let referenceIlluminant = tables.illuminants[film.info.referenceIlluminant]!
    let raw = hanatos2025RawLUT(
        spectra: spectra, sensitivity: sensitivity,
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
