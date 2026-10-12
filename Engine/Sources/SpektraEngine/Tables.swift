import Foundation

/// Spectral and colorimetric tables from colour-science and Spektrafilm, sampled on the
/// 380–780 nm / 5 nm grid (`Resources/tables.json`, written by `tools/export_tables.py`).
public struct Tables: Decodable, Sendable {
    public let spektrafilmVersion: String
    public let colourVersion: String
    public let wavelengths: [Double]
    /// CIE 1931 2° colour matching functions x̄ ȳ z̄.
    public let cmfs: [SIMD3<Double>]
    /// Spektrafilm's `standard_illuminant(label)`: spectra normalised to a mean of 1.
    public let illuminants: [String: [Double]]
    /// Schott KG3 heat-absorbing filter transmittance.
    public let kg3HeatFilter: [Double]
    /// Canon 24 mm f/2.8 IS lens transmittance (for the `TH-KG3-L` illuminant).
    public let lensTransmission: [Double]
    /// Transmittance of the enlarger's analytic C, M, Y dichroic filters at full strength.
    public let dichroicFilters: [SIMD3<Double>]
    public let colourSpaces: [String: ColourSpace]
    /// 3 × 3 cone-response matrices (rows) for von Kries adaptation: CAT02, CAT16, Bradford.
    public let chromaticAdaptation: [String: [SIMD3<Double>]]

    public struct ColourSpace: Decodable, Sendable {
        /// Normalised primary matrix, rows.
        public let rgbToXYZ: [SIMD3<Double>]
        /// CIE 1931 xy.
        public let whitepoint: SIMD2<Double>
        /// Transfer function: `sRGB`, `gamma`, `BT.2020`, `ROMM RGB` or `linear`.
        public let cctf: String
        public let gamma: Double?
    }

    public static func load() throws -> Tables {
        try JSONDecoder().decode(Tables.self, from: Data(contentsOf: resources.appending(component: "tables.json")))
    }

    /// Neutral enlarger filters (Kodak CC values, C M Y) keyed by paper → illuminant → film.
    public static func loadNeutralPrintFilters() throws -> [String: [String: [String: SIMD3<Double>]]] {
        let url = resources.appending(component: "neutral_print_filters.json")
        return try JSONDecoder().decode([String: [String: [String: SIMD3<Double>]]].self, from: Data(contentsOf: url))
    }

    /// hanatos2025 irradiance spectra indexed by triangular chromaticity coordinates (192 × 192 × 81).
    public static func loadSpectraLUT() throws -> NPYArray {
        try NPYArray(contentsOf: resources.appending(component: "irradiance_xy_tc.npy"))
    }
}

extension Tables.ColourSpace {
    /// colour-science's `cctf_decoding` for this space: encoded value → linear, in f64.
    public func decode(_ value: Double) -> Double {
        // colour's spow: the power applied to |x| with the sign kept.
        func spow(_ x: Double, _ p: Double) -> Double { x < 0 ? -pow(-x, p) : pow(x, p) }
        switch cctf {
        case "sRGB":
            return 0.0031308 * 12.92 >= value ? value / 12.92 : spow((value + 0.055) / 1.055, 2.4)
        case "gamma":
            // "Indeterminate" negatives: NaN, as numpy's power gives.
            return pow(value, gamma!)
        case "BT.2020":
            let (alpha, beta) = (1.099, 0.018)
            let threshold = alpha * spow(beta, 0.45) - (alpha - 1)
            return value < threshold ? value / 4.5 : spow((value + (alpha - 1)) / alpha, 1 / 0.45)
        case "ROMM RGB":
            let threshold = 16 * pow(16, 1.8 / (1 - 1.8))
            return value < threshold ? value / 16 : spow(value, 1.8)
        default:
            return value
        }
    }
}
