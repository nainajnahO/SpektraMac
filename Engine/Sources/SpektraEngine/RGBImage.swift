import Accelerate
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// An RGB image as 32-bit floats, interleaved and row-major (NumPy's `height × width × 3`).
public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 3)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The app's working space: linear ITU-R BT.2020, which Spektrafilm accepts as input
    /// (`"ITU-R BT.2020"` without CCTF decoding) and which holds what cameras record.
    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    public struct DecodeError: LocalizedError {
        public let url: URL
        public var errorDescription: String? { "Can't read \(url.lastPathComponent) as an image" }
    }

    /// Decodes any file Core Image reads, upright and colour-managed into ``workingColorSpace``.
    public init(contentsOf url: URL) throws {
        self.init(rendering: try Self.decode(contentsOf: url))
    }

    /// Any file Core Image reads, upright, as Core Image's image of it: decoded as it's rendered
    /// (``Engine/open(_:)`` renders it straight onto the GPU). Camera RAW files are developed
    /// linearly, like Spektrafilm's RAW loader (rawpy with gamma 1 and no auto-brightening): white
    /// balance as shot, and no tone curve, shadow bias, baseline exposure or gamut mapping.
    public static func decode(contentsOf url: URL) throws -> CIImage {
        let image: CIImage?
        // CIRAWFilter opens other images too, so the file's type decides.
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .rawImage) == true, let raw = CIRAWFilter(imageURL: url) {
            raw.boostAmount = 0
            raw.shadowBias = 0
            raw.baselineExposure = 0
            raw.isGamutMappingEnabled = false
            if raw.isLocalToneMapSupported {
                raw.localToneMapAmount = 0
            }
            image = raw.outputImage
        } else if type?.conforms(to: .tiff) == true, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyDepth] as? Int ?? 8) > 8 {
            image = plainImage(from: source, properties: properties)
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        // A RAW file Core Image can't decode comes back with an empty extent.
        guard let image, !image.extent.isEmpty else { throw DecodeError(url: url) }
        return image
    }

    /// The image ImageIO decodes, handed to Core Image as plain memory, upright. For TIFFs over
    /// 8 bits per channel: Core Image reads them slowly otherwise, from the file or from ImageIO's
    /// image alike (8.5 s for a 24 MP 16-bit TIFF with deflate compression, against 0.35 s to
    /// decode it and 0.1 s to convert the copy, which converts the same).
    private static func plainImage(from source: CGImageSource, properties: [CFString: Any]) -> CIImage? {
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = decoded.colorSpace,
              let pixels = decoded.dataProvider?.data,
              let provider = CGDataProvider(data: pixels),
              let copy = CGImage(width: decoded.width, height: decoded.height,
                                 bitsPerComponent: decoded.bitsPerComponent, bitsPerPixel: decoded.bitsPerPixel,
                                 bytesPerRow: decoded.bytesPerRow, space: space, bitmapInfo: decoded.bitmapInfo,
                                 provider: provider, decode: decoded.decode,
                                 shouldInterpolate: decoded.shouldInterpolate, intent: decoded.renderingIntent)
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return CIImage(cgImage: copy).oriented(orientation)
    }

    /// `image` rendered into ``workingColorSpace``.
    private init(rendering image: CIImage) {
        let extent = image.extent.integral
        let (width, height) = (Int(extent.width), Int(extent.height))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        Self.makeContext().render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: extent,
                                  format: .RGBAf, colorSpace: Self.workingColorSpace)
        self.init(width: width, height: height, pixels: rgb(fromRGBA: rgba, width: width, height: height))
    }

    /// The pixels as Core Image's image, in ``workingColorSpace``.
    var ciImage: CIImage {
        let rgba = rgba(fromRGB: pixels, width: width, height: height, alpha: 1)
        return CIImage(bitmapData: Data(bytes: rgba, count: rgba.count * 4), bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: Self.workingColorSpace)
    }

    /// `image` scaled down (Lanczos) to at most `maxPixels` on the long side, for the preview and the
    /// screen. Python's `resize_for_preview` resizes bilinearly after an anti-aliasing blur;
    /// Lanczos does both in one. The edges are extended before scaling so the border pixels keep
    /// full coverage. At least 1 px on a side: a texture can't be empty.
    static func scaledDown(_ image: CIImage, maxPixels: Int) -> CIImage {
        let (width, height) = (image.extent.width, image.extent.height)
        let scale = Double(maxPixels) / Double(max(width, height))
        guard scale < 1 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        let size = CGSize(width: max(1, (Double(width) * scale).rounded()), height: max(1, (Double(height) * scale).rounded()))
        return filter.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    // Full-float working format: Core Image's default half floats would cost precision. On
    // `commandQueue` (the engine's, so its work and the kernels' run in order), or on the system
    // default Metal device, the one ``GPU`` renders on.
    static func makeContext(commandQueue: (any MTLCommandQueue)? = nil) -> CIContext {
        let options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false]
        return commandQueue.map { CIContext(mtlCommandQueue: $0, options: options) } ?? CIContext(options: options)
    }
}

extension CGImage {
    public struct EncodeError: LocalizedError {
        public let url: URL
        public var errorDescription: String? { "Can't write \(url.lastPathComponent)" }
    }

