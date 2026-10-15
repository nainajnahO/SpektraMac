import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PhotoModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("showsSettings") private var showsSettings = true

    var body: some View {
        @Bindable var model = model
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
                    Button("Log", systemImage: "list.bullet.rectangle") { openWindow(id: "log") }
                    Toggle("Adjust", systemImage: "slider.horizontal.3", isOn: $showsSettings)
                        .help("Show or hide the settings")
                }
            }
            // The canvas doesn't scroll under the toolbar, so the window would otherwise
            // draw a hard separator line beneath it.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // On the right, where Photos has its Adjust panel.
            .inspector(isPresented: $showsSettings) {
                SettingsPanel()
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
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
    }
}

// MARK: - Settings

/// The settings, one step of the process at a time, chosen at the top: the camera's exposure,
/// the film, and the print made from it. Laid out as Photos' Adjust panel: a group per effect.
private struct SettingsPanel: View {
    @Environment(PhotoModel.self) private var model
    @SceneStorage("settingsCategory") private var category = Category.film

    private enum Category: String, CaseIterable {
        case camera = "Camera", film = "Film", print = "Print"
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch category {
                case .camera:
                    AdjustmentGroup("Exposure", systemImage: "plusminus.circle", adjustment: .exposure) {
                        ExposureStrip()
                    } options: {
                        ValueSlider("Highlight boost", value: $model.controls.highlightBoost, in: 0...10, step: 0.5,
                                    format: .number.precision(.fractionLength(1)), unit: "EV")
                            .help("Raises the brightest highlights before they reach the film, rebuilding light the camera clipped, so bright lights glow more.")
                    }
                case .film:
                    StockRow(title: "Film", stocks: model.films, selection: $model.film, controls: $model.controls)
                    AdjustmentGroup("Halation", systemImage: "sun.haze", adjustment: .halation,
                                    isOn: $model.controls.halation) {
                        ValueSlider("Strength", value: $model.controls.halationAmount, in: 0...3, step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("The glow from light bouncing back off the film base, over the film's own.")
                    } options: {
                        ValueSlider("Size", value: $model.controls.halationSize, in: 0...3, step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How far the glow reaches, over the film's own.")
                        ValueSlider("Scatter", value: $model.controls.scatterAmount, in: 0...1, step: 0.05,
                                    format: .number.precision(.fractionLength(2)))
                            .help("Light spreading inside the emulsion, which softens fine detail.")
                        ValueSlider("Scatter size", value: $model.controls.scatterSize, in: 0...3, step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How far light spreads inside the emulsion, over the film's own.")
                    }
                    // At most 1.5: much stronger inhibition (both at 2, say) breaks Spektrafilm's
                    // curves corrected for it, greys and all, in Python as here.
                    AdjustmentGroup("Couplers", systemImage: "drop.halffull", adjustment: .couplers,
                                    isOn: $model.controls.couplers) {
                        ThumbnailStrip("Saturation", value: $model.controls.couplerSaturation,
                                       in: model.range(of: .couplerSaturation), step: 0.05,
                                       format: .number.precision(.fractionLength(2)), frames: model.strips[.couplerSaturation])
                            .help("How strongly each colour layer holds back the others as it develops: more gives purer colours.")
                    } options: {
                        ValueSlider("Edge contrast", value: $model.controls.couplerEdgeContrast, in: 0...1.5, step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How strongly each layer holds back its own development nearby: more gives crisper edges in fine detail. The overall contrast stays the film's.")
                    }
                    AdjustmentGroup("Grain", systemImage: "aqi.medium", adjustment: .grain, isOn: $model.controls.grain) {
                        // Not down to 0: the particle count per pixel divides by the area.
                        ValueSlider("Size", value: $model.controls.grainSize, in: 0.05...2, step: 0.05,
                                    format: .number.precision(.fractionLength(2)), unit: "µm²")
                            .help("The area of one silver halide particle: about 0.1 µm² for ISO 100, 0.4 µm² for ISO 400.")
                    } options: {
                        ValueSlider("Softness", value: $model.controls.grainSoftness, in: 0...2, step: 0.05,
                                    format: .number.precision(.fractionLength(2)), unit: "px")
                            .help("The blur over the grain, in pixels of the render.")
                    }
                case .print:
                    if model.controls.scanFilm {
                        Text(model.isSlideFilm
                             ? "A slide is viewed directly, so there's no print."
                             : "The film itself is showing. These settings apply when the toolbar shows Print.")
                            .foregroundStyle(.secondary)
                    }
                    Group {
                        StockRow(title: "Paper", stocks: model.papers, selection: $model.controls.paper,
                                 controls: $model.controls)
                        AdjustmentGroup("Contrast", systemImage: "circle.lefthalf.filled", adjustment: .contrast) {
                            ThumbnailStrip("Contrast", value: $model.controls.printContrast,
                                           in: model.range(of: .printContrast), step: 0.05,
                                           format: .number.precision(.fractionLength(2)), frames: model.strips[.printContrast])
                                .help("The paper's contrast around mid-grey: lower brings a bright sky and dark faces closer together.")
                        } options: {
                            ValueSlider("Highlight contrast", value: $model.controls.printHighlightContrast, in: 0.5...2,
                                        step: 0.05, neutral: 1, format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the light tones alone: lower keeps more detail in a bright sky.")
                            ValueSlider("Shadow contrast", value: $model.controls.printShadowContrast, in: 0.5...2,
                                        step: 0.05, neutral: 1, format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the dark tones alone: lower opens up faces in shadow.")
                        }
                        AdjustmentGroup("Enlarger", systemImage: "lightbulb", adjustment: .enlarger) {
                            ThumbnailStrip("Print exposure", value: $model.controls.printExposure,
                                           in: model.range(of: .printExposure), step: 0.02,
                                           format: .number.precision(.fractionLength(2)), frames: model.strips[.printExposure])
                        } options: {
                            ValueSlider("Y filter shift", value: $model.controls.yFilterShift, in: -100...100, step: 1, neutral: 0,
                                        format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                        unit: "CC")
                            ValueSlider("M filter shift", value: $model.controls.mFilterShift, in: -100...100, step: 1, neutral: 0,
                                        format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                        unit: "CC")
                            ValueSlider("Preflash", value: $model.controls.preflash, in: 0...0.05, step: 0.001,
                                        format: .number.precision(.fractionLength(3)))
                                .help("A flash of plain light on the paper before the print, so light tones such as a bright sky gain some tone. It darkens the whole print: lower the print exposure to bring the mid-tones back.")
                        }
                        AdjustmentGroup("Glare", systemImage: "sun.max", adjustment: .glare, isOn: $model.controls.glare) {
                            ValueSlider("Amount", value: $model.controls.glareAmount, in: 0...1, step: 0.01,
                                        format: .number.precision(.fractionLength(2)), unit: "%")
                                .help("Stray light over the print as it's viewed, in percent of the light: it lifts the blacks.")
                        } options: {
                            ValueSlider("Roughness", value: $model.controls.glareRoughness, in: 0...1, step: 0.05,
                                        format: .number.precision(.fractionLength(2)))
                                .help("How unevenly the stray light falls.")
                            ValueSlider("Softness", value: $model.controls.glareSoftness, in: 0...3, step: 0.1,
                                        format: .number.precision(.fractionLength(1)), unit: "px")
                                .help("The blur over the stray light, in pixels of the render.")
                        }
                    }
                    .disabled(model.controls.scanFilm)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .top) {
            Picker("Settings", selection: $category) {
                ForEach(Category.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.top, .horizontal])
        }
    }
}

/// A group of settings as Photos lays out an adjustment: a disclosure headed by its symbol and
/// name, a reset arrow and, where the effect can be off, an on/off circle; its main control, then
/// the rest under Options. Whether each is open is kept with the window.
private struct AdjustmentGroup<Main: View, Options: View>: View {
    @Environment(PhotoModel.self) private var model
    let title: String
    let systemImage: String
    let adjustment: PhotoModel.Adjustment
    let isOn: Binding<Bool>?
    let main: Main
    let options: Options
    @SceneStorage private var isExpanded: Bool
    @SceneStorage private var showsOptions: Bool

    init(_ title: String, systemImage: String, adjustment: PhotoModel.Adjustment, isOn: Binding<Bool>? = nil,
         @ViewBuilder main: () -> Main, @ViewBuilder options: () -> Options) {
        self.title = title
        self.systemImage = systemImage
        self.adjustment = adjustment
        self.isOn = isOn
        self.main = main()
        self.options = options()
        _isExpanded = SceneStorage(wrappedValue: true, "adjustment.\(title)")
        _showsOptions = SceneStorage(wrappedValue: false, "adjustment.\(title).options")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                main
                DisclosureGroup("Options", isExpanded: $showsOptions) {
                    VStack(spacing: 6) { options }
                        .padding(.top, 4)
                }
            }
            .padding(.top, 6)
            .disabled(isOn?.wrappedValue == false)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.title3)
                Spacer()
                Button("Reset \(title)", systemImage: "arrow.uturn.backward") { model.reset(adjustment) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(model.isAtDefaults(adjustment))
                    .help("Back to the film's defaults")
                if let isOn {
                    Toggle(title, isOn: isOn)
                        .toggleStyle(CircleToggleStyle())
                        .help(isOn.wrappedValue ? "Turn off" : "Turn on")
                }
            }
        }
    }
}

/// Photos' on/off circle for an adjustment: a ring when it's off, a check when it's on.
private struct CircleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The Film or Paper row: its stocks in a pop-up menu (``StockMenu``). A row of its own, as
/// `LabeledContent` gives its content at most about half the row, cutting short names.
private struct StockRow: View {
    let title: String
    let stocks: [ProfileInfo]
    @Binding var selection: String
    @Binding var controls: Controls

    var body: some View {
        HStack {
            Text(title)
                .fixedSize()
            Spacer(minLength: 8)
            StockMenu(stocks: stocks, selection: $selection, controls: $controls)
                .layoutPriority(1)
                .accessibilityLabel(title)
        }
    }
}

/// A pop-up menu of stocks under headings, from their profiles: slides, still negatives or
/// papers, then cine stocks. While it's open, the photo shows the stock the pointer is on as
/// choosing it would, and goes back to `controls` as they were if the menu closes without a
/// choice. AppKit's pop-up button: SwiftUI's menus don't say which item is highlighted, and an
/// `NSMenuDelegate` is told.
private struct StockMenu: NSViewRepresentable {
    let stocks: [ProfileInfo]
    @Binding var selection: String
    /// What choosing a stock may change, as the menu found it.
    @Binding var controls: Controls

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        // As SwiftUI's picker: the name at the arrows, cut short where the row is narrow.
        button.alignment = .right
        (button.cell as! NSPopUpButtonCell).lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.stocks != stocks.map(\.stock) {
            coordinator.stocks = stocks.map(\.stock)
            button.menu = menu(delegate: coordinator)
        }
        // While the menu is open, its check mark stays on the stock it opened with.
        if !coordinator.isOpen {
            button.select(button.itemArray.first { $0.representedObject as? String == selection })
        }
        button.isEnabled = context.environment.isEnabled
    }

    /// The selected stock's width, as SwiftUI's picker has, rather than the widest stock's.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        let widest = button.intrinsicContentSize
        func width(_ title: String) -> CGFloat { (title as NSString).size(withAttributes: [.font: button.font!]).width }
        let ideal = widest.width - (button.itemTitles.map(width).max() ?? 0) + width(button.titleOfSelectedItem ?? "")
        return CGSize(width: min(ideal, proposal.width ?? ideal), height: widest.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func menu(delegate: Coordinator) -> NSMenu {
        let groups = Dictionary(grouping: stocks) { stock -> String in
            if stock.type == .positive { return "Slide" }
            if stock.use == .cine { return "Cine" }
            return stock.stage == .filming ? "Negative" : "Still"
        }
        let menu = NSMenu()
        menu.delegate = delegate
        for heading in ["Slide", "Negative", "Still", "Cine"] {
            guard let group = groups[heading] else { continue }
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(.sectionHeader(title: heading))
            for stock in group {
                let item = NSMenuItem(title: stock.name, action: nil, keyEquivalent: "")
                item.representedObject = stock.stock
                menu.addItem(item)
            }
        }
        return menu
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: StockMenu
        /// The stocks the menu lists.
        var stocks: [String] = []
        /// The controls the menu opened with, while it's open.
        private var opened: Controls?
        private var chosen: String?
        var isOpen: Bool { opened != nil }

        init(parent: StockMenu) {
            self.parent = parent
        }

        func menuWillOpen(_ menu: NSMenu) {
            opened = parent.controls
            chosen = nil
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let opened else { return }
            show(item?.representedObject as? String, from: opened)
        }

        @objc func choose(_ button: NSPopUpButton) {
            chosen = button.selectedItem?.representedObject as? String
        }

        func menuDidClose(_ menu: NSMenu) {
            // The pop-up sends its action as the menu closes: settle once both have run.
            DispatchQueue.main.async { [self] in
                guard let opened else { return }
                self.opened = nil
                show(chosen, from: opened)
            }
        }

        /// The controls the menu opened with, `stock` chosen from them unless it's theirs.
        private func show(_ stock: String?, from opened: Controls) {
            parent.controls = opened
            if let stock, stock != parent.selection {
                parent.selection = stock
            }
        }
    }
}

/// The exposure, in stops over the photo as shot. Its dots are where each way of metering puts
/// it for this photo (``MeteringMark``); a mark's name shows only while the exposure is on it, so
/// marks a fraction of a stop apart don't crowd, and the trackpad clicks as it lands on one.
private struct ExposureStrip: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let readings = model.photo.map { photo in
            MeteringMark.allCases.compactMap { mark in photo.metering.ev[mark.rawValue] }
        } ?? []
        let here = model.marksAtExposure
        let range = model.exposureRange
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailStrip("Exposure", value: $model.exposureEV, in: range, step: 0.1, format: Self.stops, unit: "EV",
                           frames: model.strips[.exposure], marks: Set(readings).sorted()) {
                model.isAdjustingExposure = $0
            }
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

    /// What the mark the exposure is on meters, or how far it is from the nearest one.
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

/// The name of the mark the exposure is on, under its dot on the strip, kept inside the row at
/// the ends.
private struct MarkName: View {
    let name: String
    /// Where the dot is along the strip, 0 at its minimum.
    let fraction: Double
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let x = fraction * geometry.size.width
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

/// A slider as Photos draws its adjustments: the name and value inside a bar that fills from
/// `neutral` (the lower bound unless given) to the value. Dragging anywhere on it moves the value
/// from where it was, the bar's width for the whole range; with Full Keyboard Access the arrow
/// keys step it. SwiftUI's `Slider` can't be restyled (there's no slider style to conform to), so
/// the bar is drawn here, with the system slider standing in for VoiceOver.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let neutral: Double?
    let format: FloatingPointFormatStyle<Double>
    let unit: String
    @State private var width: CGFloat = 0
    /// The value when the drag began.
    @State private var dragStart: Double?
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, neutral: Double? = nil,
         format: FloatingPointFormatStyle<Double>, unit: String = "") {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.neutral = neutral
        self.format = format
        self.unit = unit
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)")
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            let x = fraction(of: value) * width, origin = fraction(of: neutral ?? range.lowerBound) * width
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(.tertiary)
                    .frame(width: abs(x - origin))
                    .offset(x: min(x, origin))
                Rectangle().fill(.secondary)
                    .frame(width: 2)
                    .offset(x: min(max(x - 1, 0), width - 2))
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .opacity(isEnabled ? 1 : 0.5)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let start = dragStart ?? value
                dragStart = start
                guard width > 0 else { return }
                set(start + drag.translation.width / width * (range.upperBound - range.lowerBound))
            }
            .onEnded { _ in dragStart = nil })
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left: set(value - step)
            case .right: set(value + step)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(title) }
        }
    }

    private func fraction(of value: Double) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// Sets the value to the nearest step, within the range.
    private func set(_ newValue: Double) {
        let stepped = range.lowerBound + ((newValue - range.lowerBound) / step).rounded() * step
        value = min(max(stepped, range.lowerBound), range.upperBound)
    }
}

