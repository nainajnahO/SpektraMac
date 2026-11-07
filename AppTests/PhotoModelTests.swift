import AppKit
import Foundation
import SpektraEngine
import Testing
import UniformTypeIdentifiers
@testable import SpektraMac

/// `PhotoModel` with the real engine, in the app: what renders (``PhotoModel/log``), what's set
/// (``PhotoModel/controls``) and what Undo says. Each test's model keeps its settings in a suite of
/// the test's own and leaves its photos out of the recent documents, so a test run leaves the app's
/// settings and File › Open Recent as they were. One test at a time: each model has an engine of
/// its own on the one GPU.
@Suite(.serialized)
final class PhotoModelTests {
    /// The test's photos, presets and settings, removed after.
    private let folder = URL.temporaryDirectory.appending(path: "PhotoModelTests-\(UUID().uuidString)")
    /// The test's settings: a suite named by a path is kept there, in the test's folder, not with
    /// the app's preferences, where an emptied suite would leave its file behind.
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = folder.appending(path: "Settings.plist").path
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: A held slider

    /// While a slider is held, a change renders only the preview; once it's let go, the screen-size
    /// render and the strips follow.
    @Test func heldSliderRendersOnlyPreviewsUntilLetGo() async throws {
        let model = try await openedModel()
        let start = model.log.count
        model.isAdjusting = true
        for value in [1.1, 1.2, 1.3] {
            let before = model.log.count
            model.controls.printExposure = value
            try await until { messages(of: model, since: before).contains { $0.hasPrefix("Rendered preview") } }
        }
        // Held a while longer: nothing else renders.
        try await Task.sleep(for: .seconds(1))
        let held = messages(of: model, since: start)
        #expect(held.allSatisfy(isPreview), "\(held)")

        let released = model.log.count
        model.isAdjusting = false
        try await until {
            let after = messages(of: model, since: released)
            return after.contains { $0.hasPrefix("Rendered screen size") } && after.contains { $0.contains("thumbnails in") }
        }
    }

    /// Zoomed in, a slider held and dragged back over a value already shown shows its kept render,
    /// and should stop there until it's let go (#289): today it carries on to the full-size render.
    @Test func heldSliderBackOverAKeptRenderZoomedIn() async throws {
        let model = try await openedModel()
        model.wantsFullResolution = true
        try await until { model.log.contains { $0.message.hasPrefix("Rendered full resolution") } }
        let shown = model.controls

        let start = model.log.count
        model.isAdjusting = true
        model.controls.printExposure = 1.2
        try await until { messages(of: model, since: start).contains { $0.hasPrefix("Rendered preview") } }
        let back = model.log.count
        model.controls = shown
        try await until { messages(of: model, since: back).contains { $0.hasPrefix("Showed the kept screen size") } }
        try await Task.sleep(for: .seconds(1))
        let held = messages(of: model, since: start)
        withKnownIssue("#289: a kept render carries on to the full-size render while the slider is held", isIntermittent: true) {
            #expect(held.allSatisfy(isPreview), "\(held)")
        }
        model.isAdjusting = false
    }

    // MARK: Reset

    /// Reset returns an adjustment to the film's saved defaults, and ``PhotoModel/isAtDefaults(_:)``
    /// follows (#284).
    @Test func resetReturnsToTheFilmsSavedDefaults() async throws {
        let model = try await makeModel()
        model.controls.grainSize = 0.5
        model.makeDefaultForFilm()
        #expect(model.isAtDefaults(.grain))

        model.controls.grainSize = 1.2
        #expect(!model.isAtDefaults(.grain))
        model.reset(.grain)
        #expect(model.controls.grainSize == 0.5)
        #expect(model.isAtDefaults(.grain))
    }

    // MARK: Presets