    /// Writes the image, as ``Engine/export(controls:as:)`` makes it, about as `save_image_oiio`
    /// writes a render: its pixels are clipped and rounded already (it truncates: at most a level
    /// apart), 16-bit for TIFF and PNG, 8-bit for JPEG at quality 0.98 (OpenImageIO's 98). TIFFs
    /// are uncompressed, unlike its deflate, which took 2.7 s for 24 MP and saved 4 % on a render
    /// with grain. The file embeds the image's colour space's ICC profile, `metadata`, marked
    /// upright since the pixels are, and `record`.
    public func write(to url: URL, as type: UTType, metadata: PhotoMetadata?, record: EditRecord) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw EncodeError(url: url) }
        var properties = metadata?.properties ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        if type.conforms(to: .jpeg) {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.98
        }
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware] = record.software
        tiff[kCGImagePropertyTIFFImageDescription] = record.summary
        if type.conforms(to: .tiff) {
            tiff[kCGImagePropertyTIFFCompression] = 1  // none
        }
        properties[kCGImagePropertyTIFFDictionary] = tiff
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        iptc[kCGImagePropertyIPTCCaptionAbstract] = record.summary
        iptc[kCGImagePropertyIPTCKeywords] = (iptc[kCGImagePropertyIPTCKeywords] as? [String] ?? []) + record.keywords
        properties[kCGImagePropertyIPTCDictionary] = iptc
        // ImageIO mirrors the records above into XMP's standard fields (CreatorTool, description,
        // subject) and adds these to it.
        let settings = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(settings, EditRecord.namespace as CFString,
                                                        EditRecord.prefix as CFString, nil)
        else { throw EncodeError(url: url) }
        for (name, value) in Self.settings(of: record.controls) {
            guard let tag = CGImageMetadataTagCreate(EditRecord.namespace as CFString, EditRecord.prefix as CFString,
                                                     name as CFString, .default, "\(value)" as CFString),
                  CGImageMetadataSetTagWithPath(settings, nil, "\(EditRecord.prefix):\(name)" as CFString, tag)
            else { throw EncodeError(url: url) }
        }
        CGImageDestinationAddImageAndMetadata(destination, self, settings, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError(url: url) }
    }

    /// `value`'s stored properties by name, for the XMP: a struct's (a diffusion filter's) by its name
    /// and theirs, so the lens filter's strength is `cameraDiffusionStrength`.
    static func settings(of value: Any, prefix: String = "") -> [(name: String, value: Any)] {
        Mirror(reflecting: value).children.flatMap { child -> [(name: String, value: Any)] in
            guard let label = child.label else { return [] }
            let name = prefix.isEmpty ? label : prefix + label.prefix(1).uppercased() + label.dropFirst()
            return Mirror(reflecting: child.value).displayStyle == .struct
                ? settings(of: child.value, prefix: name) : [(name, child.value)]
        }
    }
}

/// Interleaved RGBA floats without their alpha, as interleaved RGB (`width × height` pixels).
func rgb(fromRGBA rgba: [Float], width: Int, height: Int) -> [Float] {
    var rgb = [Float](repeating: 0, count: width * height * 3)
    rgba.withUnsafeBytes { source in
        rgb.withUnsafeMutableBytes { destination in
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                                       height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
            var destination = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * 12)
            precondition(vImageConvert_RGBAFFFFtoRGBFFF(&source, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
        }
    }
    return rgb
}

/// Interleaved RGB floats as interleaved RGBA, `alpha` in every pixel (`width × height` pixels).
func rgba(fromRGB rgb: [Float], width: Int, height: Int, alpha: Float) -> [Float] {
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgb.withUnsafeBytes { source in
        rgba.withUnsafeMutableBytes { destination in
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                                       height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 12)
            var destination = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * 16)
            precondition(vImageConvert_RGBFFFtoRGBAFFFF(&source, nil, alpha, &destination, false,
                                                        vImage_Flags(kvImageNoFlags)) == kvImageNoError)
        }
    }
    return rgba
}

/// What a saved rendering records of how it was made, beside the photo's own metadata: the app
/// (TIFF `Software`), the edit in a line (TIFF `ImageDescription` and IPTC `Caption-Abstract`),
/// keywords after the photo's own (IPTC `Keywords`), and every control by its name, in XMP of the
/// app's own. The camera's EXIF stays as shot: it has no field for a film.
public struct EditRecord: Sendable {
    public let software: String
    public let summary: String
    public let keywords: [String]
    public let controls: Controls

    /// The controls' XMP namespace and its prefix.
    static let namespace = "https://github.com/nainajnahO/SpektraMac/settings/"
    static let prefix = "spektramac"

    public init(software: String, summary: String, keywords: [String], controls: Controls) {
        self.software = software
        self.summary = summary
        self.keywords = keywords
        self.controls = controls
    }
}

/// What a rendering written from a photo keeps of the photo's metadata: its EXIF, GPS and IPTC
/// records and the camera, date and credits of its TIFF record. Not what describes the original
/// pixels: orientation, size and colour space.
public struct PhotoMetadata: @unchecked Sendable {  // immutable property-list values
    let properties: [CFString: Any]

    /// Nil when ImageIO reads no properties from the file.
    public init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var kept: [CFString: Any] = [:]
        if var exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                        kCGImagePropertyExifColorSpace] {
                exif[key] = nil
            }
            kept[kCGImagePropertyExifDictionary] = exif
        }
        kept[kCGImagePropertyGPSDictionary] = all[kCGImagePropertyGPSDictionary]
        kept[kCGImagePropertyIPTCDictionary] = all[kCGImagePropertyIPTCDictionary]
        if let tiff = all[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let keys = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                        kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright]
            kept[kCGImagePropertyTIFFDictionary] = tiff.filter { keys.contains($0.key) }
        }
        properties = kept
    }
}
