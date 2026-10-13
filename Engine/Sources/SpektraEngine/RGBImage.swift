import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
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

    public struct DecodeError: Error, CustomStringConvertible {
        public let url: URL
        public var description: String { "Can't read \(url.lastPathComponent) as an image" }
    }

    /// Decodes any file Core Image reads, upright and colour-managed into ``workingColorSpace``.
    /// Camera RAW files are developed linearly, like Spektrafilm's RAW loader (rawpy with gamma 1
    /// and no auto-brightening): white balance as shot, and no tone curve, shadow bias, baseline
    /// exposure or gamut mapping.
    public init(contentsOf url: URL) throws {
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
            image = Self.plainImage(from: source, properties: properties)
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        // A RAW file Core Image can't decode comes back with an empty extent.
        guard let image, !image.extent.isEmpty else { throw DecodeError(url: url) }
        self.init(rendering: image)
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
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        self.init(width: width, height: height, pixels: rgb)
    }

    /// A copy no larger than `maxPixels` on its long side, for the preview. Python's
    /// `resize_for_preview` resizes bilinearly after an anti-aliasing blur; Core Image's Lanczos
    /// does both in one.
    public func resized(maxPixels: Int) -> RGBImage {
        guard max(width, height) > maxPixels else { return self }
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = pixels[pixel * 3]
            rgba[pixel * 4 + 1] = pixels[pixel * 3 + 1]
            rgba[pixel * 4 + 2] = pixels[pixel * 3 + 2]
        }
        let image = CIImage(bitmapData: Data(bytes: rgba, count: rgba.count * 4), bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: Self.workingColorSpace)
        return RGBImage(rendering: Self.scaledDown(image, maxPixels: maxPixels))
    }

    /// `image` scaled down (Lanczos) to at most `maxPixels` on the long side. The edges are
    /// extended before scaling so the border pixels keep full coverage.
    static func scaledDown(_ image: CIImage, maxPixels: Int) -> CIImage {
        let (width, height) = (image.extent.width, image.extent.height)
        let scale = Double(maxPixels) / Double(max(width, height))
        guard scale < 1 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        let size = CGSize(width: (Double(width) * scale).rounded(), height: (Double(height) * scale).rounded())
        return filter.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    public struct EncodeError: Error, CustomStringConvertible {
        public let url: URL
        public var description: String { "Can't write \(url.lastPathComponent)" }
    }

    /// Writes the pixels, already encoded in `colorSpace`, as `save_image_oiio` does: clipped to
    /// [0, 1] and truncated to integers, 16-bit for TIFF (deflate) and PNG, 8-bit for JPEG
    /// (quality 0.98, OpenImageIO's 98). The file embeds `colorSpace`'s ICC profile and
    /// `metadata`, marked upright since the pixels are.
    public func write(to url: URL, as type: UTType, colorSpace: CGColorSpace, metadata: PhotoMetadata?) throws {
        let bits = type.conforms(to: .jpeg) ? 8 : 16
        // NaN (outside the colour model) as black, as NumPy's cast gives.
        func clipped(_ value: Float) -> Float { value.isNaN ? 0 : min(max(value, 0), 1) }
        let data = bits == 16 ? pixels.map { UInt16(clipped($0) * 65535) }.withUnsafeBytes { Data($0) }
                              : pixels.map { UInt8(clipped($0) * 255) }.withUnsafeBytes { Data($0) }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: 3 * bits,
                                  bytesPerRow: width * 3 * bits / 8, space: colorSpace,
                                  bitmapInfo: bits == 16 ? .byteOrder16Little : [],
                                  provider: CGDataProvider(data: data as CFData)!, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw EncodeError(url: url) }
        var properties = metadata?.properties ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        if type.conforms(to: .jpeg) {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.98
        }
        if type.conforms(to: .tiff) {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 8  // deflate
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError(url: url) }
    }

    // Full-float working format: Core Image's default half floats would cost precision.
    // The system default Metal device, the one ``GPU`` renders on.
    static func makeContext() -> CIContext {
        CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
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
