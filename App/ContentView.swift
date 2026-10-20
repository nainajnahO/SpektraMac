import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PhotoModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @SceneStorage("showsSettings") private var showsSettings = true
    @SceneStorage("settingsCategory") private var category = SettingsCategory.film

    var body: some View {
        @Bindable var model = model
        ImageCanvas()
            .navigationTitle(model.photo?.name ?? "SpektraMac")
            .navigationSubtitle(status)
            .toolbar {
                ToolbarItemGroup(placement: .principal) {
                    ShowPicker()
                }
                ToolbarItemGroup {
                    Button("Open…", systemImage: "folder") { model.isImporting = true }
                    if model.canCancel {
                        Button("Cancel", systemImage: "xmark.circle") { model.cancel() }
                    }
                    Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                        .disabled(!model.canSave)
                    Button("Log", systemImage: "list.bullet.rectangle") { openWindow(id: "log") }
                    Toggle("Adjust", systemImage: "slider.horizontal.3", isOn: $showsSettings)
                        .help("Show or hide the settings")
                }
            }
            // No toolbar background, so the inspector's glass is even to the top: macOS draws one for
            // each column, over the inspector a dark fade behind the tabs. The zoomed photo shows
            // under the toolbar's glass instead (``ImageCanvas``).
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // On the right over the photo, as Photos' Adjust panel: the photo fits beside it and
            // shows through the inspector's glass when zoomed or moved under it (``ImageCanvas``),
            // as the inspector lies over the canvas rather than beside it.
            .inspector(isPresented: $showsSettings) {
                SettingsPanel(category: category)
                    // Greyed out while the canvas shows the original: they set the edit.
                    .disabled(model.showsOriginal)
                    .inspectorColumnWidth(290)
                    // In the inspector's own part of the toolbar, so centred over the panel.
                    .toolbar {
                        ToolbarSpacer(.flexible)
                        ToolbarItem {
                            Picker("Settings", selection: $category) {
                                ForEach(SettingsCategory.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            .pickerStyle(.segmented)
                        }
                        ToolbarSpacer(.flexible)
                    }
            }
            .onChange(of: undoManager, initial: true) { _, undoManager in
                model.undoManager = undoManager
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.open(url)
                return true
            }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): model.open(url)
            case .failure(let error): model.importFailed(error)
            }
        }
        .fileImporter(isPresented: $model.isImportingPreset, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.openPreset(url)
            case .failure(let error): model.importFailed(error)
            }
        }
        .alert(model.failure?.title ?? "", isPresented: Binding { model.failure != nil } set: { if !$0 { model.failure = nil } },
               presenting: model.failure) { _ in
        } message: { failure in
            Text(failure.message)
        }
    }

    /// What the app is doing, else the last error (until a photo is opened), else what the canvas
    /// shows: under the window's title.
    private var status: String {
        if model.isLoading { return "Opening…" }
        if let phase = model.savePhase { return phase }
        if model.showsOriginal { return "Original" }
        if model.isRendering { return model.isRenderingFullResolution ? "Rendering full resolution…" : "Rendering…" }
        if let message = model.errorMessage { return message }
        // Without one, the canvas says so.
        guard let photo = model.photo else { return "" }
        if model.shownMode == .full {
            return "Full resolution, \(photo.width.formatted()) × \(photo.height.formatted())"
        } else if case .reduced? = model.shownMode, let image = model.displayImage {
            return "Screen size, \(image.width.formatted()) × \(image.height.formatted())"
        } else {
            return "Preview, \(photo.previewWidth.formatted()) × \(photo.previewHeight.formatted())"
        }
    }
}

/// Print | Film, in a view of its own reading only what it shows (``PhotoModel/showsFilm``): the
/// controls change at every step of a slider, and read here or in the window's body they laid out
/// the toolbar again each time.
private struct ShowPicker: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        Picker("Show", selection: Binding { model.showsFilm } set: { model.controls.scanFilm = $0 }) {
            Text("Print").tag(false)
                .selectionDisabled(model.isSlideFilm)
            Text("Film").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(model.showsOriginal)
        .help("Print: the film printed on the paper. Film: the developed negative, or the slide itself.")
    }
}

// MARK: - Canvas

