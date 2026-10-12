import simd

/// Spektrafilm's `RuntimePhotoParams` after `digest_params`, field for field. Property names are
/// the Python names in camelCase, so the JSON the golden data records decodes directly
/// (`JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`). Grows as stages are ported.
public struct Parameters: Codable, Sendable {
    public var camera = Camera()
    public var filmRender = FilmRender()
    public var enlarger = Enlarger()
    public var printRender = PrintRender()
    public var scanner = Scanner()
    public var io = IO()
    public var settings = Settings()

    public init() {}

    /// Spektrafilm's `ScannerParams`. Black/white correction is not ported (off by default).
    public struct Scanner: Codable, Sendable {
        /// Gaussian σ of the scanner lens, in pixels.
        public var lensBlur = 0.0
        /// σ in pixels, amount; either 0 is off.
        public var unsharpMask = [0.7, 0.7]
    }

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
        /// A key of ``Tables/colourSpaces``.
        public var outputColorSpace = "sRGB"
        public var outputCctfEncoding = true
        public var outputGamutCompress = OutputGamutCompressSpec()
        /// Scan the developed film itself (slides, or viewing the negative) instead of a print.
        public var scanFilm = false
    }

    /// Spektrafilm's `InputGamutCompressSpec`.
    public struct InputGamutCompressSpec: Codable, Sendable, Equatable {
        public var active = true
        /// Only `xy` is ported.
        public var algorithm = "xy"
        /// Reinhard knee (threshold, limit, power).
        public var knee = [0.0, 1.0, 6.0]
    }

    /// Spektrafilm's `OutputGamutCompressSpec`.
    public struct OutputGamutCompressSpec: Codable, Sendable, Equatable {
        /// Only `cam16ucs` and `off` are ported.
        public var algorithm = "cam16ucs"
        /// Reinhard knee on chroma / C_max (threshold, limit, power).
        public var knee = [0.0, 1.0, 6.0]
        /// One-sided Reinhard knee on lightness / the white's lightness, or `nil` for none.
        public var lightnessCompression: [Double]? = [0.7, 1.0, 2.2]
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
        public var neutralPrintFiltersFromDatabase = true
    }

    public struct PrintRender: Codable, Sendable {
        public var densityCurvesMorph = PrintCurvesMorph()
        public var glare = Glare()
    }

    /// Spektrafilm's `GlareParams`: flare in the print viewing, as a random field of the viewing
    /// illuminant added to the scanned XYZ.
    public struct Glare: Codable, Sendable {
        public var active = true
        /// Mean, in percent of the illuminant.
        public var percent = 0.03
        /// Standard deviation relative to the mean.
        public var roughness = 0.7
        /// Gaussian σ of the field, in pixels.
        public var blur = 0.5
    }

    /// Spektrafilm's `PrintCurvesMorphParams`: coupled-gamma reshaping of the paper's fitted
    /// sub-layer curves (fast = lowest-threshold layer) plus developer exhaustion. Off by default.
    public struct PrintCurvesMorph: Codable, Sendable {
        public var active = false
        public var gammaFactor = 1.0
        public var gammaFactorFast = 1.0
        public var gammaFactorSlow = 1.0
        public var gammaFactorRed = 1.0
        public var gammaFactorGreen = 1.0
        public var gammaFactorBlue = 1.0
        /// 0…1: blends every sub-layer toward a Gumbel-max CDF.
        public var developerExhaustion = 0.0
    }

    /// Spektrafilm's `EnlargerParams`. Filter values are Kodak CC units (100 = density 1.0).
    public struct Enlarger: Codable, Sendable {
        /// A key of ``Tables/illuminants``.
        public var illuminant = "TH-KG3"
        public var printExposure = 1.0
        public var printExposureCompensation = true
        public var normalizePrintExposure = true
        public var yFilterShift = 0.0
        public var mFilterShift = 0.0
        public var yFilterNeutral = 55.0
        public var mFilterNeutral = 65.0
        public var cFilterNeutral = 0.0
        public var lensBlur = 0.0
        public var preflashExposure = 0.0
        public var preflashYFilterShift = 0.0
        public var preflashMFilterShift = 0.0

        /// The filters the print is exposed through: neutral plus the user's shifts.
        var printFilters: SIMD3<Double> {
            SIMD3(cFilterNeutral, mFilterNeutral + mFilterShift, yFilterNeutral + yFilterShift)
        }

        /// The filters for the preflash exposure.
        var preflashFilters: SIMD3<Double> {
            SIMD3(cFilterNeutral, mFilterNeutral + preflashMFilterShift, yFilterNeutral + preflashYFilterShift)
        }
    }

    /// `apply_database_neutral_print_filters`: the C, M, Y filters that print a grey neutral for
    /// this film, paper and enlarger lamp. Unknown combinations keep the current values.
    public mutating func applyNeutralPrintFilters(film: Profile, print: Profile,
                                                  database: [String: [String: [String: SIMD3<Double>]]]) {
        guard settings.neutralPrintFiltersFromDatabase,
              let filters = database[print.info.stock]?[enlarger.illuminant]?[film.info.stock]
        else { return }
        enlarger.cFilterNeutral = filters.x
        enlarger.mFilterNeutral = filters.y
        enlarger.yFilterNeutral = filters.z
    }
}

