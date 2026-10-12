import CoreGraphics
import Foundation
import Observation
import SpektraEngine
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
    /// What the sidebar and the Film | Negative switch set; every change re-renders the preview.
    var controls = Controls() {
        didSet { scheduleRender() }
    }
    /// The film. Choosing one also picks the paper it's meant to be printed on and, as
    /// Spektrafilm's GUI does, views slides directly instead of printing them.
    var film: String {
        get { controls.film }
        set {
            controls.film = newValue
            guard let info = films.first(where: { $0.stock == newValue }) else { return }
            if let paper = info.targetPrint {
                controls.paper = paper
            }
            controls.scanFilm = info.type == .positive
        }
    }
    var films: [ProfileInfo] { engine?.films ?? [] }
    var papers: [ProfileInfo] { engine?.papers ?? [] }
    /// Display-sized rendering of the last simulation.
    private(set) var displayImage: CGImage?
    /// Whether `displayImage` comes from the full-resolution render rather than the preview.
    private(set) var showsFullResolution = false
    private(set) var isLoading = false
    private(set) var isRendering = false
    private(set) var errorMessage: String?
    private(set) var log: [LogEntry] = []
    /// Drives the Open panel (`fileImporter`); ⌘O and the toolbar set it.
    var isImporting = false

    private let engine: Engine?
    private let logger = Logger(subsystem: "nainajnahO.SpektraMac", category: "model")
    private var renderTask: Task<Void, Never>?
    private var renderScheduled = false

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
                let (image, preview) = try await Task.detached(priority: .userInitiated) {
                    let image = try RGBImage(contentsOf: url)
                    return (image, engine?.preview(of: image))
                }.value
                sourceName = url.lastPathComponent
                source = image
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
        let controls = controls
        renderTask = Task {
            let start = ContinuousClock.now
            do {
                let output = try await engine.render(image, controls: controls, preview: !fullResolution)
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
        }
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
