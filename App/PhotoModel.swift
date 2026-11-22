import AppKit
import CoreTransferable
import Foundation
import ImageIO
import Observation
import SpektraEngine
import UniformTypeIdentifiers
import Vision
import os

@MainActor
@Observable
final class PhotoModel {
    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
    }

    /// The open photo (on the engine's GPU), all of it or framed: its file name, size and preview
    /// size, and what the metering marks found in it.
    struct Photo: Identifiable {
        /// The same through a framing: it's the file that opened.
        var id = UUID()
        let name: String
        let width: Int
        let height: Int
        let previewWidth: Int
        let previewHeight: Int
        let metering: MeteringReadings
        /// The region each mark meters, white with the weight as alpha.
        let meteringOverlays: [MeteringMark: CGImage]
        /// The size it opened at.
        let wholeWidth: Int
        let wholeHeight: Int
        /// How that's turned and cropped, the crop in whole pixels. The photo's own, apart from the
        /// controls: no preset or film's defaults has a framing, and the next photo opens whole.
        var framing = Framing.whole

        /// All of it, in its own pixels.
        var wholeBounds: CGRect { CGRect(x: 0, y: 0, width: wholeWidth, height: wholeHeight) }
    }
    /// A new photo, or the open one cropped another way, stops the last render, empties the kept
    /// renders and the strips, and renders at once, showing its edit.
    private(set) var photo: Photo? {
        didSet {
            // The last photo's render may have started while the engine opened this one, and waited
            // behind it, holding that photo's size and readings. With its preview in flight, this
            // one's own render would return at once, leaving that one to make the strips (#320).
            stopRendering()
            finishedRenders.removeAllObjects()
            strips = [:]
            stripControls = nil
            if photo?.id != oldValue?.id {
                wholeOriginal = nil
                horizons = [:]
                horizonsLookedFor = []
            }
            updateOriginal()
            showsOriginal = false
            scheduleRender()
        }
    }
    /// The open photo as macOS shows it, upright and at full size (``loadOriginal(of:)``), cropped
    /// as the photo is: what a click on the canvas shows in place of the edit.
    private(set) var original: CGImage?
    /// All of it: ``original`` is cut from it, and crop mode shows it.
    private(set) var wholeOriginal: CGImage?
    /// The canvas shows ``original`` in place of the edit, and the settings are greyed out.
    var showsOriginal = false
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
        // The open photo's framing is as it was, should this one fail to open.
        cancelCropping()
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
                askedFraming = .whole
                photo = Photo(name: url.lastPathComponent, width: opened.width, height: opened.height,
                              previewWidth: opened.previewWidth, previewHeight: opened.previewHeight,
                              metering: opened.metering, meteringOverlays: opened.meteringOverlays,
                              wholeWidth: opened.width, wholeHeight: opened.height)
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
                    wholeOriginal = image
                    updateOriginal()
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

    /// Frames ``original`` from ``wholeOriginal`` as the photo is framed: away from the main actor, as
    /// it's a render of the photo's size. Meanwhile there's none to show.
    private func updateOriginal() {
        guard let whole = wholeOriginal, let photo, photo.framing != .whole else {
            original = wholeOriginal
            return
        }
        original = nil
        let (id, framing, size) = (photo.id, photo.framing, photo.wholeBounds.size)
        Task {
            let framed = await Task.detached(priority: .userInitiated) { Self.framed(whole, as: framing, of: size) }.value
            guard self.photo?.id == id, self.photo?.framing == framing, wholeOriginal === whole else { return }
            original = framed ?? whole
        }
    }

    /// `image`, all of a photo of `size` in the engine's pixels, framed as `framing` has it: scaled
    /// to `size` first, as a RAW file's size as ImageIO decodes it can differ from Core Image's.
    nonisolated private static func framed(_ image: CGImage, as framing: Framing, of size: CGSize) -> CGImage? {
        let bounds = CGRect(origin: .zero, size: framing.turned(size))
        let region = framing.crop ?? bounds
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(image.width),
                                                                                  y: size.height / CGFloat(image.height)))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Core Image measures up.
        return imageContext.createCGImage(framing.applied(to: scaled, size: size),
                                          from: CGRect(x: region.minX, y: bounds.height - region.maxY,
                                                       width: region.width, height: region.height),
                                          format: image.bitsPerComponent > 8 ? .RGBAh : .RGBA8, colorSpace: space)
    }

    /// Frames the original and the last render while the engine frames the photo.
    nonisolated private static let imageContext = CIContext()

    // MARK: Cropping

    /// Crop mode: the canvas shows all of the original, turned as marked, with the part to keep
    /// marked on it (``markedFraming``), and the settings wait. ``endCropping()`` keeps that and
    /// ``cancelCropping()`` leaves the photo as it was.
    ///
    /// The original, not the film: grain is the frame's, so a render of all of the photo, zoomed
    /// into, shows the grain larger than the crop will have it.
    private(set) var isCropping = false
    /// Crop mode is ending with the crop kept, once the engine has it: the frame stays as it was
    /// marked until the cropped photo is there to show in its place.
    private(set) var isLeavingCropMode = false
    /// What crop mode marks: the turns, the straightening and the part to keep, which is never nil
    /// there.
    private(set) var markedFraming = Framing.whole
    /// A straightening tape is being dragged or scrolled: the frame shows a fine grid.
    private(set) var isStraightening = false
    /// The angles that level the horizon Vision found in the open photo, for each quarter turn it
    /// was looked for in (``findHorizon()``).
    private(set) var horizons: [Int: Double] = [:]
    /// The quarter turns of the open photo Vision has looked, or is looking, for the horizon in.
    @ObservationIgnored private var horizonsLookedFor: Set<Int> = []
    /// What was marked as the slider's drag began: each angle is set from it, so the frame grows
    /// back as the photo turns back.
    @ObservationIgnored private var markedBeforeStraightening: Framing?
    /// The part marked to keep while cropping, in the pixels of the photo turned as marked, from the
    /// top left of all of it turned (``cropBounds``): what the canvas's handles move.
    var cropSelection: CGRect {
        get { markedFraming.crop ?? .zero }
        set { markedFraming.crop = newValue }
    }
    /// All of the photo turned as marked: what the part marked is measured in.
    var cropBounds: CGRect {
        guard let photo else { return .zero }
        return CGRect(origin: .zero, size: markedFraming.turned(photo.wholeBounds.size))
    }
    /// All of the photo turned and straightened as marked: the part marked keeps inside it.
    var straightenedPhoto: StraightenedPhoto {
        StraightenedPhoto(size: cropBounds.size, angle: markedFraming.angle)
    }
    /// The shape the part marked keeps to, and whether 3:2 and 4:5 stand upright rather than lie on
    /// their side.
    private(set) var cropShape = CropShape.asShot
    private(set) var cropShapeIsUpright = false
    /// The width and height typed for Custom, as the frame stands: nil keeps it to any shape.
    private(set) var typedCropRatio: CGSize?
    /// Width over height the part marked keeps to: nil for any.
    var cropRatio: CGFloat? {
        cropShape.ratio(upright: cropShapeIsUpright, typed: typedCropRatio, in: cropBounds.size)
    }
    /// The shape of the crop last kept: crop mode starts at it, for cropping a series of photos
    /// alike, while the app is open. As Shot until one's kept.
    @ObservationIgnored private var keptCropShape = (shape: CropShape.asShot, isUpright: false, typed: CGSize?.none)
    /// The photo's framing as crop mode began: what Cancel goes back to, and Undo once it's kept.
    @ObservationIgnored private var framingBeforeCropping = Framing.whole
    /// The framing last asked of the engine for the open photo, which ``photo`` has once it's made.
    @ObservationIgnored private var askedFraming = Framing.whole
    /// How many framings have been asked of the engine: the newest one's photo is the one that shows.
    @ObservationIgnored private var framingsStarted = 0

    /// Once the original, which crop mode shows, has loaded. Not while a photo opens, which the
    /// engine would crop in place of this one, or one saves.
    var canCrop: Bool { photo != nil && wholeOriginal != nil && engine != nil && !isLoading && savePhase == nil }

    /// In crop mode until the crop is being kept; otherwise as the photo can be framed.
    var canTurn: Bool {
        isCropping ? !isLeavingCropMode : photo != nil && engine != nil && !isLoading && savePhase == nil
    }

    /// Starts crop mode, on all of the original: a cropped photo shows whole, with its crop marked.
    /// It starts at the shape last kept, unless the photo is cropped to another.
    func beginCropping() {
        guard canCrop, !isCropping, let photo else { return }
        isCropping = true
        showsOriginal = false
        endStraightening()
        framingBeforeCropping = photo.framing
        markedFraming = photo.framing
        cropSelection = photo.framing.crop ?? cropBounds
        let kept = keptCropShape
        let keptRatio = kept.shape.ratio(upright: kept.isUpright, typed: kept.typed, in: cropBounds.size)
        let isKeptShape = keptRatio.map { abs(cropSelection.width - cropSelection.height * $0) <= 1 } ?? true
        if photo.framing.crop == nil || isKeptShape {
            setCropShape(kept.shape, upright: kept.isUpright, typed: kept.typed)
        } else {
            setCropShape(.custom, upright: false, typed: nil)
        }
        findHorizon()
    }

    /// Keeps the part marked to `shape`, standing as the part marked does. Custom keeps it to any
    /// shape, until a ratio is typed for it.
    func chooseCropShape(_ shape: CropShape) {
        setCropShape(shape, upright: cropSelection.height > cropSelection.width, typed: nil)
    }

    /// Keeps the part marked to `ratio`'s width by its height as typed for Custom, so 9:16 stands
    /// upright: the largest part of that shape in it. For nil, to any shape.
    func typeCropRatio(_ ratio: CGSize?) {
        setCropShape(.custom, upright: false, typed: ratio)
    }

    /// Keeps the part marked to `shape`: the largest part of that shape in what's marked, about the
    /// same middle.
    private func setCropShape(_ shape: CropShape, upright: Bool, typed: CGSize?) {
        cropShape = shape
        cropShapeIsUpright = upright
        typedCropRatio = typed
        guard let ratio = cropRatio else { return }
        let marked = cropSelection
        let width = min(marked.width, marked.height * ratio)
        cropSelection = CGRect(x: marked.midX - width / 2, y: marked.midY - width / ratio / 2,
                               width: width, height: width / ratio)
    }

    /// Turns the photo a quarter to the left, or for −1 to the right. In crop mode the part marked
    /// turns with it; otherwise the photo turns at once, one step to undo.
    func turn(left quarters: Int) {
        guard canTurn, let photo else { return }
        if isCropping {
            markedFraming = markedFraming.turned(left: quarters, in: photo.wholeBounds.size)
            if !quarters.isMultiple(of: 2) {
                cropShapeIsUpright.toggle()
                // 16:9 typed is 9:16 turned.
                typedCropRatio = typedCropRatio.map { CGSize(width: $0.height, height: $0.width) }
            }
            findHorizon()
        } else {
            // From the framing asked for last, so turns made faster than the engine all count.
            setFraming(askedFraming.turned(left: quarters, in: photo.wholeBounds.size), from: askedFraming,
                       named: "Rotate")
        }
    }

    /// A drag or scroll of a tape begins: angles are set from what's marked now. It takes over from
    /// a turn to the horizon under way.
    func beginStraightening() {
        guard isCropping else { return }
        horizonTurn?.cancel()
        horizonTurn = nil
        markedBeforeStraightening = markedFraming
        isStraightening = true
    }

    func endStraightening() {
        markedBeforeStraightening = nil
        isStraightening = false
    }

    /// Straightens the photo `angle` degrees to the right, to a tenth, from what was marked as the
    /// slider's drag began, or else from what's marked. The frame keeps the same part of the photo
    /// in its middle and its shape, made smaller where it would reach past the photo's edge.
    func straighten(to angle: Double) {
        guard isCropping, !isLeavingCropMode else { return }
        let start = markedBeforeStraightening ?? markedFraming
        guard let crop = start.crop else { return }
        let angle = min(max((angle * 10).rounded() / 10, -45), 45)
        let size = cropBounds.size
        let middle = StraightenedPhoto(size: size, angle: angle)
            .straightened(StraightenedPhoto(size: size, angle: start.angle).unstraightened(CGPoint(x: crop.midX, y: crop.midY)))
        markedFraming.angle = angle
        cropSelection = straightenedPhoto.fitted(CGRect(x: middle.x - crop.width / 2, y: middle.y - crop.height / 2,
                                                        width: crop.width, height: crop.height))
    }

    /// The angle, to a tenth, that levels the horizon Vision found in the photo turned as marked: nil
    /// while it looks, or where it found none.
    var horizonAngle: Double? { horizons[markedFraming.quarterTurns] }

    /// Straightens the photo by its horizon (``horizonAngle``), as a click on its dot on the tapes:
    /// turning it there over half a second as a quick drag of a tape would, so the frame, the tapes,
    /// the fine grid and the trackpad's clicks go with it. At once with Reduce Motion. A drag or
    /// scroll of a tape takes over from it.
    func straightenByHorizon() {
        guard isCropping, !isLeavingCropMode, let target = horizonAngle else { return }
        endStraightening()
        let start = markedFraming.angle
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(target - start) >= 0.1 else {
            straighten(to: target)
            return
        }
        beginStraightening()
        horizonTurn = Task {
            let clock = ContinuousClock()
            let began = clock.now
            var done = 0.0
            while done < 1, !Task.isCancelled, isCropping, !isLeavingCropMode {
                done = min(1, (clock.now - began) / .milliseconds(500))
                // Easing in and out.
                straighten(to: start + (target - start) * done * done * (3 - 2 * done))
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled {
                endStraightening()
            }
        }
    }

    /// The turn to the horizon under way (``straightenByHorizon()``).
    @ObservationIgnored private var horizonTurn: Task<Void, Never>?

    /// Has Vision look for the horizon in the original turned as marked, once for each quarter turn
    /// of the open photo, away from the main actor: in crop mode, for its dot on the tapes.
    private func findHorizon() {
        let turns = markedFraming.quarterTurns
        guard isCropping, let whole = wholeOriginal, let photo, !horizonsLookedFor.contains(turns) else { return }
        horizonsLookedFor.insert(turns)
        Task {
            let found: Result<Double?, any Error>
            do {
                found = .success(try await Self.levellingAngle(of: whole, turnedLeft: turns))
            } catch {
                found = .failure(error)
            }
            guard self.photo?.id == photo.id else { return }
            switch found {
            case .success(let angle?):
                horizons[turns] = min(max((angle * 10).rounded() / 10, -45), 45)
            case .success(nil):
                note("Found no horizon in \(photo.name)")
            case .failure(let error):
                horizonsLookedFor.remove(turns)
                fail("Couldn't look for the horizon in “\(photo.name)”", error)
            }
        }
    }

    /// The degrees to the right that level the horizon Vision finds in `image` turned `quarters` to
    /// the left: nil where it finds none, as where it's level already. Vision looks at it 1024
    /// pixels on the long side, away from the main actor.
    @concurrent nonisolated private static func levellingAngle(of image: CGImage, turnedLeft quarters: Int) async throws -> Double? {
        let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        // In whole pixels: with a fraction of one at an edge, Vision found no horizon in photos
        // where it finds one otherwise.
        let size = CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(image.width),
                                                                                y: size.height / CGFloat(image.height)))
        let turned = Framing(quarterTurns: quarters).applied(to: small, size: size)
        guard let horizon = try await DetectHorizonRequest().perform(on: turned) else { return nil }
        // Vision's angle turns the photo anticlockwise to level it: a photo turned 2° clockwise
        // reads +2°.
        return -horizon.angle.converted(to: .degrees).value
    }

    /// Something to reset: the photo is framed, or what's marked isn't all of it.
    var canResetCrop: Bool {
        guard isCropping, !isLeavingCropMode else { return false }
        return framingBeforeCropping != .whole || framingToKeep != .whole
    }

    /// Ends crop mode with all of the photo kept, unturned: one step to undo, as ``endCropping()``.
    /// The frame stays as marked until the photo shows, so Done doesn't start to grow out of Crop
    /// meanwhile.
    func resetCrop() {
        guard canResetCrop else { return }
        setFraming(.whole, from: framingBeforeCropping, named: "Crop")
    }

    /// What's marked differs from the framing as crop mode began: ``endCropping()`` would change it.
    var hasCropChanges: Bool {
        isCropping && framingToKeep != framingBeforeCropping
    }

    /// Ends crop mode, framing the photo as marked, in whole pixels: one step to undo. A crop of a
    /// new shape is the one the next starts at.
    func endCropping() {
        guard isCropping, !isLeavingCropMode else { return }
        if hasCropChanges {
            keptCropShape = (cropShape, cropShapeIsUpright, typedCropRatio)
        }
        setFraming(framingToKeep, from: framingBeforeCropping, named: "Crop")
    }

    /// ``markedFraming`` with the part marked in whole pixels: no crop for all of the photo.
    private var framingToKeep: Framing {
        let bounds = cropBounds
        // The size before the place, so a square stays one.
        let size = CGSize(width: max(1, cropSelection.width.rounded()), height: max(1, cropSelection.height.rounded()))
        var framing = markedFraming
        // Straightened, the photo reaches past where it lies unstraightened, and isn't all kept: in
        // whole pixels inside it, a pixel smaller where rounding would take a corner past its edge.
        // Kept past it, the frame marked in crop mode again would have no room to move.
        guard framing.angle == 0 else {
            let photo = straightenedPhoto
            var (inside, kept) = (size, CGRect.zero)
            for _ in 0..<4 {
                let placed = photo.fitted(CGRect(x: cropSelection.midX - inside.width / 2, y: cropSelection.midY - inside.height / 2,
                                                 width: inside.width, height: inside.height))
                kept = CGRect(origin: CGPoint(x: placed.minX.rounded(), y: placed.minY.rounded()), size: inside)
                if photo.contains(kept) {
                    break
                }
                inside = CGSize(width: max(1, inside.width - 1), height: max(1, inside.height - 1))
            }
            framing.crop = kept
            return framing
        }
        let origin = CGPoint(x: min(max(0, cropSelection.minX.rounded()), bounds.width - size.width),
                             y: min(max(0, cropSelection.minY.rounded()), bounds.height - size.height))
        let kept = CGRect(origin: origin, size: size).intersection(bounds)
        framing.crop = kept == bounds ? nil : kept
        return framing
    }

    /// Ends crop mode with the photo framed as it was before: not once the crop is being kept.
    func cancelCropping() {
        guard isCropping, !isLeavingCropMode else { return }
        isCropping = false
    }

    /// Frames the photo as `framing` has it, which Undo sets back to `previous`: a step named `name`.
    private func setFraming(_ framing: Framing, from previous: Framing, named name: String) {
        if framing != previous, let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                // Not while a photo opens: the engine would frame that one. The step is spent, and
                // the photo that opens empties Undo. Undone in crop mode, the mode ends: the crop
                // it was marking is gone.
                guard !model.isLoading else { return }
                model.setFraming(previous, from: framing, named: name)
            }
            undoManager.setActionName(name)
        }
        applyFraming(framing)
    }

    /// Has the engine frame the photo as `framing` has it, and shows the result: metered again, at
    /// the exposure it had. The newest of several asked for is the one that shows. Crop mode ends
    /// with it.
    private func applyFraming(_ framing: Framing) {
        guard let engine, let photo, framing != askedFraming else {
            isCropping = false
            return
        }
        askedFraming = framing
        framingsStarted += 1
        let generation = framingsStarted
        isLeavingCropMode = isCropping
        // The engine frames once it's done rendering: stop that.
        stopRendering()
        stripTask?.cancel()
        stripTask = nil
        stopPreloading()
        Task {
            do {
                let (opened, time) = try await EngineTime.measure(on: engine) { try $0.frame(framing) }
                // A framing asked for since shows instead.
                guard generation == framingsStarted else { return }
                isCropping = false
                isLeavingCropMode = false
                // As does another photo.
                guard let shown = self.photo, shown.id == photo.id else { return }
                // Until its first render, the canvas shows the last one framed the same way: cut and
                // turned from it where it shows all of that, else nothing.
                displayImage = displayImage.flatMap { Self.cut($0, framed: shown.framing, to: framing,
                                                               of: shown.wholeBounds.size) }
                self.photo = Photo(id: shown.id, name: shown.name, width: opened.width, height: opened.height,
                                   previewWidth: opened.previewWidth, previewHeight: opened.previewHeight,
                                   metering: opened.metering, meteringOverlays: opened.meteringOverlays,
                                   wholeWidth: shown.wholeWidth, wholeHeight: shown.wholeHeight, framing: framing)
                let what = framing == .whole ? "Showed all of" : framing.crop == nil ? "Turned" : "Cropped"
                note("\(what) \(shown.name) (\(opened.width) × \(opened.height)) \(time.formatted())")
            } catch {
                guard generation == framingsStarted else { return }
                isCropping = false
                isLeavingCropMode = false
                guard self.photo?.id == photo.id else { return }
                // The engine keeps the photo as it was: its renders, stopped above, start again.
                askedFraming = self.photo?.framing ?? .whole
                scheduleRender()
                fail("Couldn't crop “\(photo.name)”", error, alert: true)
            }
        }
    }

    /// `display`, a render of a photo of `size` framed `shown`, cut and turned to show it framed
    /// `framing`: nil where it doesn't show all of that, or it's straightened otherwise.
    nonisolated private static func cut(_ display: CGImage, framed shown: Framing, to framing: Framing,
                                        of size: CGSize) -> CGImage? {
        guard framing.angle == shown.angle else { return nil }
        let quarters = framing.quarterTurns - shown.quarterTurns
        // What's to show, where the render lies.
        let wanted = framing.turned(left: -quarters, in: size)
        let kept = wanted.crop ?? CGRect(origin: .zero, size: wanted.turned(size))
        let rendered = shown.crop ?? CGRect(origin: .zero, size: shown.turned(size))
        guard rendered.contains(kept) else { return nil }
        let scale = CGAffineTransform(scaleX: CGFloat(display.width) / rendered.width,
                                      y: CGFloat(display.height) / rendered.height)
        guard let part = display.cropping(to: kept.offsetBy(dx: -rendered.minX, dy: -rendered.minY)
                                              .applying(scale).integral) else { return nil }
        return quarters.isMultiple(of: 4) ? part : framed(part, as: Framing(quarterTurns: quarters),
                                                          of: CGSize(width: part.width, height: part.height))
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

    /// Not in crop mode, where the engine has all of the photo, whatever is marked to keep.
    var canSave: Bool { photo != nil && engine != nil && savePhase == nil && !isCropping }
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

    /// The finished photo, for Share and Copy, while a photo is open and not being cropped.
    var finishedPhoto: FinishedPhoto? {
        guard !isCropping else { return nil }
        return photo.map { FinishedPhoto(model: self, name: ($0.name as NSString).deletingPathExtension) }
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