/// A control as Photos shows its main adjustments: its name and value over frames of the photo
/// across its range (``PhotoModel/Strip``), with a line at the value; `marks` are dots under it.
/// Clicking or dragging along it sets the value there; with Full Keyboard Access the arrow keys
/// step it, and the system slider stands in for VoiceOver. Drawn here, as Photos' strip isn't
/// one of SwiftUI's or AppKit's controls.
private struct ThumbnailStrip: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: FloatingPointFormatStyle<Double>
    let unit: String
    /// None until the model has made them.
    let frames: [CGImage]?
    let marks: [Double]
    let onEditingChanged: (Bool) -> Void
    @State private var width: CGFloat = 0
    @State private var isDragging = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         format: FloatingPointFormatStyle<Double>, unit: String = "", frames: [CGImage]?, marks: [Double] = [],
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
        self.unit = unit
        self.frames = frames
        self.marks = marks
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)")
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                if let frames {
                    ForEach(frames.indices, id: \.self) { index in
                        Color.clear
                            .overlay { Image(decorative: frames[index], scale: 1).resizable().scaledToFill() }
                            .clipped()
                    }
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 44)
            .overlay(alignment: .leading) {
                Rectangle().fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: min(max(fraction(of: value) * width - 1, 0), width - 2))
            }
            .clipShape(.rect(cornerRadius: 6))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        onEditingChanged(true)
                    }
                    guard width > 0 else { return }
                    set(range.lowerBound + drag.location.x / width * (range.upperBound - range.lowerBound))
                }
                .onEnded { _ in
                    isDragging = false
                    onEditingChanged(false)
                })
            if !marks.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(marks, id: \.self) { mark in
                        Circle().fill(.secondary)
                            .frame(width: 4, height: 4)
                            .offset(x: fraction(of: mark) * width - 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4, alignment: .leading)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left: set(value - step)
            case .right: set(value + step)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(title) }
        }
    }

    private func fraction(of value: Double) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// Sets the value to the nearest step, within the range.
    private func set(_ newValue: Double) {
        let stepped = range.lowerBound + ((newValue - range.lowerBound) / step).rounded() * step
        value = min(max(stepped, range.lowerBound), range.upperBound)
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
