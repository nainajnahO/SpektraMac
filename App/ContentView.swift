import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PhotoModel.self) private var model
    @State private var showLog = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            // Toolbar, inspector and status bar belong to the detail column. Attaching them
            // to the split view itself spans them across the sidebar and loses the
            // full-height floating sidebar treatment.
            ImageCanvas()
                .safeAreaInset(edge: .bottom) { StatusBar() }
                .navigationTitle(model.photo?.name ?? "SpektraMac")
                .toolbar {
                    ToolbarItemGroup(placement: .principal) {
                        Picker("Show", selection: $model.controls.scanFilm) {
                            Text("Print").tag(false)
                                .selectionDisabled(model.isSlideFilm)
                            Text("Film").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .help("Print: the film printed on the paper. Film: the developed negative, or the slide itself.")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Open…", systemImage: "folder") { model.isImporting = true }
                        if model.canCancel {
                            Button("Cancel", systemImage: "xmark.circle") { model.cancel() }
                        }
                        Button("Save…", systemImage: "square.and.arrow.down") { model.save() }
                            .disabled(!model.canSave)
                        Toggle("Log", systemImage: "list.bullet.rectangle", isOn: $showLog)
                    }
                }
                // The canvas doesn't scroll under the toolbar, so the window would otherwise
                // draw a hard separator line beneath it.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .inspector(isPresented: $showLog) {
                    LogView()
                        .inspectorColumnWidth(min: 260, ideal: 340)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    model.open(url)
                    return true
                }
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): model.open(url)
            case .failure(let error): model.importFailed(error)
            }
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Simulation") {
                Picker("Film", selection: $model.film) {
                    StockSections(stocks: model.films)
                }
                Picker("Paper", selection: $model.controls.paper) {
                    StockSections(stocks: model.papers)
                }
                .disabled(model.controls.scanFilm)
            }
            Section("Exposure") {
                ExposureSlider()
            }
            Section("Enlarger") {
                ValueSlider("Print exposure", value: $model.controls.printExposure, in: 0...2, step: 0.02,
                            format: .number.precision(.fractionLength(2)))
                ValueSlider("Y filter shift", value: $model.controls.yFilterShift, in: -100...100, step: 1,
                            format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                            unit: "CC")
                ValueSlider("M filter shift", value: $model.controls.mFilterShift, in: -100...100, step: 1,
                            format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                            unit: "CC")
            }
            .disabled(model.controls.scanFilm)
            Section("Effects") {
                Toggle("Grain", isOn: $model.controls.grain)
                Toggle("Halation", isOn: $model.controls.halation)
            }
        }
        .formStyle(.grouped)
    }
}

/// A film or paper menu's stocks under headings, from their profiles: slides, still negatives or
/// papers, then cine stocks.
private struct StockSections: View {
    let stocks: [ProfileInfo]

    var body: some View {
        let groups = Dictionary(grouping: stocks) { stock -> String in
            if stock.type == .positive { return "Slide" }
            if stock.use == .cine { return "Cine" }
            return stock.stage == .filming ? "Negative" : "Still"
        }
        ForEach(["Slide", "Negative", "Still", "Cine"].filter { groups[$0] != nil }, id: \.self) { heading in
            Section(heading) {
                ForEach(groups[heading]!, id: \.stock) { Text($0.name).tag($0.stock) }
            }
        }
    }
}

