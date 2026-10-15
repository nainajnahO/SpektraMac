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
    }
    /// A new photo empties the kept renders and renders at once.
    private(set) var photo: Photo? {
        didSet {
            finishedRenders.removeAllObjects()
            scheduleRender()
        }
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
    /// The photo's long side fitted on the canvas, in screen pixels: what renders are reduced to
    /// until the canvas may show more. A new size renders a reduced render on screen again.
    var canvasLongSide = 0 {
        didSet {
            if canvasLongSide != oldValue && awaitsFullResolution {
                render(from: .reduced)
            }
        }
    }
    /// Whether the canvas may show the photo larger than it fits: the pointer is over it, or it's
    /// zoomed in. Only then does the whole photo render, if it's larger than the canvas shows it.
    var wantsFullResolution = false {
        didSet {
            if wantsFullResolution && awaitsFullResolution {
                render(from: .full)
            }
        }
    }
    /// The reduced render is on screen and the controls haven't changed since.
    private var awaitsFullResolution = false
    /// A preview is rendering: a change meanwhile waits for it to show, then renders.
    private var isPreviewing = false
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
    /// Finished renders at the canvas's size for the open photo, by the controls they show: going
    /// back to controls shown before (hovering back to a stock, a slider back at a value) shows
    /// them at once. Not full-resolution ones (96 MB at 24 MP). `NSCache` drops the oldest past
    /// 512 MB, and all of them when memory runs low.
    private let finishedRenders: NSCache<RenderKey, CGImage> = {
        let cache = NSCache<RenderKey, CGImage>()
        cache.totalCostLimit = 512 << 20
        return cache
    }()
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
                isPreviewing = false
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

    /// Where a render starts: a change to the controls at the quick preview, a new canvas size at
    /// the reduced render, ``wantsFullResolution`` at the whole photo.
    private enum RenderStart { case preview, reduced, full }

    /// Renders the preview, then, once the controls have been still for `fullRenderDelay`, with
    /// the blurs and grain the preview leaves out: at the size the canvas shows the photo, and the
    /// whole photo once ``wantsFullResolution``, or at once where the canvas shows it no smaller.
    /// A change cancels it, except a preview, which shows and then renders the newest controls.
    /// Controls with a kept finished render (``finishedRenders``) show it instead, at once.
    private func render(from start: RenderStart = .preview) {
        // A preview in flight shows, then renders the newest controls: cancelling it at each step
        // of a slider would leave none on screen until the slider pauses.
        guard start != .preview || !isPreviewing else { return }
        renderTask?.cancel()
        isPreviewing = false
        isRenderingFullResolution = false
        awaitsFullResolution = false
        guard let photo, let engine else {
            displayImage = nil
            isRendering = false
            return
        }
        isRendering = true
        isPreviewing = start == .preview
        renderTask = Task {
            var controls = self.controls
            do {
                // Whether a kept finished render is on screen.
                var isFinished = false
                if start == .preview {
                    repeat {
                        controls = self.controls
                        isFinished = showKept(controls, photo: photo)
                        if !isFinished {
                            try await show(controls: controls, mode: .preview, engine: engine, photo: photo)
                        }
                    } while controls != self.controls
                    isPreviewing = false
                }
                if start != .full && !isFinished {
                    isRendering = false
                    try await Task.sleep(for: Self.fullRenderDelay)
                    isRendering = true
                }
                // The canvas's size once things are still.
                let longSide = reducedLongSide(of: photo)
                let reduces = start != .full && longSide < max(photo.width, photo.height)
                if reduces && !isFinished {
                    try await show(controls: controls, mode: .reduced(longSide: longSide), engine: engine, photo: photo)
                }
                if reduces && !wantsFullResolution {
                    awaitsFullResolution = true
                } else {
                    isRenderingFullResolution = true
                    try await show(controls: controls, mode: .full, engine: engine, photo: photo)
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render", error)
            }
            isPreviewing = false
            isRendering = false
            isRenderingFullResolution = false
        }
    }

    /// The long side renders are reduced to: the canvas's (the preview's before it has a size).
    private func reducedLongSide(of photo: Photo) -> Int {
        canvasLongSide > 0 ? canvasLongSide : max(photo.previewWidth, photo.previewHeight)
    }

    /// Puts the kept finished render of `controls` on screen, if there is one.
    private func showKept(_ controls: Controls, photo: Photo) -> Bool {
        let longSide = reducedLongSide(of: photo)
        guard let image = finishedRenders.object(forKey: RenderKey(controls: controls, longSide: longSide)) else {
            return false
        }
        displayImage = image
        shownMode = .reduced(longSide: longSide)
        note("Showed the kept screen size (\(image.width) × \(image.height))")
        return true
    }

    /// Renders the photo and puts it on screen, unless a newer change has made it stale.
    private func show(controls: Controls, mode: RenderMode, engine: Engine, photo: Photo) async throws {
        let start = ContinuousClock.now
        let display = try await engine.display(controls: controls, mode: mode)
        try Task.checkCancellation()
        displayImage = display
        shownMode = mode
        if case .reduced(let longSide) = mode {
            finishedRenders.setObject(display, forKey: RenderKey(controls: controls, longSide: longSide),
                                      cost: display.bytesPerRow * display.height)
        }
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
        let size = mode == .full ? "\(photo.width) × \(photo.height)" : "\(display.width) × \(display.height)"
        let name = switch mode {
        case .preview: "preview"
        case .reduced: "screen size"
        case .full, .export: "full resolution"
        }
        note("Rendered \(name) (\(size)) in \(elapsed)")
    }

    /// What a kept render shows: `NSCache` wants an object key.
    private nonisolated final class RenderKey: NSObject {
        let controls: Controls
        let longSide: Int

        init(controls: Controls, longSide: Int) {
            (self.controls, self.longSide) = (controls, longSide)
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? RenderKey else { return false }
            return controls == other.controls && longSide == other.longSide
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(controls)
            hasher.combine(longSide)
            return hasher.finalize()
        }
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

    // MARK: LUTs

    var canExportLUT: Bool { engine != nil }
    /// Spektrafilm's LUT tool's default size: trilinear interpolation between its entries is
    /// within ΔE2000 0.56 of exact (Portra 400 → Portra Endura), a 1 MB file.
    private static let lutSize = 33
    /// macOS declares no type for `.cube` files, so the Save panel gets a dynamic one.
    private static let cubeType = UTType(filenameExtension: "cube", conformingTo: .text)!

    /// Writes the controls' look as a `.cube` LUT for LightCraft, which applies one to its
    /// display-encoded sRGB, exposed as the exposure slider shows (``Engine/lut(controls:exposureEV:size:)``).
    /// Its title, the name LightCraft shows, is the file's.
    func exportLUT() {
        guard let engine else { return }
        let paperName = papers.first { $0.stock == controls.paper }?.name ?? controls.paper
        let stops = exposureEV.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.cubeType]
        panel.nameFieldStringValue = controls.scanFilm ? filmName : "\(filmName) – \(paperName)"
        panel.message = "The LUT carries this exposure (\(stops) EV) and every setting a LUT can hold. Grain, halation, glare, highlight boost and the sharper edges of the couplers' Edge contrast depend on neighbouring pixels or the whole photo, so they're left out."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let (controls, exposureEV) = (controls, exposureEV)
        let comments = [
            "Made with SpektraMac from Spektrafilm by Andrea Volpato (https://github.com/andreavolpato/spektrafilm).",
            "Film and paper data: CC BY-SA 4.0.",
            controls.scanFilm ? "Film: \(filmName), scanned" : "Film: \(filmName), printed on \(paperName)",
            "Exposure: \(stops) EV",
            "Input and output: sRGB, encoded",
        ]
        Task {
            do {
                let lut = try await engine.lut(controls: controls, exposureEV: exposureEV, size: Self.lutSize)
                try lut.cube(title: url.deletingPathExtension().lastPathComponent, comments: comments)
                    .write(to: url, options: .atomic)
                note("Exported LUT \(url.lastPathComponent) at \(stops) EV")
            } catch {
                fail("Could not export the LUT", error)
            }
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

    // MARK: Adjustments

    /// The settings' groups, as Photos groups its adjustments: each resets on its own.
    enum Adjustment {
        case exposure, halation, couplers, grain, contrast, enlarger, glare
    }

    /// Whether `adjustment`'s controls are what choosing the film applies.
    func isAtDefaults(_ adjustment: Adjustment) -> Bool {
        controls == resetting(adjustment, in: controls)
    }

    /// Returns `adjustment`'s controls to what choosing the film applies.
    func reset(_ adjustment: Adjustment) {
        controls = resetting(adjustment, in: controls)
    }

    /// `controls` with `adjustment`'s from the film's saved defaults, or the app's own. Saved
    /// defaults that can't be read were reported when the film was chosen, so here they're the
    /// app's own.
    private func resetting(_ adjustment: Adjustment, in controls: Controls) -> Controls {
        let defaults = UserDefaults.standard.data(forKey: Self.defaultsKey(controls.film))
            .flatMap { try? Controls(preset: $0) } ?? Controls()
        var reset = controls
        switch adjustment {
        case .exposure:
            reset.exposureMark = defaults.exposureMark
            reset.exposureOffsetEV = defaults.exposureOffsetEV
            reset.highlightBoost = defaults.highlightBoost
        case .halation:
            reset.halation = defaults.halation
            reset.halationAmount = defaults.halationAmount
            reset.halationSize = defaults.halationSize
            reset.scatterAmount = defaults.scatterAmount
            reset.scatterSize = defaults.scatterSize
        case .couplers:
            reset.couplers = defaults.couplers
            reset.couplerSaturation = defaults.couplerSaturation
            reset.couplerEdgeContrast = defaults.couplerEdgeContrast
        case .grain:
            reset.grain = defaults.grain
            reset.grainSize = defaults.grainSize
            reset.grainSoftness = defaults.grainSoftness
        case .contrast:
            reset.printContrast = defaults.printContrast
            reset.printHighlightContrast = defaults.printHighlightContrast
            reset.printShadowContrast = defaults.printShadowContrast
        case .enlarger:
            reset.printExposure = defaults.printExposure
            reset.yFilterShift = defaults.yFilterShift
            reset.mFilterShift = defaults.mFilterShift
            reset.preflash = defaults.preflash
        case .glare:
            reset.glare = defaults.glare
            reset.glareAmount = defaults.glareAmount
            reset.glareRoughness = defaults.glareRoughness
            reset.glareSoftness = defaults.glareSoftness
        }
        return reset
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
