import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import SpektraEngine

/// A 4 × 2 photo in four colours, a quadrant each: red top left, green top right, blue bottom left,
/// white bottom right.
private let quadrants: CGImage = {
    let (red, green, blue, white): ([UInt8], [UInt8], [UInt8], [UInt8]) =
        ([255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255])
    let rows = [red + red + green + green, blue + blue + white + white]
    let provider = CGDataProvider(data: Data(rows.joined()) as CFData)!
    return CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}()

/// Turning a quarter at a time and straightening (``Framing``): where a photo's pixels and its crop
/// go.
struct FramingTests {
    /// Turned left, the top right corner comes to the top left; each turn moves whole pixels.
    @Test(arguments: [(1, ["green", "white", "red", "blue"]),
                      (2, ["white", "blue", "green", "red"]),
                      (3, ["blue", "red", "white", "green"])])
    func quarterTurnsMoveWholePixels(quarters: Int, corners: [String]) throws {
        let framing = Framing(quarterTurns: quarters)
        let size = CGSize(width: 4, height: 2)
        let turned = framing.applied(to: CIImage(cgImage: quadrants), size: size)
        #expect(turned.extent == CGRect(origin: .zero, size: framing.turned(size)))
        let pixels = try rgb(of: turned, in: turned.extent)
        let (width, height) = (Int(turned.extent.width), Int(turned.extent.height))
        let found = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)].map { x, y in
            name(of: Array(pixels[(y * width + x) * 4..<(y * width + x) * 4 + 3]))
        }
        #expect(found == corners)
    }

    /// The crop turns as the photo does: where its corners go is where it lies turned.
    @Test(arguments: 1...3)
    func cropTurnsWithThePhoto(quarters: Int) {
        let size = CGSize(width: 600, height: 400)
        let crop = CGRect(x: 50, y: 20, width: 300, height: 100)
        let turned = Framing(crop: crop).turned(left: quarters, in: size)
        #expect(turned.quarterTurns == quarters)
        #expect(turned.crop == crop.applying(Framing(quarterTurns: quarters).transform(for: size)))
        #expect(turned.turned(left: -quarters, in: size) == Framing(crop: crop))
    }

    /// Straightened, the photo turns about its middle, which stays the middle of where it lies
    /// unstraightened, and its corners reach past that: a crop of whole pixels there has none bare.
    @Test func straighteningTurnsAboutTheMiddle() throws {
        let size = CGSize(width: 600, height: 400)
        let framing = Framing(angle: 10)
        let middle = CGPoint(x: 300, y: 200)
        let moved = middle.applying(framing.transform(for: size))
        #expect(abs(moved.x - middle.x) < 1e-9 && abs(moved.y - middle.y) < 1e-9)

        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size))
        let straightened = framing.applied(to: grey, size: size)
        #expect(straightened.extent.contains(CGRect(origin: .zero, size: size)))
        // A pixel past the turned photo's corner, in the box around it: its edge reaches on. Core
        // Image rounds the box out to whole pixels, so its outermost ones are partly outside it.
        let corner = CGRect(x: straightened.extent.minX + 5, y: straightened.extent.minY + 5, width: 1, height: 1)
        let pixel = try rgb(of: straightened, in: corner)
        #expect(pixel[3] == 255 && pixel[0] > 100 && pixel[0] == pixel[1] && pixel[1] == pixel[2], "\(pixel)")
    }

    /// `image`'s RGBA bytes in `rect`, rows from the top.
    private func rgb(of image: CIImage, in rect: CGRect) throws -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let cgImage = try #require(context.createCGImage(image, from: rect, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let data = try #require(cgImage.dataProvider?.data as Data?)
        return (0..<cgImage.height).flatMap { row in
            Array(data[row * cgImage.bytesPerRow..<row * cgImage.bytesPerRow + cgImage.width * 4])
        }
    }

    private func name(of rgb: [UInt8]) -> String {
        switch rgb {
        case [255, 0, 0]: "red"
        case [0, 255, 0]: "green"
        case [0, 0, 255]: "blue"
        case [255, 255, 255]: "white"
        default: "\(rgb)"
        }
    }
}

extension PhotoOpeningTests {
    /// The engine frames a photo to the size the framing asks for, and back to all of it.
    @Test func engineFramesToTheSizeAsked() async throws {
        let engine = try Engine()
        _ = try await engine.open(CIImage(cgImage: quadrants).transformed(by: CGAffineTransform(scaleX: 150, y: 150)))
        let turned = try await engine.frame(Framing(quarterTurns: 1))
        #expect(turned.width == 300 && turned.height == 600)
        let cropped = try await engine.frame(Framing(quarterTurns: 3, angle: -4.5, crop: CGRect(x: 20, y: 40, width: 250, height: 380)))
        #expect(cropped.width == 250 && cropped.height == 380)
        let whole = try await engine.frame(.whole)
        #expect(whole.width == 600 && whole.height == 300)
    }
}
