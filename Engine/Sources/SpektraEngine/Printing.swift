import Foundation

/// `color_enlarger` with Spektrafilm's analytic dichroic filters (`custom_dichroic_filters`): the
/// lamp spectrum through C, M and Y filters dialled in to Kodak CC values (100 CC = density 1).
/// Each filter passes its band fully and attenuates the rest by 10^(−CC/100).
func enlargerLight(_ lamp: [Double], filters cc: SIMD3<Double>, dichroics: [SIMD3<Double>]) -> [Double] {
    let transmittance = SIMD3(pow(10, -cc.x / 100), pow(10, -cc.y / 100), pow(10, -cc.z / 100))
    return zip(lamp, dichroics).map { light, filter in
        let dimmed = 1 - (1 - filter) * (1 - transmittance)
        return light * dimmed.x * dimmed.y * dimmed.z
    }
}

/// `apply_print_curves_morph`: the paper's density curves on `logExposure`, rebuilt from its
/// fitted model (per channel a sum of sub-layer normal CDFs, mirrored for positives) and, when
/// the morph is active, reshaped by it. Python develops prints on these even with the morph off.
func printCurves(_ model: ProfileData.DensityCurvesModel, logExposure: [Double],
                 morph: Parameters.PrintCurvesMorph, positive: Bool) -> [SIMD3<Double>] {
    var curves = [SIMD3<Double>](repeating: .zero, count: logExposure.count)
    for channel in 0..<3 {
        var centers = model.centers[channel], sigmas = model.sigmas[channel]
        let amplitudes = model.amplitudes[channel]
        var exhaustion = [Double](repeating: 0, count: centers.count)
        if morph.active {
            precondition([morph.gammaFactor, morph.gammaFactorFast, morph.gammaFactorSlow, morph.gammaFactorRed,
                          morph.gammaFactorGreen, morph.gammaFactorBlue].allSatisfy { $0 > 0 }
                         && (0...1).contains(morph.developerExhaustion))
            // Grain-speed order: the fast layer has the lowest threshold (centre).
            let order = centers.indices.sorted { centers[$0] < centers[$1] }
            let channelGamma = [morph.gammaFactorRed, morph.gammaFactorGreen, morph.gammaFactorBlue][channel]
            let fast = morph.gammaFactor * channelGamma * morph.gammaFactorFast
            let slow = morph.gammaFactor * channelGamma * morph.gammaFactorSlow
            for (layer, gamma) in [(order[0], fast), (order[order.count / 2], slow), (order[order.count - 1], slow)] {
                sigmas[layer] = max(sigmas[layer] / gamma, 0.05)  // SIGMA_FLOOR
                centers[layer] /= gamma
            }
            exhaustion = [Double](repeating: morph.developerExhaustion, count: centers.count)
            let offset = exhaustionCentreOffset(centers: centers, amplitudes: amplitudes, sigmas: sigmas,
                                                exhaustion: exhaustion, positive: positive)
            centers = centers.map { $0 + offset }
        }
        for (index, exposure) in logExposure.enumerated() {
            curves[index][channel] = channelDensity(exposure, centers: centers, amplitudes: amplitudes,
                                                    sigmas: sigmas, exhaustion: exhaustion, positive: positive)
        }
    }
    return curves
}

/// `_evaluate_channel_density`: Σ_i A_i · CDF_i((x − μ_i)/σ_i), each CDF a normal blended toward
/// the matched Gumbel-max by its exhaustion weight; z is negated for positive profiles.
private func channelDensity(_ x: Double, centers: [Double], amplitudes: [Double], sigmas: [Double],
                            exhaustion: [Double], positive: Bool) -> Double {
    let gumbelLocation = -log(log(2.0)), gumbelWidth = 0.5 * log(2.0) * (2 * Double.pi).squareRoot()
    var total = 0.0
    for layer in centers.indices {
        var z = (x - centers[layer]) / sigmas[layer]
        if positive { z = -z }
        var cdf = normalCDF(z)
        if exhaustion[layer] > 0 {
            let gumbel = exp(-exp(-(z / gumbelWidth + gumbelLocation)))
            cdf = (1 - exhaustion[layer]) * cdf + exhaustion[layer] * gumbel
        }
        total += amplitudes[layer] * cdf
    }
    return total
}

/// `_developer_exhaustion_center_offset`: the common centre shift that keeps the density at zero
/// log exposure (mid-grey) unchanged under developer exhaustion. Python brackets the root by
/// doubling ±0.25 up to 12 times and refines with brentq (xtol 1e-10); this bisects the same
/// bracket to full precision (no root finder in the standard library or Accelerate).
private func exhaustionCentreOffset(centers: [Double], amplitudes: [Double], sigmas: [Double],
                                    exhaustion: [Double], positive: Bool) -> Double {
    guard exhaustion.contains(where: { abs($0) > 1e-8 }) else { return 0 }  // np.allclose(·, 0)
    let target = channelDensity(0, centers: centers, amplitudes: amplitudes, sigmas: sigmas,
                                exhaustion: exhaustion.map { _ in 0 }, positive: positive)
    func residual(_ offset: Double) -> Double {
        channelDensity(0, centers: centers.map { $0 + offset }, amplitudes: amplitudes, sigmas: sigmas,
                       exhaustion: exhaustion, positive: positive) - target
    }
    if abs(residual(0)) <= 1e-12 { return 0 }
    var (low, high) = (-0.25, 0.25)
    for _ in 0..<12 {
        let (lowResidual, highResidual) = (residual(low), residual(high))
        if lowResidual == 0 { return low }
        if highResidual == 0 { return high }
        if lowResidual * highResidual < 0 {
            for _ in 0..<200 {
                let middle = (low + high) / 2
                guard middle != low && middle != high else { break }
                if (residual(middle) < 0) == (lowResidual < 0) { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
        low *= 2
        high *= 2
    }
    return 0
}

/// scipy's `norm.cdf` (Cephes `ndtr`): erf near zero, erfc in the tails.
func normalCDF(_ a: Double) -> Double {
    let x = a * 0.5.squareRoot()
    if abs(x) < 0.5.squareRoot() { return 0.5 + 0.5 * erf(x) }
    let y = 0.5 * erfc(abs(x))
    return x > 0 ? 1 - y : y
}
