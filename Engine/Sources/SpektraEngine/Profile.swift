import Foundation

/// A film or paper profile, decoded from Spektrafilm's JSON (`profiles/<stock>.json`).
///
/// Spectral arrays have one entry per wavelength of ``Tables/wavelengths`` (380–780 nm, 5 nm);
/// curves have one entry per point of ``ProfileData/logExposure``. Channel triples are CMY dye
/// layers (equivalently the R, G, B sensitive layers). `null` in the JSON becomes `.nan`.
///
/// A black-and-white stock has one layer. Its sensitivity and curves are read into all three
/// channels and its silver into the first alone, so every step runs on it as on a colour stock,
/// and what sums the layers through their dyes (printing, scanning) sees the first: three copies
/// that never mix, one of them visible. That first channel takes the first (red) of every
/// per-channel setting, as Spektrafilm's `match_channels` has it.
public struct Profile: Decodable, Sendable {
    public let info: ProfileInfo
    public private(set) var data: ProfileData

    enum CodingKeys: CodingKey { case info, data }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try container.decode(ProfileInfo.self, forKey: .info)
        // The data's columns are layers or development times, which only the info says.
        data = try container.decode(ProfileData.self, forKey: .data, configuration: info.channelModel)
    }

    /// This stock developed for `minutes` (``ProfileData/Development/asked(_:of:)``): its base
    /// density and curves are that development's. A colour stock, developed one way, as it is.
    func developed(minutes: Double?) -> Profile {
        guard let development = ProfileData.Development.asked(minutes, of: data.developments) else { return self }
        var developed = self
        developed.data.baseDensity = development.baseDensity
        developed.data.densityCurves = development.densityCurves
        developed.data.densityCurvesLayers = development.densityCurvesLayers
        developed.data.densityCurvesModel = development.densityCurvesModel
        return developed
    }

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
    /// Three dye layers, or one of silver.
    public enum ChannelModel: String, Decodable, Sendable {
        case colour = "color"
        case blackAndWhite = "bw"
    }

    public let stock: String
    public let name: String
    public let type: Kind
    public let support: Support
    public let stage: Stage
    public let use: Use
    public let antihalation: Antihalation
    public let targetPrint: String?
    public let channelModel: ChannelModel
    public let referenceIlluminant: String
    public let viewingIlluminant: String

    enum CodingKeys: String, CodingKey {
        case stock, name, type, support, stage, use, antihalation
        case targetPrint = "target_print"
        case channelModel = "channel_model"
        case referenceIlluminant = "reference_illuminant"
        case viewingIlluminant = "viewing_illuminant"
    }
}

public struct ProfileData: DecodableWithConfiguration, Sendable {
    public let wavelengths: [Double]
    public let logSensitivity: [SIMD3<Double>]
    /// Empty for papers and black-and-white stocks.
    public let hanatos2025AdaptationWindowParams: [Double]
    /// 3 × 15 for colour films, empty for papers and black-and-white stocks.
    public let hanatos2025AdaptationSurfaceParams: [[Double]]
    public let channelDensity: [SIMD3<Double>]
    public fileprivate(set) var baseDensity: [Double]
    public let logExposure: [Double]
    public fileprivate(set) var densityCurves: [SIMD3<Double>]
    /// Per log-exposure point: one CMY triple per sensitivity sub-layer (256 × 3 × 3).
    public fileprivate(set) var densityCurvesLayers: [[SIMD3<Double>]]
    public fileprivate(set) var densityCurvesModel: DensityCurvesModel
    /// A black-and-white stock's measured developments, shortest first; a colour stock, developed
    /// one way, has none. ``baseDensity`` and the curves above are the standard one's, until
    /// ``Profile/developed(minutes:)`` makes them another's.
    public let developments: [Development]

    public struct DensityCurvesModel: Decodable, Sendable {
        /// Only a sum of normal CDFs per layer is ported, under both names Spektrafilm has given
        /// it, so a profile fitted with another model fails to load rather than being read as one.
        public let modelType: ModelType
        /// Channels × layers.
        public let centers: [[Double]]
        public let amplitudes: [[Double]]
        public let sigmas: [[Double]]

        public enum ModelType: String, Decodable, Sendable {
            case cdfs
            case normCDFs = "norm_cdfs"
        }

        enum CodingKeys: String, CodingKey {
            case centers, amplitudes, sigmas
            case modelType = "model_type"
        }
    }

    /// What one development time makes of a black-and-white stock.
    public struct Development: Sendable {
        public let minutes: Double
        let baseDensity: [Double]
        let densityCurves: [SIMD3<Double>]
        let densityCurvesLayers: [[SIMD3<Double>]]
        let densityCurvesModel: DensityCurvesModel

        /// Spektrafilm's `select_development_time`: of `developments`, the one nearest `minutes`
        /// (the first of two as near), and without a time the standard one, the middle (the
        /// first of two). `nil` where there are none.
        static func asked(_ minutes: Double?, of developments: [Development]) -> Development? {
            guard let minutes else { return developments.isEmpty ? nil : developments[(developments.count - 1) / 2] }
            return developments.min { abs($0.minutes - minutes) < abs($1.minutes - minutes) }
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
        case developmentTime = "development_time"
    }

