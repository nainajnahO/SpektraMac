import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SpektraEngine

/// Writes an 8-bit sRGB PNG of `pixels` (RGB bytes) and returns its URL.
private func writePNG(_ pixels: [UInt8], width: Int, height: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(component: "\(UUID()).png")
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

@Test func photoDecodesRendersAndDisplays() async throws {
    // Mid grey and pure red, side by side.
    let url = try writePNG([128, 128, 128, 255, 0, 0], width: 2, height: 1)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try RGBImage(contentsOf: url)
    #expect(image.width == 2 && image.height == 1)
    // colour-science: sRGB decode, then sRGB → BT.2020 primaries.
    let expected: [Double] = [0.2158799901529247, 0.21585396096747733, 0.215848923573429,
                              0.6274413720579783, 0.0690276171470781, 0.016364235071680725]
    #expect(Difference(image.pixels, expected).maxAbsolute < 2e-4)

    let rendered = try await Engine().render(image)
    #expect(rendered.width == 2 && rendered.height == 1)

    let display = try #require(rendered.displayImage(in: RGBImage.workingColorSpace))
    #expect(display.width == 2 && display.height == 1)
}
