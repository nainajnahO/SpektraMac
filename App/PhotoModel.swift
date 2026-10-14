import AppKit
import Foundation
import Observation
import SpektraEngine
import UniformTypeIdentifiers
import os

@MainActor
@Observable
final class PhotoModel {
    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
    }

    /// The open photo (on the engine's GPU): its file name, size and preview size, and what the
    /// metering marks found in it.
    struct Photo: Identifiable {
        let id = UUID()
        let name: String
        let width: Int
        let height: Int
        let previewWidth: Int
        let previewHeight: Int
        let metering: MeteringReadings
        /// The region each mark meters, white with the weight as alpha.
        let meteringOverlays: [MeteringMark: CGImage]

        /// Whether the preview is scaled down from the photo, so the photo has a reduced size.
        var isLargerThanPreview: Bool { width > previewWidth || height > previewHeight }
    }
    /// A new photo renders at once.
    private(set) var photo: Photo? {
        didSet { scheduleRender() }
    }
    /// The photo's EXIF, GPS and IPTC records, for saved renderings.
    @ObservationIgnored private var metadata: PhotoMetadata?
    /// What the sidebar and the Print | Film switch set; every change re-renders the preview.
    var controls = Controls() {
        didSet { scheduleRender() }
    }
    /// The film. Choosing one applies the defaults made for it, if any; otherwise it picks the
    /// paper the film is meant to be printed on and, as Spektrafilm's GUI does, views slides
    /// directly instead of printing them, keeping the other controls.
    var film: String {
        get { controls.film }
        set {
            if let defaults = savedDefaults(for: newValue) {
                controls = defaults
            } else {
                controls = factoryControls(for: newValue, from: controls)
            }
        }
    }
    var filmName: String { films.first { $0.stock == controls.film }?.name ?? controls.film }
    /// A slide is viewed, never printed: every paper is negative-working, so a printed slide
    /// comes out as a negative image.
    var isSlideFilm: Bool { films.first { $0.stock == controls.film }?.type == .positive }
    var films: [ProfileInfo] { engine?.films ?? [] }
    var papers: [ProfileInfo] { engine?.papers ?? [] }
    /// The exposure the slider shows, in stops over the photo as shot: the controls' mark's
    /// reading for this photo plus their offset. Set within ``snap`` of a mark, it lands on the
    /// mark; elsewhere it keeps the nearest mark and the offset from it, so the next photo opens
    /// as far from that mark's own reading.
    var exposureEV: Double {
        get {
            guard let photo else { return controls.exposureOffsetEV }
            return photo.metering.reading(resolving: controls.exposureMark).ev + controls.exposureOffsetEV
        }
        set {
            guard let photo else { return }
            let nearest = MeteringMark.allCases.compactMap { mark in photo.metering.ev[mark.rawValue].map { (mark, $0) } }
                .min { abs($0.1 - newValue) < abs($1.1 - newValue) }!
            var controls = controls
            controls.exposureMark = nearest.0
            controls.exposureOffsetEV = abs(newValue - nearest.1) < Self.snap ? 0 : newValue - nearest.1
            self.controls = controls
        }
    }
    /// How close to a mark the slider lands on it, in stops.
    static let snap = 0.15
    /// The marks the exposure is on: those whose reading for this photo rounds to it.
    var marksAtExposure: [MeteringMark] {
        guard let photo else { return [] }
        let exposure = exposureEV
        return MeteringMark.allCases.filter { mark in
            photo.metering.ev[mark.rawValue].map { abs($0 - exposure) < 0.05 } ?? false
        }
    }
    /// While the Exposure slider is held: the canvas then tints the region the mark it's on meters.
    var isAdjustingExposure = false
    /// Display-sized rendering of the last simulation.
    private(set) var displayImage: CGImage?
    /// The render `displayImage` comes from.
    private(set) var shownMode: RenderMode?
    /// Whether the canvas may show the photo larger than its reduced size: the pointer is over it,
    /// or it's zoomed in. Only then does the whole photo render.
    var wantsFullResolution = false {
        didSet {
            if wantsFullResolution && awaitsFullResolution {
                render(fullResolutionOnly: true)
            }
        }
    }
    /// The reduced render is on screen and the controls haven't changed since.
    private var awaitsFullResolution = false
    private(set) var isLoading = false
    private(set) var isRendering = false
    private(set) var isRenderingFullResolution = false
    /// What saving is doing, while it runs.
    private(set) var savePhase: String?
    private(set) var errorMessage: String?
    private(set) var log: [LogEntry] = []
    /// Drives the Open panel (`fileImporter`); ⌘O and the toolbar set it.
    var isImporting = false

    private let engine: Engine?
    private let logger = Logger(subsystem: "nainajnahO.SpektraMac", category: "model")
    private var renderTask: Task<Void, Never>?
    private var renderScheduled = false
    private var saveTask: Task<Void, Never>?

    init() {
        do {
            engine = try Engine()
        } catch {
            engine = nil
            errorMessage = "Metal is unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: Opening

    func open(_ url: URL) {
        guard let engine else { return }
        // Files from the Open panel are security-scoped; dropped files are already accessible.
        let scoped = url.startAccessingSecurityScopedResource()
        isLoading = true
        errorMessage = nil
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let (image, metadata) = try await Task.detached(priority: .userInitiated) {
                    (try RGBImage.decode(contentsOf: url), PhotoMetadata(contentsOf: url))
                }.value
                // The engine opens the photo once it's done rendering the last one: stop that.
                renderTask?.cancel()
                isRendering = false
                isRenderingFullResolution = false
                awaitsFullResolution = false
                let opened = try await engine.open(image)
                self.metadata = metadata
                photo = Photo(name: url.lastPathComponent, width: opened.width, height: opened.height,
                              previewWidth: opened.previewWidth, previewHeight: opened.previewHeight,
                              metering: opened.metering, meteringOverlays: opened.meteringOverlays)
                note("Opened \(url.lastPathComponent) (\(opened.width) × \(opened.height))")
            } catch {
                fail("Could not open \(url.lastPathComponent)", error)
            }
            isLoading = false
        }
    }

    func importFailed(_ error: Error) {
        fail("Could not open the file", error)
    }

    // MARK: Rendering

    /// How long the controls stay still before the blurs and grain render.
    private static let fullRenderDelay = Duration.milliseconds(500)

    /// Renders once per main-actor turn, however many settings changed in it.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            renderScheduled = false
            render()
        }
    }

    /// Renders the preview, then, once the controls have been still for `fullRenderDelay`, with
    /// the blurs and grain the preview leaves out: at the preview's size, and the whole photo once
    /// ``wantsFullResolution``. A photo no larger than its preview renders whole at once. A newer
    /// change cancels them.
    private func render(fullResolutionOnly: Bool = false) {
        renderTask?.cancel()
        isRenderingFullResolution = false
        awaitsFullResolution = false
        guard let photo, let engine else {
            displayImage = nil
            isRendering = false
            return
        }
        isRendering = true
        let controls = controls
        renderTask = Task {
            do {
                if !fullResolutionOnly {
                    try await show(controls: controls, mode: .preview, engine: engine, photo: photo)
                    isRendering = false
                    try await Task.sleep(for: Self.fullRenderDelay)
                    isRendering = true
                    if photo.isLargerThanPreview {
                        try await show(controls: controls, mode: .reduced, engine: engine, photo: photo)
                    }
                }
                if wantsFullResolution || !photo.isLargerThanPreview {
                    isRenderingFullResolution = true
                    try await show(controls: controls, mode: .full, engine: engine, photo: photo)
                } else {
                    awaitsFullResolution = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render", error)
            }
            isRendering = false
            isRenderingFullResolution = false
        }
    }

    /// Renders the photo and puts it on screen, unless a newer change has made it stale.
    private func show(controls: Controls, mode: RenderMode, engine: Engine, photo: Photo) async throws {
        let start = ContinuousClock.now
        let display = try await engine.display(controls: controls, mode: mode)
        try Task.checkCancellation()
        displayImage = display
        shownMode = mode
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
        let size = mode == .full ? "\(photo.width) × \(photo.height)" : "\(photo.previewWidth) × \(photo.previewHeight)"
        let name = switch mode {
        case .preview: "preview"
        case .reduced: "reduced size"
        case .full, .export: "full resolution"
        }
        note("Rendered \(name) (\(size)) in \(elapsed)")
    }

    // MARK: Saving and cancelling

    var canSave: Bool { photo != nil && engine != nil && savePhase == nil }
    var canCancel: Bool { savePhase != nil }

    /// Renders the photo at full resolution, sRGB-encoded, and writes it where the Save panel says:
    /// 16-bit TIFF or PNG, or JPEG, by the name's extension.
    func save() {
        guard let photo, let engine else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .tiff, .png]
        panel.nameFieldStringValue = (photo.name as NSString).deletingPathExtension + ".jpg"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
        let (controls, metadata) = (controls, metadata)
        savePhase = "Rendering \(url.lastPathComponent) at full resolution…"
        saveTask = Task {
            defer { savePhase = nil; saveTask = nil }
            let start = ContinuousClock.now
            do {
                let output = try await engine.render(controls: controls, mode: .export)
                try Task.checkCancellation()
                savePhase = "Writing \(url.lastPathComponent)…"
                try await Task.detached(priority: .userInitiated) {
                    try output.write(to: url, as: type, colorSpace: Engine.exportColorSpace, metadata: metadata)
                }.value
                let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))
                note("Saved \(url.lastPathComponent) in \(elapsed)")
            } catch is CancellationError {
                note("Cancelled saving \(url.lastPathComponent)")
            } catch {
                fail("Could not save \(url.lastPathComponent)", error)
            }
        }
    }

    /// Stops a save; the GPU stops at its next memory flush.
    func cancel() {
        saveTask?.cancel()
    }

    // MARK: Presets

    var canUsePresets: Bool { engine != nil }

    func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(filmName).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controls.preset().write(to: url, options: .atomic)
            note("Saved preset \(url.lastPathComponent)")
        } catch {
            fail("Could not save the preset", error)
        }
    }

    func openPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preset = try Controls(preset: Data(contentsOf: url))
            guard films.contains(where: { $0.stock == preset.film }),
                  papers.contains(where: { $0.stock == preset.paper }) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown film or paper (\(preset.film), \(preset.paper))",
                ])
            }
            controls = preset
            note("Opened preset \(url.lastPathComponent)")
        } catch {
            fail("Could not open the preset", error)
        }
    }

    /// Makes the current controls what choosing this film applies from now on.
    func makeDefaultForFilm() {
        do {
            try UserDefaults.standard.set(controls.preset(), forKey: Self.defaultsKey(controls.film))
            note("Made these settings the default for \(filmName)")
        } catch {
            fail("Could not save the default for \(filmName)", error)
        }
    }

    /// Forgets the film's saved defaults and returns every control to the app's own.
    func restoreFactoryDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(controls.film))
        controls = factoryControls(for: controls.film, from: Controls())
        note("Restored the factory defaults for \(filmName)")
    }

    private static func defaultsKey(_ film: String) -> String { "filmDefaults.\(film)" }

    private func savedDefaults(for film: String) -> Controls? {
        guard let preset = UserDefaults.standard.data(forKey: Self.defaultsKey(film)) else { return nil }
        do {
            return try Controls(preset: preset)
        } catch {
            fail("Ignored the saved defaults for \(film)", error)
            return nil
        }
    }

    /// `controls` with `film`, its target paper (if it has one) and slides viewed directly.
    private func factoryControls(for film: String, from controls: Controls) -> Controls {
        var controls = controls
        controls.film = film
        guard let info = films.first(where: { $0.stock == film }) else { return controls }
        if let paper = info.targetPrint {
            controls.paper = paper
        }
        controls.scanFilm = info.type == .positive
        return controls
    }

    // MARK: Helpers

    private func note(_ message: String) {
        log.append(LogEntry(message: message))
        logger.notice("\(message, privacy: .public)")
    }

    private func fail(_ context: String, _ error: Error) {
        errorMessage = "\(context): \(error.localizedDescription)"
        note("⚠️ \(errorMessage ?? context)")
    }
}
