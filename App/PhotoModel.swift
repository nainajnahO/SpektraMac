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

    /// The opened photo at full resolution, in the engine's working space.
    private(set) var source: RGBImage?
    /// `source` down-sized: every change re-renders it.
    private(set) var preview: RGBImage? {
        didSet { scheduleRender() }
    }
    private(set) var sourceName = ""
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
        // Files from the Open panel are security-scoped; dropped files are already accessible.
        let scoped = url.startAccessingSecurityScopedResource()
        isLoading = true
        errorMessage = nil
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let engine = engine
                let (image, preview, metadata) = try await Task.detached(priority: .userInitiated) {
                    let image = try RGBImage(contentsOf: url)
                    return (image, engine?.preview(of: image), PhotoMetadata(contentsOf: url))
                }.value
                sourceName = url.lastPathComponent
                source = image
                self.metadata = metadata
                self.preview = preview
                note("Opened \(sourceName) (\(image.width) × \(image.height))")
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

    var canRender: Bool { source != nil && engine != nil }

    /// Renders the preview again, in place of a full-resolution render on screen.
    func renderPreview() {
        render(fullResolution: false)
    }

    /// Renders the whole photo at full resolution, with the blurs and grain the preview leaves out.
    func renderFullResolution() {
        render(fullResolution: true)
    }

    /// Renders the preview once per main-actor turn, however many settings changed in it, and
    /// cancels a render that a newer change has made stale.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            renderScheduled = false
            renderPreview()
        }
    }

    private func render(fullResolution: Bool) {
        renderTask?.cancel()
        guard let image = fullResolution ? source : preview, let engine else {
            displayImage = nil
            isRendering = false
            return
        }
        isRendering = true
        isRenderingFullResolution = fullResolution
        let controls = controls
        renderTask = Task {
            let start = ContinuousClock.now
            do {
                let output = try await engine.render(image, controls: controls, mode: fullResolution ? .full : .preview)
                let display = await Task.detached(priority: .userInitiated) {
                    output.displayImage(in: Engine.outputColorSpace)
                }.value
                guard !Task.isCancelled else { return }
                displayImage = display
                showsFullResolution = fullResolution
                let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
                note("Rendered \(fullResolution ? "full resolution" : "preview") (\(image.width) × \(image.height)) in \(elapsed)")
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render", error)
            }
            isRendering = false
            isRenderingFullResolution = false
        }
    }

    // MARK: Saving and cancelling

    var canSave: Bool { canRender && savePhase == nil }
    var canCancel: Bool { isRenderingFullResolution || savePhase != nil }

    /// Renders the photo at full resolution, sRGB-encoded, and writes it where the Save panel says:
    /// 16-bit TIFF or PNG, or JPEG, by the name's extension.
    func save() {
        guard let source, let engine else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .tiff, .png]
        panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + ".jpg"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
        let (controls, metadata) = (controls, metadata)
        savePhase = "Rendering \(url.lastPathComponent) at full resolution…"
        saveTask = Task {
            defer { savePhase = nil; saveTask = nil }
            let start = ContinuousClock.now
            do {
                let output = try await engine.render(source, controls: controls, mode: .export)
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

    /// Stops a full-resolution render or a save; the GPU stops at its next memory flush.
    func cancel() {
        if let saveTask {
            saveTask.cancel()
        } else if isRenderingFullResolution {
            renderTask?.cancel()
            isRendering = false
            isRenderingFullResolution = false
            note("Cancelled the full-resolution render")
        }
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
