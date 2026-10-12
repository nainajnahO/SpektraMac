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
                .navigationTitle(model.sourceName.isEmpty ? "SpektraMac" : model.sourceName)
                .toolbar {
                    ToolbarItemGroup(placement: .principal) {
                        Picker("Show", selection: $model.scanFilm) {
                            Text("Film").tag(false)
                            Text("Negative").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Open…", systemImage: "folder") { model.isImporting = true }
                        Button("Preview", systemImage: "eye") { model.renderPreview() }
                            .disabled(!model.canRender)
                        Button("Render", systemImage: "camera.aperture") { model.renderFullResolution() }
                            .disabled(!model.canRender)
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
        Form {
            Section("Photo") {
                if let source = model.source {
                    LabeledContent("File", value: model.sourceName)
                    LabeledContent("Size", value: "\(source.width) × \(source.height)")
                } else {
                    LabeledContent("File") { Text("None").foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
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
            } else if model.isRendering {
                ProgressView().controlSize(.small)
                Text("Rendering…")
            } else if let source = model.source, let preview = model.preview {
                if model.showsFullResolution {
                    Label("Full resolution, \(source.width) × \(source.height)", systemImage: "photo")
                } else {
                    Label("Preview, \(preview.width) × \(preview.height)", systemImage: "eye")
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
