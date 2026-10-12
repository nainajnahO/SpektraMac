/// Spektrafilm's `RuntimePhotoParams` after `digest_params`, field for field. Property names are
/// the Python names in camelCase, so the JSON the golden data records decodes directly
/// (`JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`). Grows as stages are ported.
public struct Parameters: Codable, Sendable {
    public var camera = Camera()
    public var io = IO()
    public var settings = Settings()

    public init() {}

    public struct Camera: Codable, Sendable {
        public var exposureCompensationEv = 0.0
        public var autoExposure = true
        /// Only `center_weighted` is ported.
        public var autoExposureMethod = "center_weighted"
        public var filmFormatMm = 35.0
        /// Band-pass filter edges (amplitude, wavelength nm, width nm); amplitude 0 is off.
        public var filterUv = [0.0, 410, 8]
        public var filterIr = [0.0, 675, 15]
    }

    public struct IO: Codable, Sendable {
        /// A key of ``Tables/colourSpaces``.
        public var inputColorSpace = "ProPhoto RGB"
        public var inputCctfDecoding = false
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
