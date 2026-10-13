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

    /// The open photo (on the engine's GPU): its file name, size and preview size.
    struct Photo: Identifiable {
        let id = UUID()
        let name: String
        let width: Int
        let height: Int
        let previewWidth: Int
        let previewHeight: Int
    }
    /// A new photo renders at once.
    private(set) var photo: Photo? {
        didSet { scheduleRender() }
    }
    /// The photo's EXIF, GPS and IPTC records, for saved renderings.
    @ObservationIgnored private var metadata: PhotoMetadata?
    /// What the sidebar and the Film | Negative switch set; every change re-renders the preview.
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
    var films: [ProfileInfo] { engine?.films ?? [] }
    var papers: [ProfileInfo] { engine?.papers ?? [] }
    /// Display-sized rendering of the last simulation.
    private(set) var displayImage: CGImage?
    /// Whether `displayImage` comes from the full-resolution render rather than the preview.
    private(set) var showsFullResolution = false
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
                let opened = try await engine.open(image)
                self.metadata = metadata
                photo = Photo(name: url.lastPathComponent, width: opened.width, height: opened.height,
                              previewWidth: opened.previewWidth, previewHeight: opened.previewHeight)
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

    /// How long the controls stay still before the whole photo renders.
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

    /// Renders the preview, then, once the controls have been still for `fullRenderDelay`, the
    /// whole photo with the blurs and grain the preview leaves out. A newer change cancels both.
    private func render() {
        renderTask?.cancel()
        isRenderingFullResolution = false
        guard let photo, let engine else {
            displayImage = nil
            isRendering = false
            return
        }
        isRendering = true
        let controls = controls
        renderTask = Task {
            do {
                try await show(controls: controls, mode: .preview, engine: engine,
                               size: "\(photo.previewWidth) × \(photo.previewHeight)")
                isRendering = false
                try await Task.sleep(for: Self.fullRenderDelay)
                isRendering = true
                isRenderingFullResolution = true
                try await show(controls: controls, mode: .full, engine: engine, size: "\(photo.width) × \(photo.height)")
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render", error)
            }
            isRendering = false
            isRenderingFullResolution = false
        }
    }

    /// Renders the photo and puts it on screen, unless a newer change has made it stale. `size`
    /// is the rendered size, for the log.
    private func show(controls: Controls, mode: RenderMode, engine: Engine, size: String) async throws {
        let start = ContinuousClock.now
        let display = try await engine.display(controls: controls, mode: mode)
        try Task.checkCancellation()
        displayImage = display
        showsFullResolution = mode == .full
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
        note("Rendered \(mode == .full ? "full resolution" : "preview") (\(size)) in \(elapsed)")
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