/// The photo fitted to the canvas below the toolbar and beside the settings panel. Scrolling (or
/// pinching) zooms around the pointer, dragging moves the zoomed photo, clicking shows the original
/// in place of the edit (and the edit again), and double-clicking shows all of it again. The canvas
/// reaches under the toolbar and the panel, so a zoomed photo shows through them, as in Photos.
private struct ImageCanvas: View {
    @Environment(PhotoModel.self) private var model
    /// Magnification over the photo fitted to the canvas (1 shows all of it), and how far the
    /// zoomed photo is moved from the centre, in points.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    /// How much of the canvas the toolbar (top) and the settings panel (trailing) cover.
    @State private var insets = EdgeInsets()
    /// Where the pointer is over the canvas below the toolbar and beside the panel: scrolling
    /// zooms around it.
    @State private var pointer: CGPoint?
    /// The offset when the drag began, and the pinch's magnification so far.
    @State private var dragStart: CGSize?
    @State private var pinched: CGFloat = 1
    @State private var scrollMonitor: Any?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Takes the canvas below the toolbar and beside the panel, whose geometry gives their sizes
        // (the safe area's insets); the canvas itself reaches under them.
        Color.clear
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                self.insets = insets
                offset = clamped(offset)
            }
            .overlay { canvas.ignoresSafeArea(.container, edges: [.top, .trailing]) }
            // Over the canvas below the toolbar and beside the panel, so centred there.
            .overlay {
                if model.displayImage == nil {
                    if let failure = model.engineFailure {
                        ContentUnavailableView("Metal is unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text("SpektraMac simulates film on the graphics processor, through Metal. \(failure)."))
                    } else {
                        ContentUnavailableView {
                            Label("No photo", systemImage: "photo")
                        } description: {
                            Text("Drop a photo here or open one to simulate it on film.")
                        } actions: {
                            Button("Open…") { model.isImporting = true }
                        }
                    }
                }
            }
    }

    private var canvas: some View {
        // A stack, not a group: without a photo, the canvas is still there to measure and to shade.
        ZStack {
            if let image = model.displayImage {
                // The reader takes the canvas's size and passes nothing back: a frame sized by the
                // photo would make that the window's minimum.
                GeometryReader { _ in
                    let fitted = fittedSize(in: visibleSize)
                    Image(decorative: model.showsOriginal ? model.original ?? image : image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .overlay { meteringOverlay }
                        .overlay { burnOverlay }
                        .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                        .position(x: visibleCentre.x + offset.width, y: visibleCentre.y + offset.height)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { drag in
                        let start = dragStart ?? offset
                        dragStart = start
                        offset = clamped(CGSize(width: start.width + drag.translation.width,
                                                height: start.height + drag.translation.height))
                    }
                    .onEnded { _ in dragStart = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { pinch in
                        zoom(by: pinch.magnification / pinched, at: pinch.startLocation)
                        pinched = pinch.magnification
                    }
                    .onEnded { _ in pinched = 1 })
                // Each click of a double-click is a click too: it switches twice, so it ends on
                // the view it started from.
                .onTapGesture {
                    if model.original != nil {
                        model.showsOriginal.toggle()
                    }
                    if NSApp.currentEvent?.clickCount == 2 {
                        zoom = 1
                        offset = .zero
                    }
                }
                .pointerStyle(zoom > 1 ? (dragStart == nil ? .grabIdle : .grabActive) : nil)
                .onContinuousHover { phase in
                    switch phase {
                    // Not under the toolbar or the panel: they lie over the canvas, yet it's still
                    // told where the pointer is.
                    case .active(let location) where location.x < visibleSize.width && location.y >= insets.top:
                        pointer = location
                    case .active, .ended: pointer = nil
                    }
                }
                .onAppear {
                    // SwiftUI has no scroll-wheel events for a plain view, so AppKit's: over the
                    // photo, scrolling zooms instead of scrolling. A trackpad's momentum after
                    // the fingers lift is left out, so the zoom stops with them.
                    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        guard let pointer else { return event }
                        if event.momentumPhase.isEmpty {
                            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.15  // points, or wheel lines
                            zoom(by: exp(event.scrollingDeltaY * step), at: pointer)
                        }
                        return nil
                    }
                }
                .onDisappear {
                    if let scrollMonitor {
                        NSEvent.removeMonitor(scrollMonitor)
                    }
                    scrollMonitor = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(.black.opacity(0.05))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            canvasSize = size
            offset = clamped(offset)
        }
        .onChange(of: model.photo?.id) {
            zoom = 1
            offset = .zero
        }
        .onChange(of: fittedLongSide, initial: true) { _, pixels in
            model.canvasLongSide = pixels
        }
        .onChange(of: zoom > 1, initial: true) { _, wants in
            model.wantsFullResolution = wants
        }
    }

    /// The canvas below the toolbar and beside the panel.
    private var visibleSize: CGSize {
        CGSize(width: max(0, canvasSize.width - insets.trailing), height: max(0, canvasSize.height - insets.top))
    }

    private var visibleCentre: CGPoint {
        CGPoint(x: visibleSize.width / 2, y: insets.top + visibleSize.height / 2)
    }

    /// While the Exposure slider is held on a mark: the region that mark meters, tinted.
    @ViewBuilder private var meteringOverlay: some View {
        if model.isAdjustingExposure, let photo = model.photo {
            ZStack {
                ForEach(model.marksAtExposure, id: \.self) { mark in
                    if let overlay = photo.meteringOverlays[mark] {
                        Color.pink
                            .mask { Image(decorative: overlay, scale: 1).resizable() }
                            .opacity(0.5)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// While a Burn slider is held: what burns, in place of the photo, white on black as strongly as
    /// it burns.
    @ViewBuilder private var burnOverlay: some View {
        if model.isAdjustingBurn, let mask = model.burnMask {
            Image(decorative: mask, scale: 1)
                .resizable()
                .background(.black)
                .allowsHitTesting(false)
        }
    }

    /// The photo's size scaled to fit `size`, with a margin: the photo's own shape, whichever
    /// render is shown, so swapping renders can't move it.
    private func fittedSize(in size: CGSize) -> CGSize {
        guard let photo = model.photo else { return .zero }
        let inset: CGFloat = 12
        let scale = max(0, min((size.width - 2 * inset) / CGFloat(photo.width),
                               (size.height - 2 * inset) / CGFloat(photo.height)))
        return CGSize(width: CGFloat(photo.width) * scale, height: CGFloat(photo.height) * scale)
    }

    /// The fitted photo's long side in screen pixels.
    private var fittedLongSide: Int {
        let fitted = fittedSize(in: visibleSize)
        return Int((max(fitted.width, fitted.height) * displayScale).rounded(.up))
    }

    /// Zooms by `factor`, keeping the photo's point under `anchor` (canvas coordinates) where it
    /// is: from all of the photo to 4 points per photo pixel.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        guard let photo = model.photo else { return }
        let fitted = fittedSize(in: visibleSize)
        guard fitted.width > 0 else { return }
        let newZoom = min(max(zoom * factor, 1), max(1, 4 * CGFloat(photo.width) / fitted.width))
        let applied = newZoom / zoom
        // The anchor's distance from the photo's centre scales with the zoom.
        let fromCentre = CGSize(width: anchor.x - visibleCentre.x, height: anchor.y - visibleCentre.y)
        zoom = newZoom
        offset = clamped(CGSize(width: fromCentre.width - (fromCentre.width - offset.width) * applied,
                                height: fromCentre.height - (fromCentre.height - offset.height) * applied))
    }

    /// `offset` limited so the zoomed photo fills the canvas below the toolbar and beside the panel
    /// where it's larger, and stays centred there where it's smaller.
    private func clamped(_ offset: CGSize) -> CGSize {
        let fitted = fittedSize(in: visibleSize)
        let slack = CGSize(width: max(0, (fitted.width * zoom - visibleSize.width) / 2),
                           height: max(0, (fitted.height * zoom - visibleSize.height) / 2))
        return CGSize(width: min(max(offset.width, -slack.width), slack.width),
                      height: min(max(offset.height, -slack.height), slack.height))
    }
}

// MARK: - Log

struct LogView: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(model.log) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.time, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
            .padding(10)
        }
        .defaultScrollAnchor(.bottom)
    }
}
