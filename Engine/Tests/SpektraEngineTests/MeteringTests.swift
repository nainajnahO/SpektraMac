import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import SpektraEngine

/// A 40 × 30 luminance preview: `top` above the middle row, `bottom` below it.
private func split(top: Double, bottom: Double) -> [Double] {
    (0..<(40 * 30)).map { $0 / 40 < 15 ? top : bottom }
}

/// Regions with the people (and objects) on the bottom half, at the preview's size, and `faces`.
private func bottomHalfRegions(faces: [CGRect] = []) -> MeteringRegions {
    let bottomHalf = WeightMap(values: split(top: 0, bottom: 1).map(Float.init), width: 40, height: 30)
    return MeteringRegions(objects: bottomHalf, people: bottomHalf, faces: faces)
}

/// Centre-weighted is Spektrafilm's auto-exposure, whatever Vision found; As shot is 0.
@Test func centreWeightedIsSpektrafilmsMeter() throws {
    let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
    let space = try Tables.load().colourSpaces["sRGB"]!
    let luminance = image.pixels.withUnsafeBufferPointer {
        meteredLuminance(of: Pixels(base: $0.baseAddress!, width: image.width, height: image.height, components: 3,
                                    rowLength: image.width * 3),
                         colourSpace: space, cctfDecoding: true)
    }
    let readings = MeteringReadings(luminance: luminance.y, width: luminance.width, height: luminance.height,
                                    regions: bottomHalfRegions())
    #expect(readings.ev[MeteringMark.centreWeighted.rawValue] == autoExposureEV(of: image, colourSpace: space, cctfDecoding: true))
    #expect(readings.ev[MeteringMark.asShot.rawValue] == 0)
}

/// People in shade under a bright sky: People meters them to mid-grey, where Centre-weighted
/// leaves them dark.
@Test func peopleInShadeReadBrighter() {
    let readings = MeteringReadings(luminance: split(top: 2, bottom: 0.02), width: 40, height: 30,
                                    regions: bottomHalfRegions())
    let shade = -log2(0.02 / 0.184)
    #expect(readings.ev[MeteringMark.centreWeighted.rawValue]! < shade - 2)
    #expect(abs(readings.ev[MeteringMark.people.rawValue]! - shade) < 1e-9)
    #expect(readings.ev[MeteringMark.faces.rawValue] == nil)
}

/// People under a skylight in a dark room read darker than Centre-weighted: the marks are true
/// readings, darker or brighter.
@Test func spotlitPeopleReadDarker() {
    let readings = MeteringReadings(luminance: split(top: 0.005, bottom: 1), width: 40, height: 30,
                                    regions: bottomHalfRegions())
    #expect(readings.ev[MeteringMark.people.rawValue]! < readings.ev[MeteringMark.centreWeighted.rawValue]! - 0.9)
}

/// A mark Vision found nothing for has no reading; resolving it takes the next broader mark's.
@Test func marksWithNothingFoundResolveBroader() {
    let nothing = WeightMap(values: Array(repeating: 0, count: 16), width: 4, height: 4)
    let none = MeteringReadings(luminance: split(top: 2, bottom: 0.02), width: 40, height: 30,
                                regions: MeteringRegions(objects: nothing, people: nothing, faces: []))
    #expect(none.ev[MeteringMark.objects.rawValue] == nil && none.ev[MeteringMark.people.rawValue] == nil)
    #expect(none.reading(resolving: .faces).mark == .centreWeighted)
    #expect(none.reading(resolving: .asShot).mark == .asShot)

    let peopleOnly = MeteringReadings(luminance: split(top: 2, bottom: 0.02), width: 40, height: 30,
                                      regions: bottomHalfRegions())
    #expect(peopleOnly.reading(resolving: .faces).mark == .people)
}

/// Vision's face boxes have their origin at the lower left; the weights' first row is the top.
@Test func faceBoxesWeightTheRightCorner() {
    let topLeft = CGRect(x: 0, y: 0.75, width: 0.25, height: 0.25)
    let weights = bottomHalfRegions(faces: [topLeft]).weights(for: .faces, width: 8, height: 8)
    #expect(weights[0] == 1 && weights[1 * 8 + 1] == 1)  // top-left corner
    #expect(weights[7 * 8] == 0 && weights[7] == 0)  // bottom-left, top-right
    #expect(weights.reduce(0, +) == 4)
}

/// Opening the golden portrait, its sides brightened like a bright background, finds her face and
/// reads it brighter than the frame; choosing the Faces mark re-renders, as the exposure is part
/// of what the engine keeps between renders.
@Test func openingAPortraitFindsTheFace() async throws {
    let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
    let backlit = image.pixels.enumerated().map { index, value in
        let column = index / 3 % image.width
        return column < image.width / 4 || column >= image.width * 3 / 4 ? value * 3 : value
    }
    // The golden photo is sRGB-encoded (extended: Core Image takes float bitmaps only in extended spaces).
    let rgba = rgba(fromRGB: backlit, width: image.width, height: image.height, alpha: 1)
    let ciImage = CIImage(bitmapData: Data(bytes: rgba, count: rgba.count * 4), bytesPerRow: image.width * 16,
                          size: CGSize(width: image.width, height: image.height), format: .RGBAf,
                          colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
    let engine = try Engine()
    let opened = try await engine.open(ciImage)
    print("Backlit portrait readings by mark: \(opened.metering.ev)")
    let face = try #require(opened.metering.ev[MeteringMark.faces.rawValue])
    #expect(face > opened.metering.ev[MeteringMark.centreWeighted.rawValue]! + 0.5)
    #expect(Set(opened.meteringOverlays.keys).isSuperset(of: [.centreWeighted, .faces]))
    #expect(opened.meteringOverlays[.asShot] == nil)
    #expect(opened.meteringOverlays.values.allSatisfy { $0.width == image.width && $0.height == image.height })

    var controls = Controls()
    let centreWeighted = try await engine.render(controls: controls, mode: .preview)
    controls.exposureMark = .faces
    let faces = try await engine.render(controls: controls, mode: .preview)
    #expect(centreWeighted.pixels != faces.pixels)
}