    public init(from decoder: any Decoder, configuration channelModel: ProfileInfo.ChannelModel) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func malformed(_ key: CodingKeys, _ expected: String) -> DecodingError {
            .dataCorruptedError(forKey: key, in: c, debugDescription: "Expected \(expected)")
        }
        // JSONDecoder can't read `null` as a Double, so read optionals and map nil to NaN.
        func vector(_ key: CodingKeys) throws -> [Double] {
            try c.decode([Double?].self, forKey: key).map { $0 ?? .nan }
        }
        // Rows of `width` values: any other width is a profile that would be misread.
        func matrix(_ key: CodingKeys, width: Int) throws -> [[Double]] {
            let rows = try c.decode([[Double?]].self, forKey: key).map { $0.map { $0 ?? .nan } }
            guard rows.allSatisfy({ $0.count == width }) else { throw malformed(key, "rows of \(width) values") }
            return rows
        }
        func triples(_ rows: [[Double]]) -> [SIMD3<Double>] {
            rows.map { SIMD3($0[0], $0[1], $0[2]) }
        }
        // Per point, the three sub-layers' rows.
        func layers(width: Int) throws -> [[[Double]]] {
            let points = try c.decode([[[Double?]]].self, forKey: .densityCurvesLayers)
                .map { $0.map { $0.map { $0 ?? .nan } } }
            guard points.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.count == width } }) else {
                throw malformed(.densityCurvesLayers, "three sub-layers of \(width) values per point")
            }
            return points
        }
        func model(rows: Int) throws -> DensityCurvesModel {
            let model = try c.decode(DensityCurvesModel.self, forKey: .densityCurvesModel)
            guard [model.centers, model.amplitudes, model.sigmas].allSatisfy({ $0.count == rows }) else {
                throw malformed(.densityCurvesModel, "\(rows) rows of centers, amplitudes and sigmas")
            }
            return model
        }

        wavelengths = try vector(.wavelengths)
        logExposure = try vector(.logExposure)
        // `null` for a black-and-white stock.
        hanatos2025AdaptationWindowParams = try c.decodeIfPresent([Double].self, forKey: .hanatos2025AdaptationWindowParams) ?? []
        hanatos2025AdaptationSurfaceParams = try c.decodeIfPresent([[Double]].self, forKey: .hanatos2025AdaptationSurfaceParams) ?? []
        switch channelModel {
        case .colour:
            logSensitivity = try triples(matrix(.logSensitivity, width: 3))
            channelDensity = try triples(matrix(.channelDensity, width: 3))
            baseDensity = try vector(.baseDensity)
            densityCurves = try triples(matrix(.densityCurves, width: 3))
            densityCurvesLayers = try layers(width: 3).map(triples)
            densityCurvesModel = try model(rows: 3)
            developments = []
        case .blackAndWhite:
            // One layer, whose columns are development times.
            let minutes = try c.decode([Double].self, forKey: .developmentTime)
            guard !minutes.isEmpty else { throw malformed(.developmentTime, "a development time") }
            logSensitivity = try matrix(.logSensitivity, width: 1).map { SIMD3(repeating: $0[0]) }
            channelDensity = try matrix(.channelDensity, width: 1).map { SIMD3($0[0], 0, 0) }
            // Per band and time, or a flat list where the times share it (which isn't an error to
            // report: the other shape is read instead).
            let bases: [[Double]]
            if let shared = try? vector(.baseDensity) {
                bases = shared.map { [Double](repeating: $0, count: minutes.count) }
            } else {
                bases = try matrix(.baseDensity, width: minutes.count)
            }
            let curves = try matrix(.densityCurves, width: minutes.count)
            let subLayers = try layers(width: minutes.count)
            let fitted = try model(rows: minutes.count)
            developments = minutes.indices.map { time in
                Development(
                    minutes: minutes[time],
                    baseDensity: bases.map { $0[time] },
                    densityCurves: curves.map { SIMD3(repeating: $0[time]) },
                    densityCurvesLayers: subLayers.map { point in point.map { SIMD3(repeating: $0[time]) } },
                    densityCurvesModel: DensityCurvesModel(
                        modelType: fitted.modelType,
                        centers: [[Double]](repeating: fitted.centers[time], count: 3),
                        amplitudes: [[Double]](repeating: fitted.amplitudes[time], count: 3),
                        sigmas: [[Double]](repeating: fitted.sigmas[time], count: 3)))
            }
            let standard = Development.asked(nil, of: developments)!
            baseDensity = standard.baseDensity
            densityCurves = standard.densityCurves
            densityCurvesLayers = standard.densityCurvesLayers
            densityCurvesModel = standard.densityCurvesModel
        }
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

/// The engine's bundled data directory (`Resources/`, written by `tools/export_tables.py`).
let resources = Bundle.module.resourceURL!.appending(component: "Resources")
