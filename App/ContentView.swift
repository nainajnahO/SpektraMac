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
                // The toolbar sizes an item, and its glass, to the new width at once. So the buttons
                // have glass of their own, and while cropping the item is as wide as they are with
                // Done from the start: Crop, at its right, grows to the left into it, and Rotate Left
                // beside it moves along. As toolbar items of their own, Rotate Left stood apart from
                // Crop by the width kept for Done.
                ZStack(alignment: .trailing) {
                    if model.isCropping {
                        HStack(spacing: Self.toolbarGlassSpacing) {
                            rotateLeftButton
                            cropToggle(showsDone: true)
                        }
                        .hidden()
                        .accessibilityHidden(true)
                    }
                    HStack(spacing: Self.toolbarGlassSpacing) {
                        if model.isCropping {
                            rotateLeftButton
                        }
                        // C as well as the Image menu's ⌘K, as in Photos: a menu item has one
                        // shortcut.
                        cropToggle(showsDone: model.hasCropChanges)
                            .keyboardShortcut("c", modifiers: [])
                    }
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

    /// While cropping, beside Crop: the photo turns as marked. The Image menu turns it either way, in
    /// crop mode or not. In glass of its own, a circle as Crop is without Done (``cropToggle(showsDone:)``).
    private var rotateLeftButton: some View {
        Button {
            model.turn(left: 1)
        } label: {
            Image(systemName: "rotate.left")
                .imageScale(.large)
                .frame(width: Self.toolbarButtonHeight, height: Self.toolbarButtonHeight)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rotate Left")
        .disabled(!model.canTurn)
        .help("Turn the photo a quarter to the left")
    }

    /// How tall the toolbar's buttons are.
    private static let toolbarButtonHeight: CGFloat = 36
    /// How far apart the toolbar puts groups of buttons in glass of their own.
    private static let toolbarGlassSpacing: CGFloat = 8

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
    /// In crop mode, a drag moves the photo under a frame fixed in the middle, as in Photos, rather
    /// than the frame over the photo: as it was chosen last, while the app is open.
    @State private var cropMovesPhoto = false
    /// While a corner or edge of the frame is dragged with the photo moving: the part marked the
    /// canvas stays laid out around (``CropOverlay/held``).
    @State private var heldCrop: CGRect?
    /// In crop mode, the straightening tape the pointer is over: scrolling there turns the photo.
    @State private var tapeUnderPointer: HorizontalEdge?
    /// While a trackpad's scroll over a tape is under way: the angle as it began, and the degrees
    /// scrolled since.
    @State private var scrollStraightening: (start: Double, degrees: Double)?
    /// How bright all of the original is, where, for the tapes: read once it's there.
    @State private var originalBrightness: Brightness?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

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
                if model.isCropping {
                    cropControls
                }
            }
            // A tape at each side, clear of the frame's edges where they're the photo's, and of the
            // controls below.
            .overlay {
                if model.isCropping {
                    let height = min(280, max(120, visibleSize.height - 200))
                    HStack {
                        StraighteningRuler(side: .leading, height: height, isPrimary: true,
                                           brightness: brightness(underTapeOn: .leading, height: height),
                                           tapeUnderPointer: $tapeUnderPointer)
                        Spacer()
                        StraighteningRuler(side: .trailing, height: height, isPrimary: false,
                                           brightness: brightness(underTapeOn: .trailing, height: height),
                                           tapeUnderPointer: $tapeUnderPointer)
                    }
                    .padding(.horizontal, StraighteningRuler.inset)
                    .disabled(model.isLeavingCropMode)
                }
            }
            .task(id: model.wholeOriginal.map(ObjectIdentifier.init)) {
                originalBrightness = nil
                guard let whole = model.wholeOriginal else { return }
                originalBrightness = await Task.detached(priority: .userInitiated) { Brightness(of: whole) }.value
            }
            // A scroll that leaves the tape before it ends ends there: the grid goes.
            .onChange(of: tapeUnderPointer) {
                if scrollStraightening != nil {
                    scrollStraightening = nil
                    model.endStraightening()
                }
            }
            // A click on the trackpad at each tenth of a degree a drag or scroll of a tape passes,
            // a rumble as it goes, and a firmer one at 0° and every 10°, as the settings' sliders
            // click at their lines. A Mac's trackpad plays only these two, so a whole degree clicks
            // as a tenth does. Not as Auto or a double-click sets the angle.
            .sensoryFeedback(trigger: model.markedFraming.angle) { old, new in
                guard model.isStraightening else { return nil }
                let passed = { (degree: Int) in
                    (old < Double(degree) && Double(degree) <= new) || (new <= Double(degree) && Double(degree) < old)
                }
                let degrees = Int(min(old, new).rounded(.down))...Int(max(old, new).rounded(.up))
                if degrees.contains(where: { $0.isMultiple(of: 10) && passed($0) }) { return .levelChange }
                // As at the exposure's dots, the firmer one at the horizon's.
                if let horizon = model.horizonAngle, (old < horizon && horizon <= new) || (new <= horizon && horizon < old) {
                    return .levelChange
                }
                // Each change of the angle is a tenth or more: it's to a tenth.
                return .alignment
            }
    }

    /// In crop mode, on the canvas over the foot of the photo, in glass as the toolbar's buttons
    /// are: what a drag moves, and the shapes to keep to. The straightening tapes are at the
    /// canvas's sides; Rotate, Reset and Cancel are in the toolbar.
    private var cropControls: some View {
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
    }

    /// The crop's shapes in one group of glass, looking as the toolbar's Camera, Film and Print do:
    /// the shape chosen on a grey capsule.
    ///
    /// That look off the toolbar is the `.tabs` picker style at the toolbar's size: `.segmented`
    /// there has dividers and its choice in the accent colour. With `.tabs`, VoiceOver announces
    /// the shapes as tabs. Not a menu: a SwiftUI menu has no action for assistive apps to press on
    /// macOS 27, which fails the accessibility audit (#314).
    private var cropShapes: some View {
        Picker("Shape", selection: Binding { model.cropShape } set: { model.chooseCropShape($0) }) {
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
                    // In crop mode, all of the original turned and straightened as marked: laid out
                    // unturned about the middle of where it lies turned.
                    let framing = model.isCropping ? model.markedFraming : .whole
                    let unturned = framing.quarterTurns.isMultiple(of: 2) ? shown.size : CGSize(width: shown.height, height: shown.width)
                    Image(image, scale: 1, label: Text(photoDescription))
                        .resizable()
                        .interpolation(.high)
                        .overlay { meteringOverlay }
                        .overlay { burnOverlay }
                        .frame(width: unturned.width, height: unturned.height)
                        .rotationEffect(.degrees(framing.angle - 90 * Double(framing.quarterTurns)))
                        .position(x: shown.midX, y: shown.midY)
                    // On the canvas, not the photo, which moves under it as it's dragged.
                    if model.isCropping {
                        CropOverlay(selection: Binding { model.cropSelection } set: { model.cropSelection = $0 },
                                    whole: model.cropBounds.size, angle: model.markedFraming.angle, photoFrame: shown,
                                    ratio: model.cropRatio, movesPhoto: cropMovesPhoto,
                                    showsFineGrid: model.isStraightening, held: $heldCrop)
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
                        if let tapeUnderPointer, model.isCropping {
                            straighten(byScrolling: event, on: tapeUnderPointer)
                            return nil
                        }
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
        if let marked = cropLaidOutAround, marked.width > 0 {
            let frame = Self.fitted(marked.size, in: visibleSize)
            let scale = frame.width / marked.width
            let bounds = model.cropBounds
            return CGRect(x: visibleCentre.x - marked.midX * scale, y: visibleCentre.y - marked.midY * scale,
                          width: bounds.width * scale, height: bounds.height * scale)
        }
        let fitted = fittedSize(in: visibleSize)
        return CGRect(x: visibleCentre.x + offset.width - fitted.width * zoom / 2,
                      y: visibleCentre.y + offset.height - fitted.height * zoom / 2,
                      width: fitted.width * zoom, height: fitted.height * zoom)
    }

    /// How bright the canvas is under the straightening tape on `side`, `height` high, from 0 to 1:
    /// the photo as crop mode shows it, darker outside the frame where it's dimmed, and the canvas
    /// beside it. Read at a few points over the tape.
    private func brightness(underTapeOn side: HorizontalEdge, height: CGFloat) -> Double {
        // Mid grey until the photo's brightness is there: the tape stays white.
        guard let originalBrightness else { return 0.5 }
        let shown = photoRect
        let framing = model.markedFraming
        let unturned = framing.quarterTurns.isMultiple(of: 2) ? shown.size : CGSize(width: shown.height, height: shown.width)
        // Back from where the canvas turns the photo to (`rotationEffect`) to where it lies unturned.
        let radians = -(framing.angle - 90 * Double(framing.quarterTurns)) * .pi / 180
        let (cos, sin) = (Foundation.cos(radians), Foundation.sin(radians))
        let scale = shown.width / model.cropBounds.width
        let selection = model.cropSelection
        let frame = CGRect(x: shown.minX + selection.minX * scale, y: shown.minY + selection.minY * scale,
                           width: selection.width * scale, height: selection.height * scale)
        // The canvas's grey: the window's background, a little darker.
        let canvas = colorScheme == .dark ? 0.2 : 0.85
        let width = StraighteningRuler.width
        let tape = CGRect(x: side == .leading ? visibleArea.minX + StraighteningRuler.inset
                                              : visibleArea.maxX - StraighteningRuler.inset - width,
                          y: visibleArea.midY - height / 2, width: width, height: height)
        let (columns, rows) = (4, 12)
        var total = 0.0
        for column in 0..<columns {
            for row in 0..<rows {
                let point = CGPoint(x: tape.minX + tape.width * (Double(column) + 0.5) / Double(columns),
                                    y: tape.minY + tape.height * (Double(row) + 0.5) / Double(rows))
                let (x, y) = (point.x - shown.midX, point.y - shown.midY)
                let onPhoto = CGPoint(x: (x * cos - y * sin) / unturned.width + 0.5, y: (x * sin + y * cos) / unturned.height + 0.5)
                if let value = originalBrightness.at(onPhoto) {
                    // The dimming's black at 60 %.
                    total += frame.contains(point) ? value : value * 0.4
                } else {
                    total += canvas
                }
            }
        }
        return total / Double(columns * rows)
    }

    /// In crop mode, what the canvas is laid out around: all of the photo turned as marked, or with
    /// the photo moving, the part marked, held while a corner or edge is dragged.
    private var cropLaidOutAround: CGRect? {
        guard model.isCropping else { return nil }
        return cropMovesPhoto ? heldCrop ?? model.cropSelection : model.cropBounds
    }

    /// Turns the photo by a scroll over the straightening tape on `side`, as dragging the tape does:
    /// a trackpad's scroll as one drag, from the angle as it began, with the fine grid; a mouse's
    /// wheel, which has no such start and end, from where the photo is, a tenth of a degree a line. A
    /// trackpad's momentum after the fingers lift is left out, so the photo stops turning with them.
    private func straighten(byScrolling event: NSEvent, on side: HorizontalEdge) {
        guard !model.isLeavingCropMode, event.momentumPhase.isEmpty else { return }
        // Degrees down the tape.
        let down = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / StraighteningRuler.scrollSpacing
                                                   : event.scrollingDeltaY / 10
        let degrees = down * StraighteningRuler.turn(on: side)
        guard !event.phase.isEmpty else {
            model.straighten(to: model.markedFraming.angle + degrees)
            return
        }
        if event.phase.contains(.began) || scrollStraightening == nil {
            scrollStraightening = (model.markedFraming.angle, 0)
            model.beginStraightening()
        }
        if var scroll = scrollStraightening {
            scroll.degrees += degrees
            scrollStraightening = scroll
            model.straighten(to: scroll.start + scroll.degrees)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollStraightening = nil
            model.endStraightening()
        }
    }

    /// Zooms the photo under the crop's frame by `factor`, about the frame's middle: the part marked
    /// shrinks as the photo grows, staying in the photo, down to 4 points a pixel.
    private func zoomUnderFrame(by factor: CGFloat) {
        guard heldCrop == nil else { return }
        let marked = model.cropSelection
        let frame = Self.fitted(marked.size, in: visibleSize)
        guard marked.width > 0, frame.width > 0 else { return }
        let scale = max(1 / factor, min(1, frame.width / 4 / marked.width))
        let size = CGSize(width: marked.width * scale, height: marked.height * scale)
        model.cropSelection = model.straightenedPhoto.fitted(CGRect(x: marked.midX - size.width / 2, y: marked.midY - size.height / 2,
                                                                    width: size.width, height: size.height))
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

/// Straightening in crop mode, as a fighter's head-up display shows its speed and height: an
/// upright tape of degrees in fine lines on the photo, one at each side of the canvas, its ticks
/// reaching out from a spine, which isn't drawn, toward the photo's middle. It turns, as the edge
/// of a wheel, past a needle with the angle beside it as it's dragged or scrolled over: down the
/// right tape, the degrees above come to the needle, turning the photo to the right, and down the
/// left one, to the left. A double-click straightens it to 0°. Beside the spine, as the
/// exposure's strip has the metering marks' dots, is a
/// dot at the angle that levels the horizon Vision finds: a click on it straightens the photo
/// there, and with the pointer on it, the same bubble as theirs says what it is, opening towards
/// the photo. With Full Keyboard Access the arrow keys step the primary tape a tenth of a degree,
/// and accessibility finds an upright slider in its place (``SliderElement``), stepping it a degree,
/// with an action for the horizon; the other is the same again, so they leave it out.
///
/// Drawn here: SwiftUI and AppKit have no ruler, tape or dial, and AppKit's slider stood upright has
/// a knob that moves along a track, with no numbers on its scale.
private struct StraighteningRuler: View {
    @Environment(PhotoModel.self) private var model
    /// The side of the canvas it's on.
    let side: HorizontalEdge
    /// How tall the tape is.
    let height: CGFloat
    /// The one the keyboard and assistive apps reach.
    let isPrimary: Bool
    /// How bright the canvas is under it, from 0 to 1.
    let brightness: Double
    /// The tape the pointer is over, this one or the other: the canvas turns scrolling there into
    /// turns of the photo.
    @Binding var tapeUnderPointer: HorizontalEdge?
    /// Drawn in black with a white shadow, over a bright photo, rather than white with a black one.
    @State private var isOnBright = false
    /// The angle as the drag began.
    @State private var dragStart: Double?
    /// The pointer is on the horizon's dot.
    @State private var isOnDot = false

    /// Points to a degree at the tape's middle, and of a drag, which the tape follows there.
    static let spacing: CGFloat = 8
    /// Points of a trackpad's scroll to a degree: five times a drag's, so a short scroll reaches
    /// tenths of a degree, the tape sliding slower than the fingers.
    static let scrollSpacing: CGFloat = 40
    static let width: CGFloat = 96
    /// How far in from the canvas's sides the tapes are.
    static let inset: CGFloat = 32
    /// How far in from the tape's inner edge its spine is: room for the ticks centred on it, and
    /// the dot.
    private static let spineInset: CGFloat = 8
    /// How far from the dot's middle, in points, the pointer is on it: the dot is 6 across.
    private static let dotReach: CGFloat = 8

    /// Which way a degree down the tape on `side` turns the photo: 1 to the right, −1 to the left.
    /// The tapes move as the photo's edges beside them do, as if they were the two sides of one
    /// wheel: turned to the right, its right edge goes down and its left edge up.
    static func turn(on side: HorizontalEdge) -> Double {
        side == .leading ? -1 : 1
    }

    /// Which way a degree down this tape turns the photo (``turn(on:)``).
    private var turn: Double { Self.turn(on: side) }

    var body: some View {
        let angle = model.markedFraming.angle
        let degrees = "\(angle.formatted(.number.precision(.fractionLength(1))))°"
        ZStack(alignment: .topLeading) {
            // Both, one faded in over the other as the photo under it turns bright or dark.
            tape(at: angle, ink: .white, shadow: .black.opacity(0.6))
                .opacity(isOnBright ? 0 : 1)
            tape(at: angle, ink: .black, shadow: .white.opacity(0.7))
                .opacity(isOnBright ? 1 : 0)
            needle(reading: degrees)
            if let dot = dotCentre(at: angle), let horizon = model.horizonAngle {
                horizonDot(isOn: abs(angle - horizon) < 0.05)
                    .position(dot)
            }
        }
            .animation(.easeInOut(duration: 0.25), value: isOnBright)
            // A little either side of the middle, so it doesn't flicker as the photo turns under
            // it with its brightness there.
            .onChange(of: brightness, initial: true) { _, brightness in
                if brightness > 0.65 {
                    isOnBright = true
                } else if brightness < 0.55 {
                    isOnBright = false
                }
            }
            .frame(width: Self.width, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let start = dragStart ?? angle
                    if dragStart == nil {
                        dragStart = start
                        model.beginStraightening()
                    }
                    model.straighten(to: start + turn * drag.translation.height / Self.spacing)
                }
                .onEnded { _ in
                    dragStart = nil
                    model.endStraightening()
                })
            // Each click of a double-click is a click too: the first may be on the dot. Where the
            // click is, rather than the hover: a scroll can slide the dot under a still pointer.
            .onTapGesture { location in
                if NSApp.currentEvent?.clickCount == 2 {
                    model.straighten(to: 0)
                } else if isOnDot(location, at: angle) {
                    model.straightenByHorizon()
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if tapeUnderPointer != side {
                        tapeUnderPointer = side
                    }
                    let isOn = isOnDot(location, at: angle)
                    if isOn != isOnDot {
                        isOnDot = isOn
                    }
                case .ended:
                    if tapeUnderPointer == side {
                        tapeUnderPointer = nil
                    }
                    isOnDot = false
                }
            }
            .pointerStyle(isOnDot ? .link : dragStart == nil ? .grabIdle : .grabActive)
            .focusable(isPrimary, interactions: .activate)
            // As a drag up or down the tape would.
            .onMoveCommand { direction in
                switch direction {
                case .up: model.straighten(to: angle - turn * 0.1)
                case .down: model.straighten(to: angle + turn * 0.1)
                default: break
                }
            }
            .accessibilityHidden(true)
            .background {
                if isPrimary {
                    SliderElement(title: "Straighten", value: angle, range: -45...45, valueText: "\(degrees) to the right",
                                  set: { model.straighten(to: $0) }, move: { model.straighten(to: angle + ($0 ? 1 : -1)) },
                                  orientation: .vertical)
                        .accessibilityActions {
                            if model.horizonAngle != nil {
                                Button(Self.horizon.name) { model.straightenByHorizon() }
                            }
                        }
                }
            }
            .help("Drag or scroll to straighten the photo; double-click for 0°")
    }

    /// What the horizon's dot stands for, in its bubble.
    private static let horizon = (systemImage: "level", name: "Horizon",
                                  about: "levels the horizon Vision finds in the photo")

    /// Where the horizon's dot is beside the spine, with the tape at `angle`: none until Vision has
    /// found it, or where it's faded out at the tape's ends.
    private func dotCentre(at angle: Double) -> CGPoint? {
        guard let horizon = model.horizonAngle, let y = place(of: horizon, at: angle)?.y else { return nil }
        guard y > height * 0.15, y < height * 0.85 else { return nil }
        // Beside the spine, on the numbers' side, clear of the ticks.
        let beside = Self.spineInset + 14
        return CGPoint(x: side == .leading ? Self.width - beside : beside, y: y)
    }

    /// `location`, in the tape, is on the horizon's dot, with the tape at `angle`.
    private func isOnDot(_ location: CGPoint, at angle: Double) -> Bool {
        dotCentre(at: angle).map { hypot($0.x - location.x, $0.y - location.y) <= Self.dotReach } ?? false
    }

    /// The horizon's dot, in the accent colour while the photo is straightened there, and its bubble
    /// with the pointer on it, opening towards the photo.
    private func horizonDot(isOn: Bool) -> some View {
        let size: CGFloat = isOnDot ? 8 : 6
        let towardsPhoto: Edge = side == .leading ? .trailing : .leading
        return Circle()
            .fill(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(isOnBright ? .black : .white))
            .shadow(color: isOnBright ? .white.opacity(0.7) : .black.opacity(0.6), radius: 1)
            .frame(width: size, height: size)
            .popover(isPresented: Binding { isOnDot && dragStart == nil } set: { isPresented in
                if !isPresented {
                    isOnDot = false
                }
            }, attachmentAnchor: .point(towardsPhoto == .trailing ? .trailing : .leading), arrowEdge: towardsPhoto) {
                DotBubble(items: [Self.horizon])
                    // It follows the pointer: a click outside it is for the tape.
                    .interactiveDismissDisabled()
            }
    }

    /// A tick every degree, centred on the spine, longer every 5 and numbered every 10, on the edge
    /// of a wheel (``place(of:at:)``): they close up and fade toward the tape's ends, the numbers
    /// squashed. Fine lines in `ink`, with a `shadow` to show where the photo is as light or dark as
    /// they are. The degrees to the right run up the right tape and down the left one.
    private func tape(at angle: Double, ink: Color, shadow: Color) -> some View {
        Canvas { context, size in
            // Outwards from the spine, which faces the photo's middle.
            let outwards: CGFloat = side == .leading ? -1 : 1
            let spine = side == .leading ? size.width - Self.spineInset : Self.spineInset
            let x = { (offset: CGFloat) in spine + outwards * offset }
            let anchor: UnitPoint = side == .leading ? .trailing : .leading
            let middle = size.height / 2
            context.addFilter(.shadow(color: shadow, radius: 1))
            for degree in -45...45 {
                guard let spot = place(of: Double(degree), at: angle) else { continue }
                let length: CGFloat = degree.isMultiple(of: 10) ? 12 : degree.isMultiple(of: 5) ? 8 : 4
                var tick = Path()
                tick.move(to: CGPoint(x: x(-length / 2), y: spot.y))
                tick.addLine(to: CGPoint(x: x(length / 2), y: spot.y))
                context.stroke(tick, with: .color(ink.opacity(spot.facing)), lineWidth: 0.75)
                // Not beside the needle's reading, nor turned almost out of sight.
                if degree.isMultiple(of: 10), abs(spot.y - middle) > 20, spot.facing > 0.1 {
                    var label = context
                    label.opacity = spot.facing
                    label.translateBy(x: x(12), y: spot.y)
                    label.scaleBy(x: 1, y: spot.facing)
                    label.draw(Text(degree.formatted()).font(.system(size: 11, design: .monospaced)).foregroundStyle(ink),
                               at: .zero, anchor: anchor)
                }
            }
        }
    }

    /// A needle across the tape's middle in yellow, as the Camera app on iPhone marks its setting,
    /// and `degrees` beside it, with a dark shadow to show on a bright photo. Drawn once over both
    /// of the tape's inks.
    private func needle(reading degrees: String) -> some View {
        Canvas { context, size in
            // Outwards from the spine.
            let outwards: CGFloat = side == .leading ? -1 : 1
            let spine = side == .leading ? size.width - Self.spineInset : Self.spineInset
            let x = { (offset: CGFloat) in spine + outwards * offset }
            let middle = size.height / 2
            context.addFilter(.shadow(color: .black.opacity(0.6), radius: 1))
            var needle = Path()
            needle.move(to: CGPoint(x: x(-8), y: middle))
            needle.addLine(to: CGPoint(x: x(14), y: middle))
            context.stroke(needle, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.draw(Text(degrees).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.yellow),
                         at: CGPoint(x: x(20), y: middle), anchor: side == .leading ? .trailing : .leading)
        }
    }

    /// Where `degree` is down the tape, with the tape at `angle`, and how far it faces out of the
    /// screen, from 1 at the middle toward 0. The tape is the edge of a wheel as tall as it is: the
    /// degrees close up and turn away toward its ends, and past them are out of sight (nil). A drag
    /// or scroll keeps up with them only at the middle.
    private func place(of degree: Double, at angle: Double) -> (y: CGFloat, facing: CGFloat)? {
        let radius = height / 2
        let turned = turn * (degree - angle) * Self.spacing / radius
        guard abs(turned) < .pi / 2 else { return nil }
        return (radius - radius * sin(turned), cos(turned))
    }
}

/// How bright a photo is, where: drawn into a grey image at most 128 pixels on its long side, read
/// at a point for the straightening tapes, many times a second while the photo turns under them.
/// Core Image's area average (`CIAreaAverage`) reads a part of the photo itself, a render each
/// time; and SwiftUI can't say how bright what's behind a view is. Read away from the main actor.
nonisolated private struct Brightness {
    private let width: Int
    private let height: Int
    /// Rows from the top, as a bitmap context keeps them.
    private let values: [UInt8]

    init?(of image: CGImage) {
        let scale = min(1, 128 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var values = [UInt8](repeating: 0, count: width * height)
        let drawn = values.withUnsafeMutableBytes { pixels in
            guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
                  let context = CGContext(data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        (self.width, self.height, self.values) = (width, height, values)
    }

    /// At `point`, measured from the top left as a fraction of the photo across and down: from 0
    /// to 1, or nil off the photo.
    func at(_ point: CGPoint) -> Double? {
        guard (0..<1).contains(point.x), (0..<1).contains(point.y) else { return nil }
        return Double(values[Int(point.y * Double(height)) * width + Int(point.x * Double(width))]) / 255
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
