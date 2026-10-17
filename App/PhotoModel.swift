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
    /// A new photo empties the kept renders and the strips, and renders at once.
    private(set) var photo: Photo? {
        didSet {
            finishedRenders.removeAllObjects()
            strips = [:]
            stripControls = nil
            scheduleRender()
        }
    }
    /// The photo's EXIF, GPS and IPTC records, for saved renderings.
    @ObservationIgnored private var metadata: PhotoMetadata?
    /// What the sidebar and the Print | Film switch set; every change re-renders the preview.
    var controls = Controls() {
        didSet {
            showsFilm = controls.scanFilm
            isSlideFilm = films.first { $0.stock == controls.film }?.type == .positive
            scheduleRender()
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
    /// What choosing `film` sets the controls to (``film``).
    func controls(choosing film: String) -> Controls {
        savedDefaults(for: film) ?? factoryControls(for: film, from: controls)
    }
    var filmName: String { films.first { $0.stock == controls.film }?.name ?? controls.film }
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
    /// The exposure's range: −4…+8 stops, widened to whole stops past any reading outside it.
    var exposureRange: ClosedRange<Double> {
        let values = (photo?.metering.ev.compactMap { $0 } ?? []) + [exposureEV]
        return min(-4, (values.min() ?? 0).rounded(.down) - 1)...max(8, (values.max() ?? 0).rounded(.up) + 1)
    }
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
    /// A render with the blurs and grain is running. Not a preview: at each step of a slider,
    /// "Rendering…" would flicker under the window's title, laying out the toolbar each time.
    private(set) var isRendering = false
    private(set) var isRenderingFullResolution = false
    /// What saving is doing, while it runs.
    private(set) var savePhase: String?
    private(set) var errorMessage: String?
    private(set) var log: [LogEntry] = []
    /// Drives the Open panel (`fileImporter`); ⌘O and the toolbar set it.
    var isImporting = false
    /// Drives the Open Preset panel (`fileImporter`); its menu item sets it.
    var isImportingPreset = false

    /// Made in the background as the app starts, so the window shows at once: about 0.1 s,
    /// 0.5 s on the first launch after a build, as Metal compiles the shaders. The Film and Paper
    /// menus fill, and photos open, once it's here.
    private var engine: Engine?
    private let logger = Logger(subsystem: "nainajnahO.SpektraMac", category: "model")
    private var renderTask: Task<Void, Never>?
    /// Finished renders at the canvas's size for the open photo, by the controls they show: going
    /// back to controls shown before (hovering back to a stock, a slider back at a value) shows
    /// them at once, as do the stocks a menu renders ahead (``preload(_:)``). Not
    /// full-resolution ones (96 MB at 24 MP). `NSCache` drops the oldest past
    /// 512 MB, and all of them when memory runs low.
    private let finishedRenders: NSCache<RenderKey, CGImage> = {
        let cache = NSCache<RenderKey, CGImage>()
        cache.totalCostLimit = 512 << 20
        return cache
    }()
    private var renderScheduled = false
    private var saveTask: Task<Void, Never>?

    init() {
        let making = Task.detached(priority: .userInitiated) { try Engine() }
        Task {
            do {
                engine = try await making.value
            } catch {
                errorMessage = "Metal is unavailable: \(error.localizedDescription)"
                return
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
                stripTask?.cancel()
                stripTask = nil
                stopPreloading()
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
        if start == .preview {
            stripTask?.cancel()
            stripTask = nil
        }
        isPreviewing = false
        isRenderingFullResolution = false
        awaitsFullResolution = false
        guard let photo, let engine else {
            displayImage = nil
            isRendering = false
            return
        }
        isRendering = start != .preview
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
                renderStrips(photo: photo, engine: engine)
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
        case .thumbnail: "thumbnail"
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

    // MARK: Thumbnail strips

    /// A control shown as Photos shows its main adjustments: the photo across the control's range,
    /// a frame each, rendered in preview mode on a small image of the photo (``RenderMode/thumbnail``).
    /// Halation, grain and glare barely show at that size, so they have none.
    enum Strip: CaseIterable {
        case exposure, couplerSaturation, printContrast, printExposure
    }
    static let framesPerStrip = 5
    /// Each strip's frames, left to right. A strip whose control changes nothing the controls show
    /// (a print setting while the film shows, say) has none.
    private(set) var strips: [Strip: [CGImage]] = [:]
    /// The controls the strips were made for.
    @ObservationIgnored private var stripControls: Controls?
    /// Makes the strips for the controls; a change to them stops it (``render(from:)``).
    @ObservationIgnored private var stripTask: Task<Void, Never>?

    /// The range a strip's control spans.
    func range(of strip: Strip) -> ClosedRange<Double> {
        switch strip {
        case .exposure: exposureRange
        case .couplerSaturation: 0...1.5
        case .printContrast: 0.5...2
        case .printExposure: 0...2
        }
    }

    /// Renders the strips for the controls, unless they show them or are being made for them. Each
    /// frame is a render of its own, so a change's preview waits on one frame at most; each strip
    /// shows once all its frames are done.
    private func renderStrips(photo: Photo, engine: Engine) {
        let controls = controls
        guard controls != stripControls, stripTask == nil else { return }
        stripTask = Task {
            let start = ContinuousClock.now
            var count = 0
            do {
                for strip in Strip.allCases {
                    guard applies(strip, to: controls) else {
                        strips[strip] = nil
                        continue
                    }
                    let span = range(of: strip)
                    var frames: [CGImage] = []
                    for frame in 0..<Self.framesPerStrip {
                        // The value at the middle of the frame.
                        let value = span.lowerBound
                            + (Double(frame) + 0.5) / Double(Self.framesPerStrip) * (span.upperBound - span.lowerBound)
                        frames.append(try await engine.display(
                            controls: frameControls(controls, strip: strip, value: value, photo: photo), mode: .thumbnail))
                        try Task.checkCancellation()
                    }
                    strips[strip] = frames
                    count += frames.count
                }
                stripControls = controls
                stripTask = nil
                let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
                note("Rendered \(count) thumbnails in \(elapsed)")
            } catch {
                guard !Task.isCancelled else { return }
                stripTask = nil
                fail("Could not render the thumbnails", error)
            }
        }
    }

    /// Whether `strip`'s control changes what `controls` show.
    private func applies(_ strip: Strip, to controls: Controls) -> Bool {
        switch strip {
        case .exposure: true
        case .couplerSaturation: controls.couplers
        case .printContrast, .printExposure: !controls.scanFilm
        }
    }

    /// `controls` with `strip`'s control at `value`: for the exposure, `value` stops over the
    /// photo as shot, from the controls' mark.
    private func frameControls(_ controls: Controls, strip: Strip, value: Double, photo: Photo) -> Controls {
        var controls = controls
        switch strip {
        case .exposure:
            controls.exposureOffsetEV = value - photo.metering.reading(resolving: controls.exposureMark).ev
        case .couplerSaturation:
            controls.couplerSaturation = value
        case .printContrast:
            controls.printContrast = value
        case .printExposure:
            controls.printExposure = value
        }
        return controls
    }

    // MARK: Stocks rendered ahead

    /// Renders what a stock menu offers, while it's open (``preload(_:)``).
    @ObservationIgnored private var preloadTask: Task<Void, Never>?

    /// Renders each of `choices` (what choosing each stock of a menu sets the controls to, in
    /// order) with every effect at the canvas's size into the kept renders, so the menu shows a
    /// stock finished the moment the pointer is on it (``showKept(_:photo:)``). One render at a
    /// time, as the strips are made: a stock the pointer reaches before its turn waits on one
    /// render at most. As many as fill half the kept renders' memory, so they can't push each
    /// other out.
    func preload(_ choices: [Controls]) {
        stopPreloading()
        guard let photo, let engine else { return }
        let longSide = reducedLongSide(of: photo)
        let scale = min(1, Double(longSide) / Double(max(photo.width, photo.height)))
        let bytes = Int(Double(photo.width) * scale) * Int(Double(photo.height) * scale) * 4
        let keys = choices.prefix(finishedRenders.totalCostLimit / 2 / bytes)
            .map { RenderKey(controls: $0, longSide: longSide) }
        preloadTask = Task {
            let start = ContinuousClock.now
            var count = 0
            do {
                for key in keys where finishedRenders.object(forKey: key) == nil {
                    let display = try await engine.display(controls: key.controls, mode: .reduced(longSide: longSide))
                    try Task.checkCancellation()
                    finishedRenders.setObject(display, forKey: key, cost: display.bytesPerRow * display.height)
                    count += 1
                }
                if count > 0 {
                    let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
                    note("Rendered \(count) stocks ahead in \(elapsed)")
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail("Could not render the stocks ahead", error)
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
                let image = try await engine.export(controls: controls, as: type)
                try Task.checkCancellation()
                savePhase = "Writing \(url.lastPathComponent)…"
                try await Task.detached(priority: .userInitiated) {
                    try image.write(to: url, as: type, metadata: metadata)
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

    func openPreset(_ url: URL) {
        // Files from the Open panel are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