/// The exposure, in stops over the photo as shot. Its dots are where each way of metering puts
/// it for this photo (``MeteringMark``); a mark's name shows only while the slider is on it, so
/// marks a fraction of a stop apart don't crowd, and the trackpad clicks as it lands on one.
private struct ExposureSlider: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let readings = model.photo.map { photo in
            MeteringMark.allCases.compactMap { mark in photo.metering.ev[mark.rawValue].map { (mark: mark, ev: $0) } }
        } ?? []
        let here = model.marksAtExposure
        let range = range(readings.map(\.ev) + [model.exposureEV])
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Exposure") {
                Text("\(model.exposureEV.formatted(Self.stops)) EV").monospacedDigit()
            }
            Slider(value: $model.exposureEV, in: range) {
                Text("Exposure")
            } ticks: {
                SliderTickContentForEach(Set(readings.map(\.ev)).sorted(), id: \.self) { SliderTick($0) }
            } onEditingChanged: { model.isAdjustingExposure = $0 }
            .labelsHidden()
            .sensoryFeedback(.alignment, trigger: here) { _, new in model.isAdjustingExposure && !new.isEmpty }
            MarkName(name: here.map(\.name).formatted(.list(type: .and)),
                     fraction: (model.exposureEV - range.lowerBound) / (range.upperBound - range.lowerBound))
            Text(description(here: here))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.photo == nil)
    }

    private static let stops = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        .sign(strategy: .always(includingZero: false))

    /// −4…+8 stops, widened to whole stops past any reading outside it.
    private func range(_ values: [Double]) -> ClosedRange<Double> {
        min(-4, (values.min() ?? 0).rounded(.down) - 1)...max(8, (values.max() ?? 0).rounded(.up) + 1)
    }

    /// What the mark the slider is on meters, or how far it is from the nearest one.
    private func description(here: [MeteringMark]) -> String {
        guard let photo = model.photo else {
            return "\(model.controls.exposureMark.name): \(model.controls.exposureMark.about)."
        }
        let resolved = photo.metering.reading(resolving: model.controls.exposureMark).mark
        var text = if let mark = here.first(where: { $0 == resolved }) ?? here.first {
            "\(mark.name): \(mark.about)."
        } else {
            "\(model.controls.exposureOffsetEV.formatted(Self.stops)) EV from \(resolved.name)."
        }
        if resolved != model.controls.exposureMark {
            text += " No \(model.controls.exposureMark.name.lowercased()) found in this photo, so it starts from \(resolved.name)."
        }
        return text
    }
}

/// The name of the mark the slider is on, under its dot. A slider tick's own label would be the
/// built-in way, but SwiftUI (macOS 26) draws it once and keeps its first text however it
/// changes, so the name is a text of its own at the dot: the slider's track ends 10 pt in from
/// each side (its knob's radius), measured. Kept inside the row at the ends.
private struct MarkName: View {
    let name: String
    /// Where the dot is along the slider, 0 at its minimum.
    let fraction: Double
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let inset = 10.0
            let x = inset + fraction * (geometry.size.width - 2 * inset)
            Text(name)
                .foregroundStyle(.tint)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .position(x: min(max(x, width / 2), geometry.size.width - width / 2), y: geometry.size.height / 2)
        }
        .frame(height: 16)
    }
}

private extension MeteringMark {
    var name: String {
        switch self {
        case .asShot: "As shot"
        case .centreWeighted: "Centre-weighted"
        case .objects: "Objects"
        case .people: "People"
        case .faces: "Faces"
        }
    }

    /// What the mark's exposure is.
    var about: String {
        switch self {
        case .asShot: "the exposure the camera chose"
        case .centreWeighted: "meters the whole frame, the centre counting most, as Spektrafilm and a film camera do"
        case .objects: "meters what stands out in the frame"
        case .people: "meters the people in the frame, so a bright sky or background can't darken them"
        case .faces: "meters the faces in the frame"
        }
    }
}

/// A slider with its value written out beside it (SwiftUI's `Slider` doesn't show its value).
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: FloatingPointFormatStyle<Double>
    let unit: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         format: FloatingPointFormatStyle<Double>, unit: String = "") {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
        self.unit = unit
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                    .labelsHidden()
                Text(unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)")
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }
}

// MARK: - Canvas

