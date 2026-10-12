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

    /// The opened photo in the engine's working space; every change re-renders.
    private(set) var source: RGBImage? {
        didSet { scheduleRender() }
    }
    private(set) var sourceName = ""
    /// Display-sized rendering of the last simulation.
    private(set) var displayImage: CGImage?
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
                let image = try await Task.detached(priority: .userInitiated) { try RGBImage(contentsOf: url) }.value
                sourceName = url.lastPathComponent
                source = image
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

    /// Renders once per main-actor turn, however many settings changed in it, and cancels a
    /// render that a newer change has made stale.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            renderScheduled = false
            render()
        }
    }

    private func render() {
        renderTask?.cancel()
        guard let source, let engine else {
            displayImage = nil
            isRendering = false
            return
        }
        isRendering = true
        renderTask = Task {
            let start = ContinuousClock.now
            do {
                let output = try await engine.render(source)
                let image = await Task.detached(priority: .userInitiated) {
                    output.displayImage(in: RGBImage.workingColorSpace)
                }.value
                guard !Task.isCancelled else { return }
                displayImage = image
                note("Rendered in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])))")
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
