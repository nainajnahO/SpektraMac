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

    let rendered = try await Engine().render(image, scanFilm: false, preview: false)
    #expect(rendered.width == 2 && rendered.height == 1)

    let display = try #require(rendered.displayImage(in: Engine.outputColorSpace))
    #expect(display.width == 2 && display.height == 1)
}

/// The synthetic DNG `tools/golden.py` writes (camera RGB = linear sRGB): developed linearly, its
/// grey patches keep their raw values, which grey keeps in BT.2020 too. Then it renders.
@Test func rawDecodesLinearlyAndRenders() async throws {
    let image = try RGBImage(contentsOf: goldenDirectory.appending(components: "raw", "patches.dng"))
    #expect(image.width == 512 && image.height == 256)
    for (patch, raw) in [0.05, 0.1, 0.2, 0.4].enumerated() {
        let index = (128 * image.width + patch * 128 + 64) * 3
        let rgb = image.pixels[index..<(index + 3)].map(Double.init)
        print("raw \(raw): \(rgb)")
        #expect(rgb.allSatisfy { abs($0 / raw - 1) < 0.005 })
    }

    let rendered = try await Engine().render(image, scanFilm: false, preview: false)
    #expect(rendered.width == 512 && rendered.height == 256)
    let finite = rendered.pixels.allSatisfy { $0.isFinite }
    #expect(finite)
}

/// The preview's parameters are Python's `digest_params` with `preview_mode`, and its image is
/// down-sized to Spektrafilm's `preview_max_size` on the long side.
@Test func previewMatchesPython() async throws {
    var parameters = try GoldenCase("photo-kodak_portra_400-kodak_portra_endura").params
    parameters.applyPreviewMode()
    #expect(parameters == (try GoldenCase("preview-kodak_portra_400-kodak_portra_endura").params))

    let engine = try Engine()
    let preview = engine.preview(of: RGBImage(width: 3000, height: 2000, pixels: [Float](repeating: 0.18, count: 3000 * 2000 * 3)))
    #expect(preview.width == 640 && preview.height == 427)
    #expect(preview.pixels.allSatisfy { abs($0 - 0.18) < 1e-5 })
    let rendered = try await engine.render(preview, scanFilm: true, preview: true)
    #expect(rendered.width == 640 && rendered.height == 427)
}