/// The photo fitted to the canvas. Scrolling (or pinching) zooms around the pointer, dragging
/// moves the zoomed photo, and double-clicking shows all of it again.
private struct ImageCanvas: View {
    @Environment(PhotoModel.self) private var model
    /// Magnification over the photo fitted to the canvas (1 shows all of it), and how far the
    /// zoomed photo is moved from the centre, in points.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    /// Where the pointer is over the photo: scrolling zooms around it.
    @State private var pointer: CGPoint?
    /// The offset when the drag began, and the pinch's magnification so far.
    @State private var dragStart: CGSize?
    @State private var pinched: CGFloat = 1
    @State private var scrollMonitor: Any?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = model.displayImage {
                // The reader takes the canvas's size and passes nothing back: a frame sized by the
                // photo would make that the window's minimum, which the split view then chases
                // until AppKit gives up (an exception when a photo opens).
                GeometryReader { geometry in
                    let fitted = fittedSize(in: geometry.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .overlay { meteringOverlay }
                        .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                        .position(x: geometry.size.width / 2 + offset.width, y: geometry.size.height / 2 + offset.height)
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
                .onTapGesture(count: 2) { zoom = 1; offset = .zero }
                .pointerStyle(zoom > 1 ? (dragStart == nil ? .grabIdle : .grabActive) : nil)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): pointer = location
                    case .ended: pointer = nil
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
            } else {
                // Outside the GeometryReader so it fills the canvas and centres itself.
                ContentUnavailableView {
                    Label("No photo", systemImage: "photo")
                } description: {
                    Text("Drop a photo here or open one to simulate it on film.")
                } actions: {
                    Button("Open…") { model.isImporting = true }
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
        // With the pointer anywhere over the canvas, where scrolling zooms.
        .onChange(of: pointer != nil || zoom > 1, initial: true) { _, wants in
            model.wantsFullResolution = wants
        }
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
        let fitted = fittedSize(in: canvasSize)
        return Int((max(fitted.width, fitted.height) * displayScale).rounded(.up))
    }

    /// Zooms by `factor`, keeping the photo's point under `anchor` (canvas coordinates) where it
    /// is: from all of the photo to 4 points per photo pixel.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        guard let photo = model.photo else { return }
        let fitted = fittedSize(in: canvasSize)
        guard fitted.width > 0 else { return }
        let newZoom = min(max(zoom * factor, 1), max(1, 4 * CGFloat(photo.width) / fitted.width))
        let applied = newZoom / zoom
        // The anchor's distance from the photo's centre scales with the zoom.
        let fromCentre = CGSize(width: anchor.x - canvasSize.width / 2, height: anchor.y - canvasSize.height / 2)
        zoom = newZoom
        offset = clamped(CGSize(width: fromCentre.width - (fromCentre.width - offset.width) * applied,
                                height: fromCentre.height - (fromCentre.height - offset.height) * applied))
    }

    /// `offset` limited so the zoomed photo fills the canvas where it's larger, and stays
    /// centred where it's smaller.
    private func clamped(_ offset: CGSize) -> CGSize {
        let fitted = fittedSize(in: canvasSize)
        let slack = CGSize(width: max(0, (fitted.width * zoom - canvasSize.width) / 2),
                           height: max(0, (fitted.height * zoom - canvasSize.height) / 2))
        return CGSize(width: min(max(offset.width, -slack.width), slack.width),
                      height: min(max(offset.height, -slack.height), slack.height))
    }
}

// MARK: - Status bar & log

private struct StatusBar: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        // Mini spinners keep the bar the labels' height: a small one makes it a point taller, and
        // the photo above would shrink each time a render starts and grow when it ends.
        HStack(spacing: 12) {
            if model.isLoading {
                ProgressView().controlSize(.mini)
                Text("Opening…")
            } else if let phase = model.savePhase {
                ProgressView().controlSize(.mini)
                Text(phase)
            } else if model.isRendering {
                ProgressView().controlSize(.mini)
                Text(model.isRenderingFullResolution ? "Rendering full resolution…" : "Rendering…")
            } else if let photo = model.photo {
                if model.shownMode == .full {
                    Label("Full resolution, \(photo.width) × \(photo.height)", systemImage: "photo")
                } else if case .reduced? = model.shownMode, let image = model.displayImage {
                    Label("Screen size, \(image.width) × \(image.height)", systemImage: "photo")
                } else {
                    Label("Preview, \(photo.previewWidth) × \(photo.previewHeight)", systemImage: "eye")
                }
            } else {
                Label("No photo", systemImage: "photo")
            }
            Spacer()
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct LogView: View {
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
