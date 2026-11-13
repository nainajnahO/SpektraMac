import AppKit
import CoreTransferable
import Foundation
import ImageIO
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
    /// A new photo stops the last one's render, empties the kept renders and the strips, and renders
    /// at once, showing its edit.
    private(set) var photo: Photo? {
        didSet {
            // The last photo's render may have started while the engine opened this one, and waited
            // behind it, holding that photo's size and readings. With its preview in flight, this
            // one's own render would return at once, leaving that one to make the strips (#320).
            stopRendering()
            finishedRenders.removeAllObjects()
            strips = [:]
            stripControls = nil
            original = nil
            showsOriginal = false
            scheduleRender()
        }
    }
    /// The open photo as macOS shows it, upright and at full size (``loadOriginal(of:)``): what a
    /// click on the canvas shows in place of the edit.
    private(set) var original: CGImage?
    /// The canvas shows ``original`` in place of the edit, and the settings are greyed out.
    var showsOriginal = false
    /// Temporary, for #365: the Development row's control, chosen in View › Development Control.
    var developmentControl = DevelopmentControl.segmented
    /// The photo's EXIF, GPS and IPTC records, for saved renderings.
    @ObservationIgnored private var metadata: PhotoMetadata?
    /// What the sidebar and the Print | Film switch set; every change re-renders the preview, and
    /// can be undone (``registerUndo(from:)``), a drag or a menu's choice in one step.
    var controls = Controls() {
        didSet {
            showsFilm = controls.scanFilm
            isSlideFilm = films.first { $0.stock == controls.film }?.type == .positive
            scheduleRender()
            if controlsBeforeChange == nil && controls != oldValue {
                registerUndo(from: oldValue)
            }
        }
    }
    /// What the toolbar's Print | Film switch shows, as the controls have it: apart from them, so
    /// the switch isn't laid out again at every step of a slider (setting an observed property to
    /// the value it has notifies no one).
    private(set) var showsFilm = false
    /// A slide is viewed, never printed: every paper is negative-working, so a printed slide
    /// comes out as a negative image.
    private(set) var isSlideFilm = false
    /// The film. Choosing one applies the defaults made for it, if any; otherwise it picks the
    /// paper the film is meant to be printed on and, as Spektrafilm's GUI does, views slides
    /// directly instead of printing them, keeping the other controls.
    var film: String {
        get { controls.film }
        set { controls = controls(choosing: newValue) }
    }
    /// What choosing `film` sets the controls to (``film``), at the same exposure: the photo's.
    func controls(choosing film: String) -> Controls {
        var chosen = savedDefaults(for: film) ?? controls.choosing(film: film, from: films)
        chosen.exposureEV = controls.exposureEV
        return chosen
    }
    var filmName: String { films.first { $0.stock == controls.film }?.name ?? controls.film }
    var paperName: String { papers.first { $0.stock == controls.paper }?.name ?? controls.paper }
    var films: [ProfileInfo] { engine?.films ?? [] }
    var papers: [ProfileInfo] { engine?.papers ?? [] }
    /// A black-and-white stock has one layer, so settings between or across a colour stock's
    /// three have nothing to set: the couplers' saturation on such a film, and on such a paper
    /// the tone graph's curve per colour, and the filters that balance a print's colour if the
    /// film is one too.
    var isBlackAndWhiteFilm: Bool { films.first { $0.stock == controls.film }?.channelModel == .blackAndWhite }
    var isBlackAndWhitePaper: Bool { papers.first { $0.stock == controls.paper }?.channelModel == .blackAndWhite }
    /// The times a stock can be developed for, if it has a choice of them, with its standard one
    /// and the one `minutes` asks for (``Engine/developmentTimes(of:asking:)``).
    func developmentTimes(of stock: String, asking minutes: Double?) -> (measured: [Double], standard: Double, developed: Double)? {
        engine?.developmentTimes(of: stock, asking: minutes)
    }
    /// The exposure's range (``Controls/exposureRange(readings:)``).
    var exposureRange: ClosedRange<Double> {
        Controls.exposureRange(readings: photo?.metering)
    }
    /// While the Exposure strip is held: the trackpad then clicks as it passes a mark's dot.
    var isAdjustingExposure = false
    /// The marks of the dot under the pointer, under the Exposure strip: the canvas then tints the
    /// regions they meter.
    var hoveredMarks: [MeteringMark] = []
    /// While a Burn slider is held: the canvas then shows what burns (``burnMask``).
    var isAdjustingBurn = false {
        didSet {
            guard isAdjustingBurn != oldValue else { return }
            if isAdjustingBurn {
                updateBurnMask()
            } else {
                burnMask = nil
            }
        }
    }
    /// Where the burn falls on the preview while a Burn slider is held (``Engine/burnMask(controls:)``).
    private(set) var burnMask: CGImage?
    /// While a slider is held: its next step would cancel the blurs and grain, so they render
    /// once it's let go.
    var isAdjusting = false {
        didSet {
            guard isAdjusting != oldValue else { return }
            if isAdjusting {
                beginChange()
            } else {
                endChange()
                if let start = awaitsRelease {
                    render(from: start)
                }
            }
        }
    }
    /// The preview or a kept render is on screen, and the blurs and grain wait for the slider to be
    /// let go: where the render carries on from then.
    private var awaitsRelease: RenderStart?
    /// Display-sized rendering of the last simulation.
    private(set) var displayImage: CGImage?
    /// The Print tab's tone graph and the controls it was made for, with each preview.
    private(set) var toneGraph: (graph: ToneGraph, controls: Controls)?
    /// The render `displayImage` comes from.
    private(set) var shownMode: RenderMode?
    /// The photo's long side fitted on the canvas, in screen pixels: what renders are reduced to
    /// until the canvas may show more. A new size renders a reduced render on screen again, or one
    /// still rendering at the old size.
    var canvasLongSide = 0 {
        didSet {
            let rendersReduced = isRendering && !isRenderingFullResolution
            if canvasLongSide != oldValue && (awaitsFullResolution || rendersReduced) {
                render(from: .resized)
            }
        }
    }
    /// Whether the canvas shows the photo larger than it fits: it's zoomed in. Only then does the
    /// whole photo render, if it's larger than the canvas shows it. Until it's on screen, the
    /// zoomed photo is the screen-size render enlarged: about 0.3 s at 12 MP, 0.5–0.9 s at 24 MP
    /// on an M1 Pro.
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
    /// A render with the blurs and grain is running. Not a preview: at each step of a slider,
    /// "Rendering…" would flicker under the window's title, laying out the toolbar each time.
    private(set) var isRendering = false
    private(set) var isRenderingFullResolution = false
    /// What saving is doing, while it runs.
    private(set) var savePhase: String?
    private(set) var errorMessage: String?
    /// Something the user asked for that failed (opening, saving, exporting, presets), for the
    /// window's alert, until it's dismissed.
    struct Failure {
        let title: String
        let message: String
    }
    var failure: Failure?
    /// Why there's no engine: Metal is unavailable. The empty canvas says so.
    private(set) var engineFailure: String?
    private(set) var log: [LogEntry] = []
    /// Drives the Open panel (`fileImporter`); ⌘O and the toolbar set it.
    var isImporting = false
    /// Drives the Open Preset panel (`fileImporter`); its menu item sets it.
    var isImportingPreset = false

    /// Made in the background as the app starts, so the window shows at once: about 0.1 s,
    /// 0.5 s on the first launch after a build, as Metal compiles the shaders. The Film and Paper
    /// menus fill, and photos open, once it's here.
    private var engine: Engine?
    /// The GPU time of the engine's own work so far, in seconds, for the Log's graph.
    var gpuSeconds: Double { engine?.gpuTime.seconds ?? 0 }
    /// The engine being made, which opening a photo waits for: one dropped as the app starts opens
    /// once it's here.
    private let makingEngine: Task<Engine, any Error>
    private let logger = Logger(subsystem: "nainajnahO.SpektraMac", category: "model")
    private var renderTask: Task<Void, Never>?
    /// Finished renders at the canvas's size for the open photo, by the controls they show: going
    /// back to controls shown before (hovering back to a stock, a slider back at a value) shows
    /// them at once, as do the choices a menu renders ahead (``preload(_:)``). Not
    /// full-resolution ones (96 MB at 24 MP). `NSCache` drops the oldest past
    /// 512 MB, and all of them when memory runs low.
    private let finishedRenders: NSCache<RenderKey, CGImage> = {
        let cache = NSCache<RenderKey, CGImage>()
        cache.totalCostLimit = 512 << 20
        return cache
    }()
    private var renderScheduled = false
    private var saveTask: Task<Void, Never>?
    /// Where the settings the app quit with and each film's saved defaults are kept: the app's own
    /// defaults, or a suite of the tests' own.
    private let defaults: UserDefaults
    /// Whether an opened photo goes to ``recentPhotos``: the tests' photos don't.
    private let addsToRecentPhotos: Bool

    init(defaults: UserDefaults = .standard, addsToRecentPhotos: Bool = true) {
        self.defaults = defaults
        self.addsToRecentPhotos = addsToRecentPhotos
        let making = Task.detached(priority: .userInitiated) { try Engine() }
        makingEngine = making
        Task {
            do {
                engine = try await making.value
            } catch {
                engineFailure = error.localizedDescription
                note("⚠️ Metal is unavailable: \(error.localizedDescription)")
                return
            }
            // The settings the app quit with, else the starting film's saved defaults, as choosing it
            // applies them: the reset buttons go back to them. Once the films are here, to check them
            // against, and so the Print | Film switch knows a slide.
            if let start = lastSettings() ?? savedDefaults(for: controls.film) {
                // Where the app starts, not an edit to undo.
                undoManager?.disableUndoRegistration()
                controls = start
                undoManager?.enableUndoRegistration()
            }
            // On the engine's queue, so the first photo opened doesn't wait for it.
            do {
                try await engine?.loadVision()
            } catch {
                fail("Could not load Vision", error)
            }
        }
    }

    // MARK: Opening

    /// How many opens have started: the newest one's photo is the one that shows (``open(_:)``).
    @ObservationIgnored private var opensStarted = 0
    /// The photos opened lately, newest first, for File › Open Recent: AppKit's list of recent
    /// documents, which keeps them between launches, with access to them, and fills the Dock
    /// icon's menu.
    private(set) var recentPhotos = NSDocumentController.shared.recentDocumentURLs

    func clearRecentPhotos() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentPhotos = []
    }

    /// Opens the photo at `url`. Photos chosen while others open show in the order chosen: an
    /// earlier one still decoding is dropped (a 16-bit TIFF can take seconds, a JPEG chosen after it
    /// a moment), and one the engine is already opening shows until the later one replaces it.
    /// "Opening…" stays until the newest is done. An opened photo goes to the top of
    /// ``recentPhotos``.
    func open(_ url: URL) {
        // Files from the Open panel and Open Recent are security-scoped; dropped files and those
        // sent by Finder or the Dock are already accessible.
        let scoped = url.startAccessingSecurityScopedResource()
        opensStarted += 1
        let generation = opensStarted
        isLoading = true
        errorMessage = nil
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            defer {
                if generation == opensStarted {
                    isLoading = false
                }
            }
            do {
                let engine = try await makingEngine.value
                let (image, metadata) = try await Task.detached(priority: .userInitiated) {
                    (try RGBImage.decode(contentsOf: url), PhotoMetadata(contentsOf: url))
                }.value
                guard generation == opensStarted else { return }
                // The engine opens the photo once it's done rendering the last one: stop that.
                stopRendering()
                stripTask?.cancel()
                stripTask = nil
                stopPreloading()
                let opened: Engine.OpenedPhoto
                do {
                    opened = try await engine.open(image)
                } catch {
                    // The engine keeps the open photo: its renders, stopped above, start again.
                    scheduleRender()
                    throw error
                }
                self.metadata = metadata
                // Every photo opens as shot, with nothing to undo: the last photo's changes were its
                // own, and Undo would bring its exposure back with them.
                undoManager?.removeAllActions()
                undoManager?.disableUndoRegistration()
                controls.exposureEV = 0
                undoManager?.enableUndoRegistration()
                photo = Photo(name: url.lastPathComponent, width: opened.width, height: opened.height,
                              previewWidth: opened.previewWidth, previewHeight: opened.previewHeight,
                              metering: opened.metering, meteringOverlays: opened.meteringOverlays)
                note("Opened \(url.lastPathComponent) (\(opened.width) × \(opened.height))")
                if addsToRecentPhotos {
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    recentPhotos = NSDocumentController.shared.recentDocumentURLs
                }
                loadOriginal(of: url)
            } catch {
                // A photo chosen since says how it went instead.
                guard generation == opensStarted else { return }
                fail("Couldn't open “\(url.lastPathComponent)”", error, alert: true)
            }
        }
    }

    /// Reads `url` into ``original`` for the photo just opened, unless another opens meanwhile:
    /// after the photo shows, so it opens no later for it (0.05–0.45 s for 12–24 MP JPEG, HEIC and
    /// DNG files on an M1 Pro).
    private func loadOriginal(of url: URL) {
        let id = photo?.id
        // Files from the Open panel are security-scoped, and the opening task stops its access.
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let image = try await Task.detached(priority: .utility) { try Self.decodeOriginal(contentsOf: url) }.value
                if photo?.id == id {
                    original = image
                }
            } catch {
                fail("Could not read the original of \(url.lastPathComponent)", error)
            }
        }
    }

    /// `url` as macOS shows it, upright and at full size: ImageIO's decoding, as Preview's, so a
    /// RAW file has its default look rather than the engine's linear development.
    nonisolated private static func decodeOriginal(contentsOf url: URL) throws -> CGImage {
        // A thumbnail made from the image with no size limit: ImageIO's way to have it upright.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        return image
    }

    func importFailed(_ error: Error) {
        fail("Couldn't open the file", error, alert: true)
    }

    // MARK: Rendering

    /// How long the canvas's size stays still before the photo renders at it: a window being
    /// resized changes it at every frame.
    private static let resizeDelay = Duration.milliseconds(500)

    /// Renders once per main-actor turn, however many settings changed in it.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            renderScheduled = false
            render()
        }
    }

    /// Where a render starts: a change to the controls at the quick preview; a slider let go at the
    /// reduced render, or past it if it let go over a kept one (`kept`); a new canvas size at the
    /// reduced render once it has been still for `resizeDelay`; ``wantsFullResolution`` at the
    /// whole photo.
    private enum RenderStart { case preview, reduced, kept, resized, full }

    /// Renders the preview, then with the blurs and grain the preview leaves out, once the slider
    /// is let go if one is held (``isAdjusting``): at the size the canvas shows the photo, and the
    /// whole photo once ``wantsFullResolution``, or at once where the canvas shows it no smaller.
    /// A change cancels it, except a preview, which shows and then renders the newest controls.
    /// Controls with a kept finished render (``finishedRenders``) show it instead, at once.
    private func render(from start: RenderStart = .preview) {
        // A preview in flight shows, then renders the newest controls: cancelling it at each step
        // of a slider would leave none on screen until the slider pauses.
        guard start != .preview || !isPreviewing else { return }
        stopRendering()
        if start == .preview {
            stripTask?.cancel()
            stripTask = nil
        }
        guard let photo, let engine else {
            displayImage = nil
            return
        }
        isRendering = start == .reduced || start == .full
        isPreviewing = start == .preview
        renderTask = Task {
            var controls = self.controls
            do {
                // Whether a kept finished render is on screen.
                var isFinished = start == .kept
                if start == .preview {
                    repeat {
                        controls = self.controls
                        isFinished = showKept(controls, photo: photo)
                        if !isFinished {
                            try await show(controls: controls, mode: .preview, engine: engine, photo: photo)
                        }
                        // With each preview, so the graph follows a slider or its own handles as
                        // they move.
                        toneGraph = (try await engine.toneGraph(controls: controls), controls)
                    } while controls != self.controls
                    isPreviewing = false
                    // A kept render too: what follows it (the whole photo zoomed in, 0.5–0.9 s at
                    // 24 MP, or the strips) would hold up the slider's next preview.
                    if isAdjusting {
                        awaitsRelease = isFinished ? .kept : .reduced
                        return
                    }
                }
                if start == .resized {
                    try await Task.sleep(for: Self.resizeDelay)
                }
                // The canvas's size once things are still.
                let longSide = reducedLongSide(of: photo)
                let reduces = start != .full && longSide < max(photo.width, photo.height)
                if reduces && !isFinished {
                    isRendering = true
                    try await show(controls: controls, mode: .reduced(longSide: longSide), engine: engine, photo: photo)
                }
                if reduces && !wantsFullResolution {
                    awaitsFullResolution = true
                } else {
                    isRendering = true
                    isRenderingFullResolution = true
                    try await show(controls: controls, mode: .full, engine: engine, photo: photo)
                }
                renderStrips(engine: engine)
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render", error)
            }
            isPreviewing = false
            isRendering = false
            isRenderingFullResolution = false
        }
    }

    /// Stops the render under way, and what waits on one: a slider's release, or zooming in for the
    /// whole photo.
    private func stopRendering() {
        renderTask?.cancel()
        isPreviewing = false
        isRendering = false
        isRenderingFullResolution = false
        awaitsFullResolution = false
        awaitsRelease = nil
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
        let (display, time) = try await EngineTime.measure(on: engine) { try $0.display(controls: controls, mode: mode) }
        try Task.checkCancellation()
        displayImage = display
        shownMode = mode
        if mode == .preview && isAdjustingBurn {
            burnMask = try await engine.burnMask(controls: controls)
        }
        if case .reduced(let longSide) = mode {
            finishedRenders.setObject(display, forKey: RenderKey(controls: controls, longSide: longSide),
                                      cost: display.bytesPerRow * display.height)
        }
        let size = mode == .full ? "\(photo.width) × \(photo.height)" : "\(display.width) × \(display.height)"
        let name = switch mode {
        case .preview: "preview"
        case .thumbnail: "thumbnail"
        case .reduced: "screen size"
        case .full, .export: "full resolution"
        }
        note("Rendered \(name) (\(size)) \(time.formatted())")
    }

    /// Shows what burns as a Burn slider is taken hold of, before it moves (the previews it renders
    /// then show it from ``show(controls:mode:engine:photo:)``).
    private func updateBurnMask() {
        guard let engine, photo != nil else { return }
        let controls = controls
        Task {
            do {
                let mask = try await engine.burnMask(controls: controls)
                if isAdjustingBurn {
                    burnMask = mask
                }
            } catch {
                fail("Could not show what burns", error)
            }
        }
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

    // MARK: Thumbnail strips

    /// Each strip (``Controls/Strip``) has this many frames, rendered in preview mode on a small
    /// image of the photo (``RenderMode/thumbnail``). Halation, grain and glare barely show at that
    /// size, so they have none.
    static let framesPerStrip = 5
    /// Each strip's frames, left to right. A strip whose control changes nothing the controls show
    /// (a print setting while the film shows, say) has none.
    private(set) var strips: [Controls.Strip: [CGImage]] = [:]
    /// The controls the strips were made for.
    @ObservationIgnored private var stripControls: Controls?
    /// Makes the strips for the controls; a change to them stops it (``render(from:)``).
    @ObservationIgnored private var stripTask: Task<Void, Never>?

    /// The range a strip's control spans.
    func range(of strip: Controls.Strip) -> ClosedRange<Double> {
        switch strip {
        case .exposure: exposureRange
        case .couplerSaturation: Controls.range(\.couplerSaturation)
        case .printExposure: Controls.range(\.printExposure)
        }
    }

    /// Renders the strips for the controls, unless they show them or are being made for them. Each
    /// frame is a render of its own, so a change's preview waits on one frame at most; each strip
    /// shows once all its frames are done.
    private func renderStrips(engine: Engine) {
        let controls = controls
        guard controls != stripControls, stripTask == nil else { return }
        stripTask = Task {
            // The frames' own times and waits, added up: between frames, a change's preview may go first.
            var time = EngineTime()
            var count = 0
            do {
                for strip in Controls.Strip.allCases {
                    guard strip.applies(to: controls, films: films) else {
                        strips[strip] = nil
                        continue
                    }
                    let span = range(of: strip)
                    var frames: [CGImage] = []
                    for frame in 0..<Self.framesPerStrip {
                        // The value at the middle of the frame.
                        let value = span.lowerBound
                            + (Double(frame) + 0.5) / Double(Self.framesPerStrip) * (span.upperBound - span.lowerBound)
                        let frameControls = controls.setting(strip, to: value)
                        let (image, frameTime) = try await EngineTime.measure(on: engine) {
                            try $0.display(controls: frameControls, mode: .thumbnail)
                        }
                        frames.append(image)
                        time += frameTime
                        try Task.checkCancellation()
                    }
                    strips[strip] = frames
                    count += frames.count
                }
                stripControls = controls
                stripTask = nil
                note("Rendered \(count) thumbnails \(time.formatted())")
            } catch {
                guard !Task.isCancelled else { return }
                stripTask = nil
                fail("Could not render the thumbnails", error)
            }
        }
    }

    // MARK: Choices rendered ahead

    /// Renders what a menu offers, while it's open (``preload(_:)``).
    @ObservationIgnored private var preloadTask: Task<Void, Never>?

    /// Renders each of `choices` (what choosing each stock or filter of a menu sets the controls
    /// to, in order) with every effect at the canvas's size into the kept renders, so the menu
    /// shows a choice finished the moment the pointer is on it (``showKept(_:photo:)``). One render
    /// at a time, as the strips are made: a choice the pointer reaches before its turn waits on one
    /// render at most. As many as fill half the kept renders' memory, so they can't push each
    /// other out.
    func preload(_ choices: [Controls]) {
        stopPreloading()
        guard let photo, let engine else { return }
        let longSide = reducedLongSide(of: photo)
        let scale = min(1, Double(longSide) / Double(max(photo.width, photo.height)))
        // At least 1 px a side, as renders are: a canvas narrowed to a sliver fits a panorama 0 px tall.
        let bytes = max(1, Int(Double(photo.width) * scale)) * max(1, Int(Double(photo.height) * scale)) * 4
        let keys = choices.prefix(finishedRenders.totalCostLimit / 2 / bytes)
            .map { RenderKey(controls: $0, longSide: longSide) }
        preloadTask = Task {
            // The choices' own times and waits, added up: between choices, a preview may go first.
            var time = EngineTime()
            var count = 0
            do {
                for key in keys where finishedRenders.object(forKey: key) == nil {
                    let controls = key.controls
                    let (display, choiceTime) = try await EngineTime.measure(on: engine) {
                        try $0.display(controls: controls, mode: .reduced(longSide: longSide))
                    }
                    try Task.checkCancellation()
                    finishedRenders.setObject(display, forKey: key, cost: display.bytesPerRow * display.height)
                    time += choiceTime
                    count += 1
                }
                if count > 0 {
                    note("Rendered \(count) choices ahead \(time.formatted())")
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render the choices ahead", error)
            }
        }
    }

    /// Stops ``preload(_:)``; what it has rendered stays kept.
    func stopPreloading() {
        preloadTask?.cancel()
        preloadTask = nil
    }

    // MARK: Saving and cancelling

    var canSave: Bool { photo != nil && engine != nil && savePhase == nil }
    var canCancel: Bool { savePhase != nil }

    /// Shows `panel` as a sheet on the key window (the photo's, unless the Log is in front), or on
    /// its own if no window is, and gives the place chosen.
    private func destination(from panel: NSSavePanel) async -> URL? {
        let response = if let window = NSApp.keyWindow {
            await panel.beginSheetModal(for: window)
        } else {
            await panel.begin()
        }
        return response == .OK ? panel.url : nil
    }

    /// Renders the photo at full resolution, encoded in Display P3, and writes it where the Save panel says:
    /// 16-bit TIFF or PNG, or JPEG, as its format menu sets the name's extension. The suggested name
    /// has the film in it, so saving can't replace a JPEG original by accident.
    ///
    /// An `NSSavePanel`, not SwiftUI's `fileExporter` as Save Preset and Export LUT use: the exporter
    /// renders as its panel closes, as a `Transferable`'s export, and an export that throws stops the
    /// app. ⌘. cancels the render by throwing, and SwiftUI then raises an exception in
    /// `-[NSFileWrapper setPreferredFilename:]` (from `FileExportOperation.makeFirstFile`), which
    /// aborts the app (macOS 27.2, #291).
    func save() {
        guard let photo, let engine else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .tiff, .png]
        panel.showsContentTypes = true
        panel.nameFieldStringValue = "\((photo.name as NSString).deletingPathExtension) – \(filmName).jpg"
        panel.canCreateDirectories = true
        Task {
            guard let url = await destination(from: panel) else { return }
            let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
            let (controls, metadata, record) = (controls, metadata, editRecord)
            savePhase = "Rendering \(url.lastPathComponent) at full resolution…"
            saveTask = Task {
                defer { savePhase = nil; saveTask = nil }
                do {
                    let (image, rendering) = try await EngineTime.measure(on: engine) {
                        try $0.export(controls: controls, as: type)
                    }
                    try Task.checkCancellation()
                    savePhase = "Writing \(url.lastPathComponent)…"
                    let writing = ContinuousClock.now
                    try await Task.detached(priority: .userInitiated) {
                        try image.write(to: url, as: type, metadata: metadata, record: record)
                    }.value
                    let time = EngineTime(waited: rendering.waited, took: rendering.took + (.now - writing))
                    note("Saved \(url.lastPathComponent) \(time.formatted([.seconds, .milliseconds]))")
                } catch is CancellationError {
                    note("Cancelled saving \(url.lastPathComponent)")
                } catch {
                    fail("Couldn't save “\(url.lastPathComponent)”", error, alert: true)
                }
            }
        }
    }

    /// Stops a save; the GPU stops at its next memory flush.
    func cancel() {
        saveTask?.cancel()
    }

    /// The finished photo, for Share and Copy, while a photo is open.
    var finishedPhoto: FinishedPhoto? {
        photo.map { FinishedPhoto(model: self, name: ($0.name as NSString).deletingPathExtension) }
    }

    /// The finished photo as a JPEG named `name`, as Save writes one, in a folder of its own in the
    /// temporary folder: what Share and Copy send (``FinishedPhoto``).
    func finishedFile(named name: String) async throws -> URL {
        let engine = try await makingEngine.value
        let (controls, metadata, record) = (controls, metadata, editRecord)
        let (image, rendering) = try await EngineTime.measure(on: engine) { try $0.export(controls: controls, as: .jpeg) }
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "\(name).jpg")
        let writing = ContinuousClock.now
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.write(to: url, as: .jpeg, metadata: metadata, record: record)
        }.value
        let time = EngineTime(waited: rendering.waited, took: rendering.took + (.now - writing))
        note("Rendered \(url.lastPathComponent) to share \(time.formatted([.seconds, .milliseconds]))")
        return url
    }

    /// What a saved photo records of its edit: the film and paper (or the film, scanned), the
    /// exposure as the slider shows it and the adjustments switched on, by their sidebar names.
    var editRecord: EditRecord {
        func diffusion(_ filter: Parameters.DiffusionFilter.Family, _ strength: Double, on lens: String) -> String {
            "\(filter.name) \(strength.formatted(.number.precision(.fractionLength(0...3)))) on the \(lens)"
        }
        var summary = [controls.scanFilm ? "\(filmName), scanned" : "\(filmName) printed on \(paperName)",
                       "\(exposureText) EV"]
        if controls.cameraDiffusion.active {
            summary.append(diffusion(controls.cameraDiffusion.filterFamily, controls.cameraDiffusion.strength, on: "lens"))
        }
        if controls.halation { summary.append("halation") }
        if controls.couplers { summary.append("couplers") }
        if controls.grain { summary.append("grain") }
        if !controls.scanFilm {
            if controls.burn { summary.append("burn") }
            if controls.enlargerDiffusion.active {
                summary.append(diffusion(controls.enlargerDiffusion.filterFamily, controls.enlargerDiffusion.strength,
                                         on: "enlarger"))
            }
            if controls.glare { summary.append("glare") }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return EditRecord(software: "SpektraMac \(version)", summary: summary.joined(separator: " · "),
                          keywords: (controls.scanFilm ? [filmName] : [filmName, paperName]) + ["SpektraMac"],
                          controls: controls)
    }

    /// The exposure as the slider shows it, signed, to a tenth of a stop.
    private var exposureText: String {
        controls.exposureEV.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
    }

    // MARK: LUTs

    var canExportLUT: Bool { engine != nil }
    /// Spektrafilm's LUT tool's default size: trilinear interpolation between its entries is
    /// within ΔE2000 0.56 of exact (Portra 400 → Portra Endura), a 1 MB file.
    private static let lutSize = 33
    /// macOS declares no type for `.cube` files, so the Export LUT panel gets a dynamic one.
    nonisolated static let cubeType = UTType(filenameExtension: "cube", conformingTo: .text)!

    /// Drives the Export LUT panel (`fileExporter`); ``exportLUT()`` sets it.
    var isExportingLUT = false
    /// What the Export LUT panel writes, made before it opens: an export that throws as a
    /// `fileExporter`'s panel closes stops the app (``save()``).
    private(set) var lutFile: LUTFile?
    /// What the Export LUT panel suggests, and the LUT's title if the file keeps it.
    var lutName: String { controls.scanFilm ? filmName : "\(filmName) – \(paperName)" }
    /// What the Export LUT panel says above its name field.
    var lutMessage: String {
        "The LUT carries this exposure (\(exposureText) EV) and every setting a LUT can hold. Grain, halation, glare, the burn, highlight boost and the sharper edges of the couplers' Edge contrast depend on neighbouring pixels or the whole photo, so they're left out."
    }

    /// Renders the controls' look as a `.cube` LUT for LightCraft, which applies one to its
    /// display-encoded sRGB, exposed as the exposure slider shows (``Engine/lut(controls:size:)``),
    /// titled ``lutName``, then opens the Export LUT panel to write it.
    func exportLUT() {
        guard let engine else { return }
        let (controls, stops, title) = (controls, exposureText, lutName)
        let comments = [
            "Made with SpektraMac from Spektrafilm by Andrea Volpato (https://github.com/andreavolpato/spektrafilm).",
            "Film and paper data: CC BY-SA 4.0.",
            controls.scanFilm ? "Film: \(filmName), scanned" : "Film: \(filmName), printed on \(paperName)",
            "Exposure: \(stops) EV",
            "Input and output: sRGB, encoded",
        ]
        Task {
            do {
                let lut = try await engine.lut(controls: controls, size: Self.lutSize)
                lutFile = LUTFile(lut: lut, title: title, comments: comments, stops: stops)
                isExportingLUT = true
            } catch {
                fail("Couldn't export the LUT", error, alert: true)
            }
        }
    }

    /// What the Export LUT panel says once it's done. The LUT's title, the name LightCraft shows, is
    /// the file's: the export can't know a name typed in the panel, so a file named otherwise is
    /// written again with its own.
    func lutExported(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            guard let exported = lutFile else { return }
            let title = url.deletingPathExtension().lastPathComponent
            if title != exported.title {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try exported.lut.cube(title: title, comments: exported.comments).write(to: url, options: .atomic)
            }
            note("Exported LUT \(url.lastPathComponent) at \(exported.stops) EV")
        } catch {
            fail("Couldn't export the LUT", error, alert: true)
        }
    }

    // MARK: Presets

    var canUsePresets: Bool { engine != nil }
    /// Drives the Save Preset panel (`fileExporter`); ``savePreset()`` sets it.
    var isSavingPreset = false
    /// What the Save Preset panel writes, made before it opens, as for Export LUT (``lutFile``).
    private(set) var presetFile: PresetFile?

    func savePreset() {
        do {
            presetFile = PresetFile(json: try controls.preset())
            isSavingPreset = true
        } catch {
            fail("Couldn't save the preset", error, alert: true)
        }
    }

    /// What the Save Preset panel says once it's done.
    func presetSaved(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url): note("Saved preset \(url.lastPathComponent)")
        case .failure(let error): fail("Couldn't save the preset", error, alert: true)
        }
    }

    func openPreset(_ url: URL) {
        // Files from the Open panel are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let preset = try Controls(preset: Data(contentsOf: url))
            guard knowsStocks(of: preset) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown film or paper (\(preset.film), \(preset.paper))",
                ])
            }
            actionName = "Open Preset"
            var opened = checked(preset, from: url.lastPathComponent)
            // A preset carries no exposure (``Controls/preset()``): it stays the photo's.
            opened.exposureEV = controls.exposureEV
            controls = opened
            actionName = nil
            note("Opened preset \(url.lastPathComponent)")
        } catch {
            fail("Couldn't open the preset", error, alert: true)
        }
    }

    /// Whether `controls`' film and paper are among those the app has.
    private func knowsStocks(of controls: Controls) -> Bool {
        films.contains { $0.stock == controls.film } && papers.contains { $0.stock == controls.paper }
    }

    private static let lastSettingsKey = "lastSettings"

    /// Keeps the controls for the next launch, which starts with them (``lastSettings()``): the app
    /// calls it as it quits.
    func storeSettings() {
        do {
            try defaults.set(controls.preset(), forKey: Self.lastSettingsKey)
        } catch {
            logger.error("Could not keep the settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The settings the app last quit with, checked as a preset is; none if their film or paper is
    /// gone.
    private func lastSettings() -> Controls? {
        guard let preset = defaults.data(forKey: Self.lastSettingsKey) else { return nil }
        do {
            let settings = try Controls(preset: preset)
            return knowsStocks(of: settings) ? checked(settings, from: "the last settings") : nil
        } catch {
            fail("Ignored the last settings", error)
            return nil
        }
    }

    /// Makes the current controls what choosing this film applies from now on.
    func makeDefaultForFilm() {
        do {
            try defaults.set(controls.preset(), forKey: Self.defaultsKey(controls.film))
            note("Made these settings the default for \(filmName)")
        } catch {
            fail("Couldn't make these settings the default for \(filmName)", error, alert: true)
        }
    }

    /// Forgets the film's saved defaults and returns every control to the app's own.
    /// Undo brings the saved defaults back with the controls.
    func restoreFactoryDefaults() {
        setSavedDefaults(nil, for: controls.film)
        actionName = "Restore Factory Defaults"
        controls = Controls().choosing(film: controls.film, from: films)
        actionName = nil
        // The defaults' undo, in the same step, has the name even if the controls were already these.
        undoManager?.setActionName("Restore Factory Defaults")
        note("Restored the factory defaults for \(filmName)")
    }

    /// Stores `preset` as `film`'s saved defaults, or forgets them for nil; Undo puts back what was.
    private func setSavedDefaults(_ preset: Data?, for film: String) {
        let key = Self.defaultsKey(film)
        let previous = defaults.data(forKey: key)
        defaults.set(preset, forKey: key)
        undoManager?.registerUndo(withTarget: self) { model in
            model.setSavedDefaults(previous, for: film)
        }
    }

    private static func defaultsKey(_ film: String) -> String { "filmDefaults.\(film)" }

    private func savedDefaults(for film: String) -> Controls? {
        guard let preset = defaults.data(forKey: Self.defaultsKey(film)) else { return nil }
        do {
            return checked(try Controls(preset: preset), from: "the saved defaults for \(film)")
        } catch {
            fail("Ignored the saved defaults for \(film)", error)
            return nil
        }
    }

    /// `controls` read from a preset (or a film's saved defaults) made what the app can render
    /// (``Controls/checked(films:)``). Says in the log what it changed, if `source` names the preset.
    private func checked(_ controls: Controls, from source: String? = nil) -> Controls {
        let (checked, changed) = controls.checked(films: films)
        if let source, !changed.isEmpty {
            note("Changed \(changed.formatted(.list(type: .and))) from \(source) to what SpektraMac can render")
        }
        return checked
    }

    // MARK: Undo

    /// The window's undo manager, which Edit › Undo and Redo use (``ContentView`` sets it). Undo goes
    /// back through the settings whichever photo is open, as they carry over from one to the next.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The controls as a drag or an open menu found them: what they change undoes in one step once
    /// it ends (``endChange()``).
    @ObservationIgnored private var controlsBeforeChange: Controls?
    /// The next undo step's name, for a change named by what made it rather than what it changed.
    @ObservationIgnored private var actionName: String?

    /// Holds the changes to the controls a drag or an open menu makes, to undo in one step.
    func beginChange() {
        if controlsBeforeChange == nil {
            controlsBeforeChange = controls
        }
    }

    /// Ends what ``beginChange()`` began: if the controls changed, one undo step sets them back.
    func endChange() {
        guard let before = controlsBeforeChange else { return }
        controlsBeforeChange = nil
        if controls != before {
            registerUndo(from: before)
        }
    }

    /// Lets Undo set the controls back to `previous`, named after the settings group the change was
    /// in unless ``actionName`` names it. Undoing sets the controls, which registers Redo, as named.
    private func registerUndo(from previous: Controls) {
        guard let undoManager else { return }
        let name = actionName ?? Controls.groupName(changedFrom: previous, to: controls)
        undoManager.registerUndo(withTarget: self) { model in
            model.actionName = name
            model.controls = previous
            model.actionName = nil
        }
        undoManager.setActionName(name)
    }

    // MARK: Adjustments

    /// Whether `adjustment`'s controls are what choosing the film applies.
    func isAtDefaults(_ adjustment: Controls.Adjustment) -> Bool {
        controls == controls.resetting(adjustment, to: resetDefaults(for: controls.film))
    }

    /// Returns `adjustment`'s controls to what choosing the film applies.
    func reset(_ adjustment: Controls.Adjustment) {
        controls = controls.resetting(adjustment, to: resetDefaults(for: controls.film))
    }

    /// What a Reset button returns its controls to: the film's saved defaults, or the app's own.
    /// Saved defaults that can't be read were reported when the film was chosen, so here they're
    /// the app's own.
    private func resetDefaults(for film: String) -> Controls {
        defaults.data(forKey: Self.defaultsKey(film))
            .flatMap { try? Controls(preset: $0) }.map { checked($0) } ?? Controls()
    }

    // MARK: Helpers

    /// The most entries ``log`` keeps: each step of a slider adds one, and the Log window lays them
    /// all out at each. Console keeps every message (``logger``).
    private static let logLimit = 1000

    private func note(_ message: String) {
        log.append(LogEntry(message: message))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
        logger.notice("\(message, privacy: .public)")
    }

    /// Shows `error` under the window's title and logs it; for something the user asked for, also
    /// in an alert (`alert`), titled with `context`.
    private func fail(_ context: String, _ error: Error, alert: Bool = false) {
        errorMessage = "\(context): \(error.localizedDescription)"
        note("⚠️ \(errorMessage ?? context)")
        if alert {
            failure = Failure(title: "\(context).", message: error.localizedDescription)
        }
    }
}

/// A LUT as Export LUT writes it, titled `title` (``PhotoModel/exportLUT()``).
nonisolated struct LUTFile: Transferable {
    let lut: LUT
    let title: String
    let comments: [String]
    /// The exposure it carries, as the slider shows it, for the Log.
    let stops: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: PhotoModel.cubeType) { $0.lut.cube(title: $0.title, comments: $0.comments) }
    }
}

