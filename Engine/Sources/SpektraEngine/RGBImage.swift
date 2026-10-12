import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
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
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        // A RAW file Core Image can't decode comes back with an empty extent.
        guard let image, !image.extent.isEmpty else { throw DecodeError(url: url) }
        self.init(rendering: image)
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
        return RGBImage(rendering: ciImage(in: Self.workingColorSpace, maxPixels: maxPixels))
    }

    /// An 8-bit sRGB copy no larger than `maxPixels` on its long side, for display (Core Animation
    /// can't texture images over 16384 px). `colorSpace` is the space the pixels are in.
    public func displayImage(in colorSpace: CGColorSpace, maxPixels: Int = 4096) -> CGImage? {
        let image = ciImage(in: colorSpace, maxPixels: maxPixels)
        return Self.makeContext().createCGImage(image, from: image.extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// The pixels as a Core Image image, scaled down (Lanczos) to at most `maxPixels` on the long
    /// side. The edges are extended before scaling so the border pixels keep full coverage.
    private func ciImage(in colorSpace: CGColorSpace, maxPixels: Int) -> CIImage {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = pixels[pixel * 3]
            rgba[pixel * 4 + 1] = pixels[pixel * 3 + 1]
            rgba[pixel * 4 + 2] = pixels[pixel * 3 + 2]
        }
        let image = CIImage(bitmapData: Data(bytes: rgba, count: rgba.count * 4), bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace)
        let scale = Double(maxPixels) / Double(max(width, height))
        guard scale < 1 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        let size = CGSize(width: (Double(width) * scale).rounded(), height: (Double(height) * scale).rounded())
        return filter.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    // Full-float working format: Core Image's default half floats would cost precision.
    private static func makeContext() -> CIContext {
        CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }
}
