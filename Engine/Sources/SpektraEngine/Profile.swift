import Foundation

/// A film or paper profile, decoded from Spektrafilm's JSON (`profiles/<stock>.json`).
///
/// Spectral arrays have one entry per wavelength of ``Tables/wavelengths`` (380–780 nm, 5 nm);
/// curves have one entry per point of ``ProfileData/logExposure``. Channel triples are CMY dye
/// layers (equivalently the R, G, B sensitive layers). `null` in the JSON becomes `.nan`.
public struct Profile: Decodable, Sendable {
    public let info: ProfileInfo
    public let data: ProfileData

    public static func load(_ stock: String) throws -> Profile {
        let url = resources.appending(components: "profiles", "\(stock).json")
        return try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
    }

    /// Stock names of every bundled profile, sorted.
    public static func stocks() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: resources.appending(component: "profiles").path(percentEncoded: false))
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }
}

public struct ProfileInfo: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case negative, positive }
    public enum Support: String, Decodable, Sendable { case film, paper }
    public enum Stage: String, Decodable, Sendable { case filming, printing }
    public enum Use: String, Decodable, Sendable { case still, cine }
    public enum Antihalation: String, Decodable, Sendable { case strong, weak, no }

    public let stock: String
    public let name: String
    public let type: Kind
    public let support: Support
    public let stage: Stage
    public let use: Use
    public let antihalation: Antihalation
    public let targetPrint: String?
    public let referenceIlluminant: String
    public let viewingIlluminant: String

    enum CodingKeys: String, CodingKey {
        case stock, name, type, support, stage, use, antihalation
        case targetPrint = "target_print"
        case referenceIlluminant = "reference_illuminant"
        case viewingIlluminant = "viewing_illuminant"
    }
}

public struct ProfileData: Decodable, Sendable {
    public let wavelengths: [Double]
    public let logSensitivity: [SIMD3<Double>]
    /// Empty for papers.
    public let hanatos2025AdaptationWindowParams: [Double]
    /// 3 × 15 for films, empty for papers.
    public let hanatos2025AdaptationSurfaceParams: [[Double]]
    public let channelDensity: [SIMD3<Double>]
    public let baseDensity: [Double]
    public let logExposure: [Double]
    public let densityCurves: [SIMD3<Double>]
    /// Per log-exposure point: one CMY triple per sensitivity sub-layer (256 × 3 × 3).
    public let densityCurvesLayers: [[SIMD3<Double>]]
    public let densityCurvesModel: DensityCurvesModel

    public struct DensityCurvesModel: Decodable, Sendable {
        public let modelType: String
        /// Channels × layers.
        public let centers: [[Double]]
        public let amplitudes: [[Double]]
        public let sigmas: [[Double]]

        enum CodingKeys: String, CodingKey {
            case centers, amplitudes, sigmas
            case modelType = "model_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case wavelengths
        case logSensitivity = "log_sensitivity"
        case hanatos2025AdaptationWindowParams = "hanatos2025_adaptation_window_params"
        case hanatos2025AdaptationSurfaceParams = "hanatos2025_adaptation_surface_params"
        case channelDensity = "channel_density"
        case baseDensity = "base_density"
        case logExposure = "log_exposure"
        case densityCurves = "density_curves"
        case densityCurvesLayers = "density_curves_layers"
        case densityCurvesModel = "density_curves_model"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // JSONDecoder can't read `null` as a Double, so read optionals and map nil to NaN.
        func vector(_ key: CodingKeys) throws -> [Double] {
            try c.decode([Double?].self, forKey: key).map { $0 ?? .nan }
        }
        func matrix(_ key: CodingKeys) throws -> [[Double]] {
            try c.decode([[Double?]].self, forKey: key).map { $0.map { $0 ?? .nan } }
        }
        func triples(_ rows: [[Double]]) -> [SIMD3<Double>] {
            rows.map { SIMD3($0[0], $0[1], $0[2]) }
        }
        wavelengths = try vector(.wavelengths)
        logSensitivity = try triples(matrix(.logSensitivity))
        hanatos2025AdaptationWindowParams = try vector(.hanatos2025AdaptationWindowParams)
        hanatos2025AdaptationSurfaceParams = try matrix(.hanatos2025AdaptationSurfaceParams)
        channelDensity = try triples(matrix(.channelDensity))
        baseDensity = try vector(.baseDensity)
        logExposure = try vector(.logExposure)
        densityCurves = try triples(matrix(.densityCurves))
        densityCurvesLayers = try c.decode([[[Double?]]].self, forKey: .densityCurvesLayers)
            .map { triples($0.map { $0.map { $0 ?? .nan } }) }
        densityCurvesModel = try c.decode(DensityCurvesModel.self, forKey: .densityCurvesModel)
    }

    /// The spectral sensitivity, `10 ** log_sensitivity`, with what's missing (NaN) as 0, as
    /// `np.nan_to_num` has it.
    var sensitivity: [SIMD3<Double>] {
        logSensitivity.map { log in
            let linear = SIMD3(pow(10, log.x), pow(10, log.y), pow(10, log.z))
            return linear.replacing(with: 0, where: .!(linear .== linear))
        }
    }
}

/// The engine's bundled data directory (`Resources/`, written by `tools/export_tables.py`, which stays
/// on the development Mac rather than in the repository: #139).
let resources = Bundle.module.resourceURL!.appending(component: "Resources")
