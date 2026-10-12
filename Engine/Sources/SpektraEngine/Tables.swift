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
