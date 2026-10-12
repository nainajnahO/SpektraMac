/// Spektrafilm's `RuntimePhotoParams` after `digest_params`, field for field. Property names are
/// the Python names in camelCase, so the JSON the golden data records decodes directly
/// (`JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`). Grows as stages are ported.
public struct Parameters: Codable, Sendable {
    public var camera = Camera()
    public var filmRender = FilmRender()
    public var io = IO()
    public var settings = Settings()

    public init() {}

    public struct Camera: Codable, Sendable {
        public var exposureCompensationEv = 0.0
        public var autoExposure = true
        /// Only `center_weighted` is ported.
        public var autoExposureMethod = "center_weighted"
        public var lensBlurUm = 0.0
        public var filmFormatMm = 35.0
        /// Band-pass filter edges (amplitude, wavelength nm, width nm); amplitude 0 is off.
        public var filterUv = [0.0, 410, 8]
        public var filterIr = [0.0, 675, 15]
    }

    public struct IO: Codable, Sendable {
        /// A key of ``Tables/colourSpaces``.
        public var inputColorSpace = "ProPhoto RGB"
        public var inputCctfDecoding = false
        public var inputGamutCompress = InputGamutCompressSpec()
    }

    /// Spektrafilm's `InputGamutCompressSpec`.
    public struct InputGamutCompressSpec: Codable, Sendable, Equatable {
        public var active = true
        /// Only `xy` is ported.
        public var algorithm = "xy"
        /// Reinhard knee (threshold, limit, power).
        public var knee = [0.0, 1.0, 6.0]
    }
}

extension Parameters {
    public struct Settings: Codable, Sendable {
        /// Only `hanatos2025` is ported.
        public var rgbToRawMethod = "hanatos2025"
        public var applyHanatos2025AdaptationWindow = true
        /// Not ported (off by default).
        public var applyHanatos2025AdaptationSurface = false
        /// Not ported (0 by default).
        public var spectralGaussianBlur = 0.0
    }
}

extension Parameters {
    public struct FilmRender: Codable, Sendable {
        public var halation = Halation()
    }

    /// Spektrafilm's `HalationParams`: highlight boost, in-emulsion scatter and back-reflection
    /// halation. Per-channel values are R, G, B.
    public struct Halation: Codable, Sendable {
        public var active = true
        public var scatterAmount = 1.0
        public var scatterSpatialScale = 1.0
        public var halationAmount = 1.0
        public var halationSpatialScale = 1.0
        public var scatterCoreUm = [2.2, 2.0, 1.6]
        public var scatterTailUm = [9.3, 9.7, 9.1]
        public var scatterTailWeight = [0.78, 0.65, 0.67]
        public var boostEv = 0.0
        public var boostRange = 0.3
        public var protectEv = 4.0
        public var halationStrength = [0.05, 0.015, 0.0]
        public var halationFirstSigmaUm = [65.0, 65.0, 65.0]
        public var halationNBounces = 3
        public var halationBounceDecay = 0.5
        public var halationRenormalize = true
    }

    /// The film-dependent settings `digest_params` applies (`_apply_film_specifics`). So far: the
    /// halation preset keyed by the profile's use and antihalation layer.
    public mutating func applyFilmSpecifics(_ film: Profile) {
        guard film.info.support == .film else { return }
        // sigma_h from the base (still: triacetate, cine: PET); strength from the antihalation layer.
        let sigma = film.info.use == .still ? 65.0 : 50.0
        let strength: [Double] = switch film.info.antihalation {
        case .strong: [0.015, 0.005, 0.0]
        case .weak: [0.08, 0.02, 0.0]
        case .no: [0.30, 0.10, 0.015]
        }
        filmRender.halation.halationFirstSigmaUm = [sigma, sigma, sigma]
        filmRender.halation.halationStrength = strength
    }
}

extension SIMD3 where Scalar == Double {
    /// A per-channel parameter as Python stores it, a 3-element list.
    init(_ values: [Double]) { self.init(values[0], values[1], values[2]) }
}