    /// A preset's numbers out of range open brought within them, and the Log says which (#284).
    @Test func presetOutOfRangeOpensClamped() async throws {
        let model = try await makeModel()
        var preset = Controls()
        preset.printContrast = 9
        preset.grainSize = 0
        let url = try write(preset, named: "Out of range.json")
        model.openPreset(url)
        #expect(model.failure == nil)
        #expect(model.controls.printContrast == Controls.range(\.printContrast).upperBound)
        #expect(model.controls.grainSize == Controls.range(\.grainSize).lowerBound)
        // As the app lists them, in this Mac's language.
        let changed = ["printContrast", "grainSize"].formatted(.list(type: .and))
        #expect(model.log.contains {
            $0.message == "Changed \(changed) from Out of range.json to what SpektraMac can render"
        })
    }

    /// A preset naming a film the app doesn't have is refused, with an alert, and changes nothing
    /// (#284).
    @Test func presetWithAnUnknownFilmIsRefused() async throws {
        let model = try await makeModel()
        var preset = Controls()
        preset.film = "kodak_unknown_100"
        let url = try write(preset, named: "Unknown film.json")
        let before = model.controls
        model.openPreset(url)
        #expect(model.failure?.title == "Couldn't open the preset.")
        #expect(model.controls == before)
    }

    // MARK: Undo

    /// A slider's drag undoes in one step, named after its settings group; Open Preset and Restore
    /// Factory Defaults undo under their own names.
    @Test func undoStepsAndTheirNames() async throws {
        let model = try await makeModel()
        let undoManager = UndoManager()
        // Each step below is an event of its own, its changes in an undo group of their own, as a
        // window's undo manager groups them after each event in the app.
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        let start = model.controls

        event(undoManager) { model.isAdjusting = true }
        for value in stride(from: 1.05, through: 1.5, by: 0.05) {
            event(undoManager) { model.controls.printExposure = value }
        }
        event(undoManager) { model.isAdjusting = false }
        #expect(undoManager.undoActionName == "Enlarger")

        var preset = Controls()
        preset.printContrast = 1.4
        let url = try write(preset, named: "Contrast.json")
        event(undoManager) { model.openPreset(url) }
        #expect(undoManager.undoActionName == "Open Preset")

        event(undoManager) { model.restoreFactoryDefaults() }
        #expect(undoManager.undoActionName == "Restore Factory Defaults")

        undoManager.undo()
        #expect(model.controls.printContrast == 1.4)
        undoManager.undo()
        #expect(model.controls.printExposure == 1.5)
        undoManager.undo()
        #expect(model.controls == start)
        #expect(undoManager.redoActionName == "Enlarger")
    }

    // MARK: The edit record

    /// What a saved photo records of its edit: the film printed on the paper, or scanned, the
    /// exposure and the adjustments switched on.
    @Test func editRecordSummary() async throws {
        let model = try await makeModel()
        model.controls.exposureOffsetEV = 0.5
        model.controls.burn = true
        model.controls.cameraDiffusion.active = true
        // Numbers as the app writes them, in this Mac's format.
        let stops = 0.5.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
        let lens = "Black Pro-Mist \(0.5.formatted(.number.precision(.fractionLength(0...3)))) on the lens"
        #expect(model.editRecord.summary == "\(model.filmName) printed on \(model.paperName) · \(stops) EV · "
            + "\(lens) · halation · couplers · grain · burn · glare")
        #expect(model.editRecord.keywords == [model.filmName, model.paperName, "SpektraMac"])

        // Scanned, the print's own adjustments are left out.
        model.controls.scanFilm = true
        #expect(model.editRecord.summary == "\(model.filmName), scanned · \(stops) EV · \(lens) · halation · couplers · grain")
        #expect(model.editRecord.keywords == [model.filmName, "SpektraMac"])
    }

    // MARK: Opening

    /// A photo opened while another is still opening is the one that shows (#192), and neither goes
    /// to the recent documents.
    @Test func photoOpenedSecondShows() async throws {
        let model = try await makeModel()
        let recent = NSDocumentController.shared.recentDocumentURLs
        let first = try photo(named: "First.jpg", width: 3000, height: 2000)
        let second = try photo(named: "Second.jpg", width: 300, height: 200)
        model.open(first)
        model.open(second)
        #expect(model.isLoading)
        try await until { !model.isLoading }
        #expect(model.photo?.name == "Second.jpg")
        // The first, dropped, doesn't show later either.
        try await Task.sleep(for: .seconds(1))
        #expect(model.photo?.name == "Second.jpg")
        #expect(model.recentPhotos == recent)
        #expect(NSDocumentController.shared.recentDocumentURLs == recent)
    }

    // MARK: Helpers

    /// A model as the app makes one, once its engine is there, with the tests' settings.
    private func makeModel() async throws -> PhotoModel {
        let model = PhotoModel(defaults: defaults, addsToRecentPhotos: false)
        try await until { !model.films.isEmpty }
        return model
    }

    /// A model with a photo open on a canvas smaller than it, once the photo's renders are done:
    /// the preview, the screen-size render and the strips.
    private func openedModel() async throws -> PhotoModel {
        let model = try await makeModel()
        model.canvasLongSide = 400
        model.open(try photo(named: "Photo.jpg", width: 1200, height: 800))
        try await until { model.log.contains { $0.message.contains("thumbnails in") } }
        #expect(model.log.contains { $0.message.hasPrefix("Rendered screen size (400 × ") })
        return model
    }

    /// A photo of `width` × `height` as a JPEG in the tests' folder, written as Save writes one: a
    /// gradient from dark blue to light orange, with every tone between.
    private func photo(named name: String, width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colours = [CGColor(srgbRed: 0.05, green: 0.1, blue: 0.4, alpha: 1), CGColor(srgbRed: 0.95, green: 0.7, blue: 0.2, alpha: 1)]
        let gradient = try #require(CGGradient(colorsSpace: nil, colors: colours as CFArray, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let url = folder.appending(path: name)
        let record = EditRecord(software: "PhotoModelTests", summary: "", keywords: [], controls: Controls())
        try #require(context.makeImage()).write(to: url, as: .jpeg, metadata: nil, record: record)
        return url
    }

    /// `controls` as a preset file in the tests' folder.
    private func write(_ controls: Controls, named name: String) throws -> URL {
        let url = folder.appending(path: name)
        try controls.preset().write(to: url)
        return url
    }

    /// The Log's messages from entry `start` on.
    private func messages(of model: PhotoModel, since start: Int) -> [String] {
        model.log.dropFirst(start).map(\.message)
    }

    /// What a held slider may render: the preview, or a kept render shown in its place.
    private func isPreview(_ message: String) -> Bool {
        message.hasPrefix("Rendered preview") || message.hasPrefix("Showed the kept screen size")
    }

    /// Makes `step`'s changes one undo group, as an event's are in the app.
    private func event(_ undoManager: UndoManager, _ step: () -> Void) {
        undoManager.beginUndoGrouping()
        step()
        undoManager.endUndoGrouping()
    }

    private struct TimedOut: Error {}

    /// Waits until `condition` holds, letting the model's tasks run: at most `timeout`.
    private func until(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
