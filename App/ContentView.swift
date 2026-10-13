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
                            Text("Film").tag(false)
                            Text("Negative").tag(true)
                        }
                        .pickerStyle(.segmented)
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
            Section("Photo") {
                if let photo = model.photo {
                    LabeledContent("File", value: photo.name)
                    LabeledContent("Size", value: "\(photo.width) × \(photo.height)")
                } else {
                    LabeledContent("File") { Text("None").foregroundStyle(.secondary) }
                }
            }
            Section("Simulation") {
                Picker("Film", selection: $model.film) {
                    ForEach(model.films, id: \.stock) { Text($0.name).tag($0.stock) }
                }
                Picker("Paper", selection: $model.controls.paper) {
                    ForEach(model.papers, id: \.stock) { Text($0.name).tag($0.stock) }
                }
                .disabled(model.controls.scanFilm)
            }
            Section("Exposure") {
                Toggle("Auto exposure", isOn: $model.controls.autoExposure)
                ValueSlider("Compensation", value: $model.controls.exposureCompensationEV, in: -5...5, step: 0.25,
                            format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)),
                            unit: "EV")
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

    var body: some View {
        Group {
            if let image = model.displayImage {
                // The reader takes the canvas's size and passes nothing back: a frame sized by the
                // photo would make that the window's minimum, which the split view then chases
                // until AppKit gives up (an exception when a photo opens).
                GeometryReader { geometry in
                    let fitted = fittedSize(for: image, in: geometry.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
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
    }

    /// The image's size scaled to fit `size`, with a margin.
    private func fittedSize(for image: CGImage, in size: CGSize) -> CGSize {
        let inset: CGFloat = 12
        let scale = max(0, min((size.width - 2 * inset) / CGFloat(image.width),
                               (size.height - 2 * inset) / CGFloat(image.height)))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    /// Zooms by `factor`, keeping the photo's point under `anchor` (canvas coordinates) where it
    /// is: from all of the photo to 4 points per photo pixel.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        guard let image = model.displayImage, let photo = model.photo else { return }
        let fitted = fittedSize(for: image, in: canvasSize)
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
        guard let image = model.displayImage else { return .zero }
        let fitted = fittedSize(for: image, in: canvasSize)
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
        HStack(spacing: 12) {
            if model.isLoading {
                ProgressView().controlSize(.small)
                Text("Opening…")
            } else if let phase = model.savePhase {
                ProgressView().controlSize(.small)
                Text(phase)
            } else if model.isRendering {
                ProgressView().controlSize(.small)
                Text(model.isRenderingFullResolution ? "Rendering full resolution…" : "Rendering…")
            } else if let photo = model.photo {
                if model.showsFullResolution {
                    Label("Full resolution, \(photo.width) × \(photo.height)", systemImage: "photo")
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