extension Parameters {
    public struct FilmRender: Codable, Sendable {
        /// Scales the film's contrast: the exposure axis of its density curves is divided by it.
        public var densityCurveGamma = 1.0
        public var halation = Halation()
        public var dirCouplers = DirCouplers()
        public var grain = Grain()
    }

    /// Spektrafilm's `GrainParams`. Only the sub-layer model is ported (`sublayers_active`, the
    /// default).
    public struct Grain: Codable, Sendable {
        public var active = true
        public var sublayersActive = true
        /// Area of one silver halide particle in µm², before the scales.
        public var particleAreaUm2 = 0.2
        /// Particle area scale per channel (C, M, Y layers) and per sub-layer (fast to slow).
        public var particleScale = [1.6, 1.6, 3.2]
        public var particleScaleLayers = [2.0, 1.0, 0.5]
        /// Density of fog, per channel.
        public var densityMin = [0.03, 0.03, 0.03]
        /// How evenly particles are spread, per channel: 1 is a perfect grid.
        public var uniformity = [0.97, 0.99, 0.97]
        /// Final Gaussian σ in pixels.
        public var blur = 0.65
        public var blurDyeCloudsUm = 1.0
        /// Clumping: blur in µm, lognormal spread in nm.
        public var microStructure = [0.2, 30]
    }

    /// Spektrafilm's `DirCouplersParams`: development inhibitor release, within a layer
    /// (contrast, local sharpening) and between layers (saturation).
    public struct DirCouplers: Codable, Sendable {
        public var active = true
        public var amount = 1.0
        public var inhibitionSamelayer = 1.0
        public var inhibitionInterlayer = 1.0
        public var gammaSamelayerRgb = [0.341, 0.324, 0.273]
        public var gammaInterlayerRToGb = [0.355, 0.305]
        public var gammaInterlayerGToRb = [0.154, 0.358]
        public var gammaInterlayerBToRg = [0.171, 0.225]
        public var diffusionSizeUm = 20.0
        /// Exponential tail of the inhibitor diffusion.
        public var diffusionTailUm = 200.0
        public var diffusionTailWeight = 0.06

        /// `compute_dir_couplers_matrix` × amount: row = donor layer, column = receiving layer.
        var matrix: simd_double3x3 {
            let r = gammaInterlayerRToGb, g = gammaInterlayerGToRb, b = gammaInterlayerBToRg
            let same = gammaSamelayerRgb.map { $0 * inhibitionSamelayer }
            let i = inhibitionInterlayer
            return amount * simd_double3x3(rows: [
                SIMD3(same[0], r[0] * i, r[1] * i),
                SIMD3(g[0] * i, same[1], g[1] * i),
                SIMD3(b[0] * i, b[1] * i, same[2]),
            ])
        }
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

    /// The film-dependent settings `digest_params` applies (`_apply_film_specifics`): DIR coupler
    /// strengths for positive and negative films and two slide stocks, and the halation preset
    /// keyed by the profile's use and antihalation layer.
    public mutating func applyFilmSpecifics(_ film: Profile) {
        func setCouplers(_ same: [Double], _ r: [Double], _ g: [Double], _ b: [Double]) {
            filmRender.dirCouplers.gammaSamelayerRgb = same
            filmRender.dirCouplers.gammaInterlayerRToGb = r
            filmRender.dirCouplers.gammaInterlayerGToRb = g
            filmRender.dirCouplers.gammaInterlayerBToRg = b
        }
        switch film.info.type {
        case .positive: setCouplers([0.12, 0.08, 0.06], [0.12, 0.06], [0.08, 0.06], [0.06, 0.06])
        case .negative: setCouplers([0.336, 0.319, 0.273], [0.353, 0.302], [0.154, 0.353], [0.168, 0.226])
        }
        applyHalationPreset(film)
        switch film.info.stock {
        case "fujifilm_velvia_100": setCouplers([0.108, 0.072, 0.054], [0.108, 0.054], [0.072, 0.054], [0.054, 0.054])
        case "fujifilm_provia_100f": setCouplers([0.156, 0.104, 0.078], [0.156, 0.078], [0.104, 0.078], [0.078, 0.078])
        default: break
        }
    }

    private mutating func applyHalationPreset(_ film: Profile) {
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
