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
