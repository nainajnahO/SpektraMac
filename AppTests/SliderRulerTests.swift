import Foundation
import Testing
@testable import SpektraMac

/// Which values a slider's ruler draws a line at, how long, and where a drag, the arrow keys and
/// the trackpad's clicks go from them (``SliderRuler``). Widths are the panel's: about 255 pt for
/// a group's slider, 241 pt for one under Options.
struct SliderRulerTests {
    /// The Y and M filter shifts: 200 steps of 1 CC won't fit, so a line every 5 CC.
    private let filterShift = SliderRuler(range: -100...100, step: 1, neutral: 0, width: 241)
    /// The paper's contrasts: 58 steps of 0.05 fit, a line each.
    private let contrast = SliderRuler(range: 0.1...3, step: 0.05, neutral: 1, width: 241)

    @Test func crowdedStepsGetALineEveryFewSteps() {
        #expect(filterShift.lines.count == 41)
        #expect(filterShift.lines.first?.value == -100)
        #expect(filterShift.lines.last?.value == 100)
        #expect(zip(filterShift.lines, filterShift.lines.dropFirst()).allSatisfy { $1.value - $0.value == 5 })
    }

    @Test func stepsThatFitGetALineEach() {
        #expect(contrast.lines.count == 59)
        #expect(isNear(contrast.lines.first?.value, 0.1))
        #expect(contrast.lines.last?.value == 3)
    }

    @Test func linesAreLongEvery5thAndBrightEvery10thFromNeutral() {
        #expect(rank(at: 0, on: filterShift) == .bright)
        #expect(rank(at: 5, on: filterShift) == .short)
        #expect(rank(at: -25, on: filterShift) == .long)
        #expect(rank(at: 50, on: filterShift) == .bright)
        #expect(rank(at: 1, on: contrast) == .bright)
        #expect(rank(at: 0.75, on: contrast) == .long)
        #expect(rank(at: 1.5, on: contrast) == .bright)
        #expect(rank(at: 1.05, on: contrast) == .short)
    }

    /// Grain size starts at 0.05 and has no neutral value: its lines count from 0, so the long
    /// ones fall on 0.25, 0.5 and so on.
    @Test func linesCountFromZeroWithoutNeutral() {
        let grainSize = SliderRuler(range: 0.05...2, step: 0.05, neutral: nil, width: 255)
        #expect(rank(at: 0.25, on: grainSize) == .long)
        #expect(rank(at: 0.5, on: grainSize) == .bright)
        #expect(rank(at: 0.05, on: grainSize) == .short)
    }

    /// Narrower, the contrast's lines are every 5th step from 1 (0.25 apart), and its ends,
    /// 0.1 and 3, aren't among them: they're lines all the same.
    @Test func endsAreLinesOffTheCount() {
        let narrow = SliderRuler(range: 0.1...3, step: 0.05, neutral: 1, width: 100)
        #expect(isNear(narrow.lines.first?.value, 0.1))
        #expect(isNear(narrow.lines.dropFirst().first?.value, 0.25))
        #expect(narrow.lines.last?.value == 3)
        #expect(rank(at: 0.1, on: narrow) == .short)
    }

    @Test func linesAreAtLeastTheMinimumApart() {
        for (range, step) in [(-100.0...100, 1.0), (-7...11, 0.1), (0...2, 0.02), (0...1, 0.01), (0...3, 0.05)] {
            let ruler = SliderRuler(range: range, step: step, neutral: nil, width: 241)
            let spacing = zip(ruler.lines, ruler.lines.dropFirst()).map { ($1.value - $0.value) / (range.upperBound - range.lowerBound) * 241 }
            // Bar the gap to an end that's off the count.
            #expect(spacing.dropFirst().dropLast().allSatisfy { $0 >= SliderRuler.minimumSpacing - 1e-9 }, "\(range) by \(step)")
        }
    }

    @Test func aDragStopsOnTheNearestLine() {
        #expect(filterShift.nearestLine(to: 3.4) == 5)
        #expect(filterShift.nearestLine(to: 2.4) == 0)
        #expect(filterShift.nearestLine(to: 140) == 100)
    }

    /// From a line or from a value typed between two, the arrow keys go to the next line.
    @Test func theArrowKeysMoveALine() {
        #expect(filterShift.line(after: 5, upward: true) == 10)
        #expect(filterShift.line(after: 3, upward: true) == 5)
        #expect(filterShift.line(after: 3, upward: false) == 0)
        #expect(filterShift.line(after: 100, upward: true) == nil)
        // A value a hair off its line, as a preset can hold, is on it.
        #expect(isNear(contrast.line(after: 1.000_000_1, upward: true), 1.05))
    }

    /// A click for the strongest line a move reaches, not counting the one it leaves.
    @Test func theClickIsForTheStrongestLineReached() {
        #expect(filterShift.strongestLine(from: 0, to: 5) == .short)
        #expect(filterShift.strongestLine(from: 20, to: 30) == .long)
        #expect(filterShift.strongestLine(from: 30, to: 20) == .long)
        #expect(filterShift.strongestLine(from: 25, to: 20) == .short)
        #expect(filterShift.strongestLine(from: 40, to: 60) == .bright)
        #expect(filterShift.strongestLine(from: 3, to: 4) == nil)
    }

    private func rank(at value: Double, on ruler: SliderRuler) -> SliderRuler.Rank? {
        ruler.lines.first { abs($0.value - value) < 1e-9 }?.rank
    }

    private func isNear(_ value: Double?, _ expected: Double) -> Bool {
        value.map { abs($0 - expected) < 1e-9 } ?? false
    }
}
