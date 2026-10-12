/// Spektrafilm's `RuntimePhotoParams` after `digest_params`, field for field. Property names are
/// the Python names in camelCase, so the JSON the golden data records decodes directly
/// (`JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`). Grows as stages are ported.
public struct Parameters: Codable, Sendable {
    public var camera = Camera()
    public var io = IO()

    public init() {}

    public struct Camera: Codable, Sendable {
        public var exposureCompensationEv = 0.0
        public var autoExposure = true
        /// Only `center_weighted` is ported.
        public var autoExposureMethod = "center_weighted"
        public var filmFormatMm = 35.0
    }

    public struct IO: Codable, Sendable {
        /// A key of ``Tables/colourSpaces``.
        public var inputColorSpace = "ProPhoto RGB"
        public var inputCctfDecoding = false
    }
}
