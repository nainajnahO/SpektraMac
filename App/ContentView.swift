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

private struct ImageCanvas: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        Group {
            if let image = model.displayImage {
                GeometryReader { geometry in
                    let frame = fittedFrame(for: image, in: geometry.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
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
        .background(.black.opacity(0.05))
    }

    /// Where the image lands when scaled to fit, letterboxed and centred.
    private func fittedFrame(for image: CGImage, in size: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let available = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
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
