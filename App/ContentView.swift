import Charts
import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PhotoModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @SceneStorage("showsSettings") private var showsSettings = true
    @SceneStorage("settingsCategory") private var category = SettingsCategory.film
    @FocusState private var isCanvasFocused: Bool

    var body: some View {
        @Bindable var model = model
        ImageCanvas()
            .background(HostingViewName(name: "Photo"))
            // Focused from the start, as nothing else in the window takes focus on a click, so
            // Edit › Copy (⌘C) reaches it: the finished photo, as Share sends it.
            .focusable()
            .focusEffectDisabled()
            .focused($isCanvasFocused)
            .defaultFocus($isCanvasFocused, true)
            .copyable([model.finishedPhoto].compactMap { $0 })
            .navigationTitle(model.photo?.name ?? "SpektraMac")
            .navigationSubtitle(status)
            .toolbar { windowToolbar }
            // No toolbar background, so the inspector's glass is even to the top: macOS draws one for
            // each column, over the inspector a dark fade behind the tabs. The zoomed photo shows
            // under the toolbar's glass instead (``ImageCanvas``).
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // On the right over the photo, as Photos' Adjust panel: the photo fits beside it and
            // shows through the inspector's glass when zoomed or moved under it (``ImageCanvas``),
            // as the inspector lies over the canvas rather than beside it. View › Hide Inspector
            // hides it (``InspectorCommands``): the toolbar has no button for it.
            .inspector(isPresented: $showsSettings) {
                SettingsPanel(category: category)
                    .background(HostingViewName(name: "Settings"))
                    // Greyed out while the canvas shows the original, or the photo to crop: they set
                    // the edit.
                    .disabled(model.showsOriginal || model.isCropping)
                    .inspectorColumnWidth(290)
                    // A fixed width still lets a drag on the inspector's edge hide it, under a
                    // pointer that promises a resize: View › Hide Inspector is the way to hide it.
                    .interactiveDismissDisabled()
                    // In the inspector's own part of the toolbar, so centred over the panel. Only
                    // while it shows: macOS keeps a hidden inspector's toolbar items in the toolbar.
                    .toolbar {
                        if showsSettings {
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
            }
            // The window's content, around the photo's column and the inspector's.
            .background(HostingViewName(name: "Editor"))
            .onChange(of: undoManager, initial: true) { _, undoManager in
                model.undoManager = undoManager
            }
            // For the View menu (``ViewCommands``).
            .focusedSceneValue(\.settingsCategory, $category)
            .focusedSceneValue(\.showsSettings, $showsSettings)
            .dropDestination(for: URL.self) { urls, _ in
                if let url = urls.first { model.open(url) }
            }
            // Photos sent by Finder's Open With and the Dock icon (the app's document types).
            .onOpenURL { url in model.open(url) }
        .fileExporter(isPresented: $model.isExportingLUT, item: model.lutFile, contentTypes: [PhotoModel.cubeType],
                      defaultFilename: model.lutFile?.title) { model.lutExported($0) }
        // The LUT panel's note, for it alone: the panels below are outside it.
        .fileDialogMessage(model.lutMessage)
        .fileExporter(isPresented: $model.isSavingPreset, item: model.presetFile, contentTypes: [.json],
                      defaultFilename: "\(model.filmName).json") { model.presetSaved($0) }
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
        .alert(model.failure?.title ?? "", isPresented: showsFailure, presenting: model.failure) { _ in
        } message: { failure in
            Text(failure.message)
        }
    }

    // The toolbar and the alert's binding are properties of their own: inside `body`, they took the
    // type checker 0.4 s and 0.3 s on every build (#292).

    /// The window's toolbar: what the canvas shows, centred, then the buttons.
    @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            ShowPicker()
        }
        // Crop is of a photo, so it's there once one is open: a group of its own, as it changes the
        // photo where the others open and send it. On, the canvas is in crop mode; off keeps the
        // crop.
        if model.photo != nil {
            ToolbarItem {
                // The toolbar sizes an item, and its glass, to the new width at once. So the button
                // has glass of its own, and while cropping the item is as wide as the button with
                // Done from the start: the button, at its right, grows to the left into it.
                ZStack(alignment: .trailing) {
                    if model.isCropping {
                        cropToggle(showsDone: true)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    cropToggle(showsDone: model.hasCropChanges)
                }
                // Not as crop mode ends, when the toolbar changes around it at once.
                .animation(model.isCropping ? .snappy(duration: 0.3) : nil, value: model.hasCropChanges)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
        }
        // While cropping, in place of Open, Save and Share, which wait for the crop: Reset, which
        // keeps all of the photo, and Cancel, which leaves the photo as it was. Both end crop mode.
        // In one group of glass, spaced as Print and Film are.
        if model.isCropping {
            ToolbarItem {
                HStack(spacing: 3) {
                    Button("Reset", role: .destructive) { model.resetCrop() }
                        .disabled(!model.canResetCrop)
                    Button("Cancel") { model.cancelCropping() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isLeavingCropMode)
                }
                .buttonStyle(ToolbarGroupButtonStyle())
                .padding(4)
                .glassEffect(in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup {
                Button("Open…", systemImage: "folder") { model.isImporting = true }
                Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                    .disabled(!model.canSave)
                shareButton
            }
        }
    }

    /// Crop in the toolbar, in glass, blue while cropping: on, the canvas is in crop mode; off keeps
    /// the crop. With Done beside the icon if `showsDone`: the one icon throughout, so as the
    /// button grows, the icon goes with its left edge while Done fades in.
    ///
    /// Its glass is drawn here rather than by a glass button style, whose padding is its own: the
    /// icon is at the toolbar's size in a square as high as the button, a circle without Done, and
    /// Done is as far from the edge as the toolbar's titles are.
    private func cropToggle(showsDone: Bool) -> some View {
        Toggle(isOn: Binding { model.isCropping } set: { crops in
            if crops { model.beginCropping() } else { model.endCropping() }
        }) {
            HStack(spacing: 0) {
                Image(systemName: "crop")
                    .imageScale(.large)
                    .frame(width: Self.toolbarButtonHeight, height: Self.toolbarButtonHeight)
                if showsDone {
                    // Once the button has grown, and gone before it shrinks.
                    Text("Done")
                        .padding(.trailing, 12.5)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.25)),
                                                removal: .identity))
                }
            }
            .foregroundStyle(model.isCropping ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(.capsule)
            .glassEffect(model.isCropping ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                         in: .capsule)
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(showsDone ? "Done" : "Crop")
        .disabled(!model.canCrop)
        .help(model.isCropping ? "Keep the crop" : "Crop the photo")
    }

    /// How tall the toolbar's buttons are.
    private static let toolbarButtonHeight: CGFloat = 36

    /// Whether the alert shows: while there's a failure, which dismissing it clears.
    private var showsFailure: Binding<Bool> {
        Binding { model.failure != nil } set: { shows in if !shows { model.failure = nil } }
    }

    /// Share: the finished photo, or a greyed-out button in its place without a photo, so the
    /// toolbar doesn't move as one opens.
    @ViewBuilder private var shareButton: some View {
        if let finished = model.finishedPhoto {
            ShareLink(item: finished, preview: SharePreview(finished.name))
        } else {
            Button("Share", systemImage: "square.and.arrow.up") {}
                .disabled(true)
        }
    }

    /// What the app is doing, else the last error (until a photo is opened), else what the canvas
    /// shows: under the window's title.
    private var status: String {
        if model.isLoading { return "Opening…" }
        if let phase = model.savePhase { return phase }
        // The size marked is on the crop's frame: here, each step of a drag would lay out the toolbar.
        if model.isCropping { return "Cropping" }
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

extension FocusedValues {
    /// The settings tab the window shows, and whether it shows the settings, for the View menu.
    @Entry var settingsCategory: Binding<SettingsCategory>?
    @Entry var showsSettings: Binding<Bool>?
    /// What the View menu's zoom commands do to the canvas, while it has a photo.
    @Entry var canvasZoom: CanvasZoom?
}

/// The canvas's zoom commands, each nil where it can't zoom that way.
struct CanvasZoom {
    let zoomIn: (() -> Void)?
    let zoomOut: (() -> Void)?
    let fit: (() -> Void)?
}

/// Print | Film, in a view of its own reading only what it shows (``PhotoModel/showsFilm``): the
/// controls change at every step of a slider, and read here or in the window's body they laid out
/// the toolbar again each time.
private struct ShowPicker: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        Picker("Show", selection: Binding { model.showsFilm } set: { model.controls.scanFilm = $0 }) {
            Text("Print").tag(false)
            Text("Film").tag(true)
        }
        .pickerStyle(.segmented)
        // A slide has no print, so the switch is greyed out on Film: a segment of its own greyed
        // out (`selectionDisabled`) looks no different in macOS 26's toolbar.
        .disabled(model.showsOriginal || model.isSlideFilm || model.isCropping)
        .help(model.isSlideFilm
              ? "A slide is viewed directly, so it has no print. Choose a negative film to see one printed."
              : "Print: the film printed on the paper. Film: the developed negative, or the slide itself.")
    }
}

/// Names, for assistive apps, the AppKit view SwiftUI hosts this part of a window in, from its
/// background. SwiftUI hosts a window's content, and each column of a split view such as the
/// inspector's, in an `NSHostingView`, which assistive apps see as a group. It had no name, so
/// VoiceOver said only "group" and the accessibility audit failed it, and no SwiftUI modifier
/// reaches it: they name views inside it (#310). AppKit's own label does.
private struct HostingViewName: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> Namer {
        let namer = Namer()
        namer.name = name
        return namer
    }

    func updateNSView(_ namer: Namer, context: Context) {}

    final class Namer: NSView {
        var name = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The nearest view above that assistive apps see: the hosting view.
            var view = superview
            while let ancestor = view, !ancestor.isAccessibilityElement() {
                view = ancestor.superview
            }
            view?.setAccessibilityLabel(name)
        }

        // Clicks, drops and scrolls go to what it's behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Canvas

/// The photo fitted to the canvas below the toolbar and beside the settings panel. Pinching (or
/// scrolling with ⌥) zooms around the pointer, scrolling or dragging moves the zoomed photo, as in
/// Preview; clicking shows the original in place of the edit (and the edit again), and
/// double-clicking shows all of it again. The View menu zooms too (``CanvasZoom``). The canvas
/// reaches under the toolbar and the panel, so a zoomed photo shows through them, as in Photos.
private struct ImageCanvas: View {
    @Environment(PhotoModel.self) private var model
    /// Magnification over the photo fitted to the canvas (1 shows all of it), and how far the
    /// zoomed photo is moved from the centre, in points.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// The canvas below the toolbar and beside the settings panel, in the canvas's coordinates: the
    /// photo is fitted and centred there.
    @State private var visibleArea = CGRect.zero
    /// Where the pointer is over the canvas below the toolbar and beside the panel: scrolling moves
    /// the photo under it, or zooms around it.
    @State private var pointer: CGPoint?
    /// The offset when the drag began, and the pinch's magnification so far.
    @State private var dragStart: CGSize?
    @State private var pinched: CGFloat = 1
    @State private var scrollMonitor: Any?
    /// In crop mode: the width over height of the shape the crop keeps to as it was chosen, if it
    /// has one (``PhotoModel/cropShape``).
    @State private var cropRatio: CGFloat?
    /// In crop mode, a drag moves the photo under a frame fixed in the middle, as in Photos, rather
    /// than the frame over the photo: as it was chosen last, while the app is open.
    @State private var cropMovesPhoto = false
    /// While a corner or edge of the frame is dragged with the photo moving: the part marked the
    /// canvas stays laid out around (``CropOverlay/held``).
    @State private var heldCrop: CGRect?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Takes the canvas below the toolbar and beside the panel, whose geometry gives where that
        // is, read as one value: its size and where it starts (the safe area's insets). The canvas
        // itself reaches under them. As the window opens and takes its saved size, macOS 26 lays the
        // toolbar out at 52, 42 and then 52 pt within one frame. Read alone, the insets repeat 52,
        // which SwiftUI takes for a loop: it stops calling the action, and the photo was fitted below
        // a 42-pt toolbar. The size changes with them, so the area doesn't repeat (#293).
        Color.clear
            .onGeometryChange(for: CGRect.self) { geometry in
                CGRect(origin: CGPoint(x: geometry.safeAreaInsets.leading, y: geometry.safeAreaInsets.top), size: geometry.size)
            } action: { area in
                visibleArea = area
                offset = clamped(offset)
            }
            .overlay { canvas.ignoresSafeArea(.container, edges: [.top, .trailing]) }
            // Over the canvas below the toolbar and beside the panel, so centred there.
            .overlay {
                if shownImage == nil {
                    if let failure = model.engineFailure {
                        ContentUnavailableView("Metal is unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text("SpektraMac simulates film on the graphics processor, through Metal. \(failure)."))
                    } else if model.isLoading || (model.photo != nil && model.errorMessage == nil) {
                        // A photo opening, or rendering for the first time: seconds for a RAW file.
                        ProgressView()
                            .controlSize(.large)
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
            // Saving's progress and Cancel, over the photo rather than in the toolbar, which would
            // move its other buttons to make room. The render is one pass on the GPU, with no
            // stages to count, so the spinner says only that it's working, and the text what.
            .overlay(alignment: .bottom) {
                if let phase = model.savePhase {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(phase)
                        Button("Cancel") { model.cancel() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect()
                    .padding(.bottom, 16)
                }
            }
            .overlay(alignment: .bottom) {
                if model.isCropping, let photo = model.photo {
                    cropControls(for: photo)
                }
            }
    }

    /// In crop mode, on the canvas over the foot of the photo, in glass as the toolbar's buttons
    /// are: what a drag moves, and the shapes to keep to. Reset and Cancel are in the toolbar.
    private func cropControls(for photo: PhotoModel.Photo) -> some View {
        // Glass near glass is drawn together.
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Picker("Drag", selection: $cropMovesPhoto.animation(.snappy(duration: 0.3))) {
                    Label("Move Frame", systemImage: "crop").tag(false)
                    Label("Move Photo", systemImage: "photo").tag(true)
                }
                .pickerStyle(.tabs)
                .controlSize(.extraLarge)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .fixedSize()
                .glassEffect()
                .help("Drag the frame over the photo, or the photo under the frame")
                cropShapes
            }
        }
        // Once the crop is kept, they wait with the frame for the engine's crop.
        .disabled(model.isLeavingCropMode)
        // Clear of the frame's foot where it's the photo's: its edge is held below them.
        .padding(.bottom, 24)
        .onChange(of: model.cropShape) {
            // The largest part of that shape in what's marked, about the same middle.
            let marked = model.cropSelection
            cropRatio = model.cropShape.ratio(of: marked.size, in: photo.wholeBounds.size)
            guard let cropRatio else { return }
            let width = min(marked.width, marked.height * cropRatio)
            model.cropSelection = CGRect(x: marked.midX - width / 2, y: marked.midY - width / cropRatio / 2,
                                         width: width, height: width / cropRatio)
        }
    }

    /// The crop's shapes in one group of glass, looking as the toolbar's Camera, Film and Print do:
    /// the shape chosen on a grey capsule.
    ///
    /// That look off the toolbar is the `.tabs` picker style at the toolbar's size: `.segmented`
    /// there has dividers and its choice in the accent colour. With `.tabs`, VoiceOver announces
    /// the shapes as tabs. Not a menu: a SwiftUI menu has no action for assistive apps to press on
    /// macOS 27, which fails the accessibility audit (#314).
    private var cropShapes: some View {
        Picker("Shape", selection: Binding { model.cropShape } set: { model.cropShape = $0 }) {
            ForEach(CropShape.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.tabs)
        .controlSize(.extraLarge)
        .labelsHidden()
        .fixedSize()
        .glassEffect()
    }

    private var canvas: some View {
        // A stack, not a group: without a photo, the canvas is still there to measure and to shade.
        ZStack {
            if let image = shownImage {
                // The reader takes the canvas's size and passes nothing back: a frame sized by the
                // photo would make that the window's minimum.
                GeometryReader { _ in
                    let shown = photoRect
                    Image(image, scale: 1, label: Text(photoDescription))
                        .resizable()
                        .interpolation(.high)
                        .overlay { meteringOverlay }
                        .overlay { burnOverlay }
                        .frame(width: shown.width, height: shown.height)
                        .position(x: shown.midX, y: shown.midY)
                    // On the canvas, not the photo, which moves under it as it's dragged.
                    if model.isCropping, let photo = model.photo {
                        CropOverlay(selection: Binding { model.cropSelection } set: { model.cropSelection = $0 },
                                    whole: photo.wholeBounds.size, photoFrame: shown, ratio: cropRatio,
                                    movesPhoto: cropMovesPhoto, held: $heldCrop)
                            .allowsHitTesting(!model.isLeavingCropMode)
                    }
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
                        // Pinched shut, the magnification reaches 0, and 0 over 0 would make the
                        // zoom not a number, the photo gone: until it's above 0 again, no change.
                        guard pinch.magnification > 0 else { return }
                        zoom(by: pinch.magnification / pinched, at: pinch.startLocation)
                        pinched = pinch.magnification
                    }
                    .onEnded { _ in pinched = 1 })
                // Each click of a double-click is a click too: it switches twice, so it ends on
                // the view it started from.
                .onTapGesture {
                    // In crop mode a click is on the photo to crop, or beside its frame.
                    guard !model.isCropping else { return }
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
                    case .active(let location) where visibleArea.contains(location):
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
        .onChange(of: model.photo?.id) {
            zoom = 1
            offset = .zero
        }
        // Crop mode shows all of the photo, starting at any shape, and a crop is a new photo to fit.
        .onChange(of: model.isCropping) {
            zoom = 1
            offset = .zero
            cropRatio = nil
            heldCrop = nil
        }
        .focusedSceneValue(\.canvasZoom, model.photo == nil || model.isCropping ? nil : CanvasZoom(
            zoomIn: zoom < maxZoom ? { zoom(by: 2, at: visibleCentre) } : nil,
            zoomOut: zoom > 1 ? { zoom(by: 0.5, at: visibleCentre) } : nil,
            fit: zoom > 1 ? { zoom = 1; offset = .zero } : nil))
        .onChange(of: fittedLongSide, initial: true) { _, pixels in
            model.canvasLongSide = pixels
        }
        .onChange(of: zoom > 1, initial: true) { _, wants in
            model.wantsFullResolution = wants
        }
    }

    /// What the canvas shows: the render, or the original while it's asked for, or while cropping,
    /// all of the original.
    private var shownImage: CGImage? {
        if model.isCropping {
            return model.wholeOriginal
        }
        guard let render = model.displayImage else { return nil }
        return model.showsOriginal ? model.original ?? render : render
    }

    /// Where all of the photo is on the canvas: fitted, zoomed and moved, or in crop mode, placed
    /// so the part it's laid out around fills a frame fitted in the middle.
    private var photoRect: CGRect {
        if let marked = cropLaidOutAround, let photo = model.photo, marked.width > 0 {
            let frame = Self.fitted(marked.size, in: visibleSize)
            let scale = frame.width / marked.width
            return CGRect(x: visibleCentre.x - marked.midX * scale, y: visibleCentre.y - marked.midY * scale,
                          width: photo.wholeBounds.width * scale, height: photo.wholeBounds.height * scale)
        }
        let fitted = fittedSize(in: visibleSize)
        return CGRect(x: visibleCentre.x + offset.width - fitted.width * zoom / 2,
                      y: visibleCentre.y + offset.height - fitted.height * zoom / 2,
                      width: fitted.width * zoom, height: fitted.height * zoom)
    }

    /// In crop mode, what the canvas is laid out around: all of the photo, or with the photo moving,
    /// the part marked, held while a corner or edge is dragged.
    private var cropLaidOutAround: CGRect? {
        guard model.isCropping, let photo = model.photo else { return nil }
        return cropMovesPhoto ? heldCrop ?? model.cropSelection : photo.wholeBounds
    }

    /// Zooms the photo under the crop's frame by `factor`, about the frame's middle: the part marked
    /// shrinks as the photo grows, staying in the photo, down to 4 points a pixel.
    private func zoomUnderFrame(by factor: CGFloat) {
        guard heldCrop == nil, let photo = model.photo else { return }
        let marked = model.cropSelection
        let whole = photo.wholeBounds.size
        let frame = Self.fitted(marked.size, in: visibleSize)
        guard marked.width > 0, frame.width > 0 else { return }
        let least = min(1, frame.width / 4 / marked.width)
        let most = min(whole.width / marked.width, whole.height / marked.height)
        let scale = min(max(1 / factor, least), most)
        let size = CGSize(width: marked.width * scale, height: marked.height * scale)
        model.cropSelection = CGRect(x: min(max(0, marked.midX - size.width / 2), whole.width - size.width),
                                     y: min(max(0, marked.midY - size.height / 2), whole.height - size.height),
                                     width: size.width, height: size.height)
    }

    /// The canvas below the toolbar and beside the panel.
    private var visibleSize: CGSize { visibleArea.size }

    private var visibleCentre: CGPoint {
        CGPoint(x: visibleArea.midX, y: visibleArea.midY)
    }

    /// While the pointer is on a mark's dot: the region that mark meters, tinted.
    @ViewBuilder private var meteringOverlay: some View {
        if let photo = model.photo {
            ZStack {
                ForEach(model.hoveredMarks, id: \.self) { mark in
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

    /// What VoiceOver reads for the photo: its name and what it shows.
    private var photoDescription: String {
        let name = model.photo?.name ?? "Photo"
        if model.showsOriginal || model.isCropping, model.original != nil {
            return "\(name), the original"
        }
        return model.showsFilm ? "\(name) on \(model.filmName)" : "\(name) on \(model.filmName), printed on \(model.paperName)"
    }

    /// The photo's size scaled to fit `size`, with a margin: the photo's own shape, whichever
    /// render is shown, so swapping renders can't move it.
    private func fittedSize(in size: CGSize) -> CGSize {
        guard let photo = model.photo else { return .zero }
        return Self.fitted(CGSize(width: photo.width, height: photo.height), in: size)
    }

    /// `content` scaled to fit `size`, with a margin.
    private static func fitted(_ content: CGSize, in size: CGSize) -> CGSize {
        let inset: CGFloat = 12
        let scale = max(0, min((size.width - 2 * inset) / content.width, (size.height - 2 * inset) / content.height))
        return CGSize(width: content.width * scale, height: content.height * scale)
    }

    /// The fitted photo's long side in screen pixels.
    private var fittedLongSide: Int {
        let fitted = fittedSize(in: visibleSize)
        return Int((max(fitted.width, fitted.height) * displayScale).rounded(.up))
    }

    /// The most the photo zooms: 4 points per photo pixel.
    private var maxZoom: CGFloat {
        let fitted = fittedSize(in: visibleSize)
        guard let photo = model.photo, fitted.width > 0 else { return 1 }
        return max(1, 4 * CGFloat(photo.width) / fitted.width)
    }

    /// Zooms by `factor`, keeping the photo's point under `anchor` (canvas coordinates) where it
    /// is: from all of the photo to ``maxZoom``.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        // Crop mode keeps all of the photo in sight, unless it moves under the frame.
        if model.isCropping {
            if cropMovesPhoto {
                zoomUnderFrame(by: factor)
            }
            return
        }
        guard fittedSize(in: visibleSize).width > 0 else { return }
        let newZoom = min(max(zoom * factor, 1), maxZoom)
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

/// A title in a group of buttons in the toolbar, on a capsule under the pointer as the toolbar's
/// own are: grey, or for a button that throws something away, a faint red with the title red.
///
/// Drawn here: the toolbar's own group of buttons (`ControlGroup`) has its hover grey whatever a
/// button's role or tint, and its spacing its own. SwiftUI has no hover effects on macOS.
private struct ToolbarGroupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Title(configuration: configuration)
    }

    private struct Title: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let isLit = isEnabled && (isHovered || configuration.isPressed)
            let isDestructive = configuration.role == .destructive
            configuration.label
                .foregroundStyle(isLit && isDestructive ? AnyShapeStyle(.red)
                                 : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                // As far from the capsule's ends as Print and Film's titles are from theirs.
                .padding(.horizontal, 9.5)
                .frame(height: 28)
                .background {
                    if isLit {
                        Capsule()
                            .fill(isDestructive ? AnyShapeStyle(.red.opacity(0.15)) : AnyShapeStyle(.quaternary))
                            .opacity(configuration.isPressed ? 0.8 : 1)
                    }
                }
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Log

struct LogView: View {
    /// How much SpektraMac worked the Mac over one second (``LogView/sampleUsage()``).
    struct Usage: Identifiable {
        var id: Date { time }
        let time: Date
        /// The app's processor time, as a share of all the cores' time.
        let cpu: Double
        /// The GPU time of the engine's own command buffers, as a share of the second.
        let gpu: Double
    }

    @Environment(PhotoModel.self) private var model
    /// The last minute's, while the window is open.
    @State private var usage: [Usage] = []

    var body: some View {
        VStack(spacing: 0) {
            usageGraph
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.log) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            // In the primary colour, as the message: at the caption's size, the
                            // secondary falls short of the audit's contrast in light mode.
                            Text(entry.time, format: .dateTime.hour().minute().second())
                            Text(entry.message)
                                .textSelection(.enabled)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
                // An element of its own to assistive apps, named, as each line's is in it (#311).
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Messages")
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
        }
        // The window's content: a group to assistive apps, named as the window (#311).
        .background(HostingViewName(name: "Log"))
        .task { await sampleUsage() }
    }

    /// The CPU and GPU use over the last minute, as lines; one element for VoiceOver, which reads
    /// the last second's.
    private var usageGraph: some View {
        let end = usage.last?.time ?? .now
        let percent = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))
        return Chart(usage) { second in
            LineMark(x: .value("Time", second.time), y: .value("Use", second.cpu))
                .foregroundStyle(by: .value("Processor", "CPU"))
            LineMark(x: .value("Time", second.time), y: .value("Use", second.gpu))
                .foregroundStyle(by: .value("Processor", "GPU"))
        }
        .chartXScale(domain: end.addingTimeInterval(-60)...end)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1]) {
                AxisGridLine()
                AxisValueLabel(format: percent)
            }
        }
        .frame(height: 80)
        .accessibilityElement(children: .ignore)
        // A role, which the accessibility audit wants: one item, read as a picture of the lines.
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("CPU and GPU use over the last minute")
        .accessibilityValue(usage.last.map { "CPU \($0.cpu.formatted(percent)), GPU \($0.gpu.formatted(percent))" } ?? "")
    }

    /// Adds a second's use to ``usage`` each second until the window closes, keeping a minute's.
    /// The CPU's is the process's processor time on all its threads (`CLOCK_PROCESS_CPUTIME_ID`);
    /// the GPU's, the engine's command buffers' (``PhotoModel/gpuSeconds``), as macOS has no
    /// public figure for one app's GPU use.
    private func sampleUsage() async {
        func cpuSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e9 }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        var last = (time: ContinuousClock.now, cpu: cpuSeconds(), gpu: model.gpuSeconds)
        while true {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let now = (time: ContinuousClock.now, cpu: cpuSeconds(), gpu: model.gpuSeconds)
            let seconds = (now.time - last.time) / .seconds(1)
            usage.append(Usage(time: .now, cpu: (now.cpu - last.cpu) / seconds / cores, gpu: (now.gpu - last.gpu) / seconds))
            let minuteAgo = Date.now.addingTimeInterval(-60)
            usage.removeAll { $0.time < minuteAgo }
            last = now
        }
    }
}