/// The controls as Save Preset writes them (``Controls/preset()``).
nonisolated struct PresetFile: Transferable {
    let json: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.json }
    }
}

/// How long work on the engine waited for it, and took once the engine started on it. The engine
/// does one thing at a time, so a preview asked for while a photo opens waits until it's open: timed
/// from the asking, a 100 ms preview read as a 4-second one (#298).
struct EngineTime {
    var waited = Duration.zero
    var took = Duration.zero

    /// Runs `work` on `engine` and times it: from when the engine starts on it, and, apart, the wait
    /// before that. The engine's API needn't change for it: `run(_:on:)` is isolated to the engine,
    /// so it reads the clock as the engine starts on the work.
    static func measure<T: Sendable>(on engine: Engine, _ work: @Sendable (isolated Engine) throws -> T)
        async throws -> (T, EngineTime) {
        let asked = ContinuousClock.now
        let (value, started, finished) = try await run(work, on: engine)
        return (value, EngineTime(waited: started - asked, took: finished - started))
    }

    /// `work` on `engine`, with when it started and finished there.
    private static func run<T: Sendable>(_ work: @Sendable (isolated Engine) throws -> T,
                                         on engine: isolated Engine)
        throws -> (T, started: ContinuousClock.Instant, finished: ContinuousClock.Instant) {
        let started = ContinuousClock.now
        let value = try work(engine)
        return (value, started, .now)
    }

    static func += (total: inout EngineTime, time: EngineTime) {
        total.waited += time.waited
        total.took += time.took
    }

    /// "in 98 ms", then ", after waiting 3 911 ms" if it waited a millisecond or more, in `units`.
    func formatted(_ units: Set<Duration.UnitsFormatStyle.Unit> = [.milliseconds]) -> String {
        let style = Duration.UnitsFormatStyle.units(allowed: units)
        let wait = waited >= .milliseconds(1) ? ", after waiting \(waited.formatted(style))" : ""
        return "in \(took.formatted(style))\(wait)"
    }
}

/// The finished photo as Share and Copy send it: a JPEG at full resolution, as Save
/// writes one, rendered only when what receives it asks (``PhotoModel/finishedFile(named:)``).
nonisolated struct FinishedPhoto: Transferable {
    let model: PhotoModel
    /// The file's name, without its extension: the photo's.
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { photo in
            SentTransferredFile(try await photo.model.finishedFile(named: photo.name))
        }
        .suggestedFileName { "\($0.name).jpg" }
    }
}
