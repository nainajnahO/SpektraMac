import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

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
    public init(contentsOf url: URL) throws {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw DecodeError(url: url)
        }
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

    /// An 8-bit sRGB copy no larger than `maxPixels` on its long side, for display (Core Animation
    /// can't texture images over 16384 px). `colorSpace` is the space the pixels are in.
    public func displayImage(in colorSpace: CGColorSpace, maxPixels: Int = 4096) -> CGImage? {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = pixels[pixel * 3]
            rgba[pixel * 4 + 1] = pixels[pixel * 3 + 1]
            rgba[pixel * 4 + 2] = pixels[pixel * 3 + 2]
        }
        var image = CIImage(bitmapData: Data(bytes: rgba, count: rgba.count * 4), bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace)
        let scale = min(1, Double(maxPixels) / Double(max(width, height)))
        if scale < 1 {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(scale)
            image = filter.outputImage ?? image
        }
        return Self.makeContext().createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    // Full-float working format: Core Image's default half floats would cost precision.
    private static func makeContext() -> CIContext {
        CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }
}
