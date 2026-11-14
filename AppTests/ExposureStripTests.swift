import SpektraEngine
import Testing
@testable import SpektraMac

/// Where the Exposure strip draws its dots (``ExposureStrip/dots(of:within:)``): a dot for each
/// run of readings near enough that their dots would touch, at their mean, which a click on it
/// puts the exposure on, so the exposure's line lands on the dot (#359); at As shot's reading if
/// it's one of them, where a photo opens (#364).
struct ExposureStripTests {
    @Test func nearReadingsShareADotAtTheirMean() {
        // People and Faces 0.2 stops apart, Objects 0.3 over Faces: a run of three, as each is
        // within 0.4 stops of the one before. As shot far from them.
        let readings: [(mark: MeteringMark, ev: Double)] = [(.asShot, -2), (.people, 0.5), (.faces, 0.3), (.objects, 0.8)]
        let dots = ExposureStrip.dots(of: readings, within: 0.4)
        #expect(dots.map(\.marks) == [[.asShot], [.objects, .people, .faces]])
        #expect(dots[0].value == -2)
        #expect(abs(dots[1].value - (0.3 + 0.5 + 0.8) / 3) < 1e-12)
    }

    @Test func aDotWithAsShotIsAtAsShot() {
        // Centre-weighted 0.3 over As shot and Objects 0.2 over that: one run, its dot on As shot,
        // not at their mean, 0.27. Faces far from them, at its own.
        let readings: [(mark: MeteringMark, ev: Double)] = [(.objects, 0.5), (.asShot, 0), (.centreWeighted, 0.3), (.faces, 2)]
        let dots = ExposureStrip.dots(of: readings, within: 0.4)
        #expect(dots.map(\.marks) == [[.asShot, .centreWeighted, .objects], [.faces]])
        #expect(dots[0].value == 0)
        #expect(dots[1].value == 2)
    }
}
