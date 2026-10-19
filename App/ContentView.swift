import Charts
import simd
import SpektraEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PhotoModel.self) private var model
    @Environment(\.openWindow) private var openWindow
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
    }

    /// What the app is doing, else the last error (until a photo is opened), else what the canvas
    /// shows: under the window's title.
    private var status: String {
        if model.isLoading { return "Opening…" }
        if let phase = model.savePhase { return phase }
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
        .help("Print: the film printed on the paper. Film: the developed negative, or the slide itself.")
    }
}

// MARK: - Settings

/// The steps of the process the settings are in, one at a time, chosen in the toolbar over the
/// panel: the camera's exposure, the film, and the print made from it.
private enum SettingsCategory: String, CaseIterable {
    case camera = "Camera", film = "Film", print = "Print"
}

/// The settings of one step of the process, laid out as Photos' Adjust panel: a group per effect.
private struct SettingsPanel: View {
    @Environment(PhotoModel.self) private var model
    let category: SettingsCategory

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                switch category {
                case .camera:
                    AdjustmentGroup("Exposure", systemImage: "plusminus.circle", adjustment: .exposure) {
                        ExposureStrip()
                    } options: {
                        ValueSlider("Exposure", value: $model.exposureEV, in: model.exposureRange, step: 0.1, neutral: 0,
                                    format: ExposureStrip.stops, unit: "EV")
                            .disabled(model.photo == nil)
                        ValueSlider("Highlight boost", value: $model.controls.highlightBoost, in: 0...10, step: 0.5,
                                    format: .number.precision(.fractionLength(1)), unit: "EV")
                            .help("Raises the brightest highlights before they reach the film, rebuilding light the camera clipped, so bright lights glow more.")
                    }
                    DiffusionGroup(adjustment: .cameraDiffusion, isOn: \.cameraDiffusion, family: \.cameraDiffusionFilter,
                                   strength: \.cameraDiffusionStrength, size: \.cameraDiffusionSize,
                                   warmth: \.cameraDiffusionWarmth)
                case .film:
                    ChoiceRow(title: "Film", sections: stockSections(model.films), selection: $model.film,
                              controls: $model.controls, choosing: model.controls(choosing:))
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
                                       in: model.range(of: .couplerSaturation), step: 0.05, frames: model.strips[.couplerSaturation])
                            .help("How strongly each colour layer holds back the others as it develops: more gives purer colours.")
                    } options: {
                        ValueSlider("Saturation", value: $model.controls.couplerSaturation,
                                    in: model.range(of: .couplerSaturation), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How strongly each colour layer holds back the others as it develops: more gives purer colours.")
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
                        ChoiceRow(title: "Paper", sections: stockSections(model.papers), selection: $model.controls.paper,
                                  controls: $model.controls) { paper in
                            var controls = model.controls
                            controls.paper = paper
                            return controls
                        }
                        AdjustmentGroup("Contrast", systemImage: "circle.lefthalf.filled", adjustment: .contrast) {
                            ToneGraphView()
                        } options: {
                            ValueSlider("Contrast", value: $model.controls.printContrast, in: ToneGraphView.contrastRange,
                                        step: 0.05, neutral: 1, format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast around mid-grey: lower brings a bright sky and dark faces closer together.")
                            ValueSlider("Highlight contrast", value: $model.controls.printHighlightContrast,
                                        in: ToneGraphView.contrastRange, step: 0.05, neutral: 1,
                                        format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the light tones alone: lower keeps more detail in a bright sky.")
                            ValueSlider("Shadow contrast", value: $model.controls.printShadowContrast,
                                        in: ToneGraphView.contrastRange, step: 0.05, neutral: 1,
                                        format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the dark tones alone: lower opens up faces in shadow.")
                        }
                        AdjustmentGroup("Enlarger", systemImage: "lightbulb", adjustment: .enlarger) {
                            ThumbnailStrip("Print exposure", value: $model.controls.printExposure,
                                           in: model.range(of: .printExposure), step: 0.02, frames: model.strips[.printExposure])
                        } options: {
                            ValueSlider("Print exposure", value: $model.controls.printExposure, in: model.range(of: .printExposure),
                                        step: 0.02, neutral: 1, format: .number.precision(.fractionLength(2)))
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
                        AdjustmentGroup("Burn", systemImage: "sun.horizon", adjustment: .burn, isOn: $model.controls.burn) {
                            ValueSlider("Strength", value: $model.controls.burnStops, in: ToneGraphView.burnStopsRange, step: 0.1,
                                        format: .number.precision(.fractionLength(1)), unit: "EV") {
                                model.isAdjustingBurn = $0
                            }
                            .help("Extra enlarger exposure where the photo is bright, as a darkroom printer burns in a sky: a pale sky darkens and gets its colour back, and the rest of the print stays as it is.")
                            ValueSlider("Threshold", value: $model.controls.burnThreshold, in: ToneGraphView.burnThresholdRange,
                                        step: 0.1, format: ExposureStrip.stops, unit: "EV") {
                                model.isAdjustingBurn = $0
                            }
                            .help("How bright a part of the photo must be to burn, in stops over mid-grey. About +2.5 is where a screen's white sits; lower takes in more. Holding a Burn slider shows what burns, white on black.")
                        }
                        DiffusionGroup(adjustment: .enlargerDiffusion, isOn: \.enlargerDiffusion,
                                       family: \.enlargerDiffusionFilter, strength: \.enlargerDiffusionStrength,
                                       size: \.enlargerDiffusionSize, warmth: \.enlargerDiffusionWarmth)
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
            .padding(.vertical)
            .padding(.leading, 15)
            .padding(.trailing, 20)
        }
    }
}

/// A group of settings as Photos lays out an adjustment: a disclosure headed by its symbol and
/// name, a reset arrow and, where the effect can be off, an on/off circle; its main control, then
/// the rest under Options, if it has any. Whether each is open is kept with the window. Sizes and
/// shades measured from Photos' (macOS 26) screenshots.
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
        // By adjustment, not title: the camera's and the enlarger's diffusion share theirs.
        _isExpanded = SceneStorage(wrappedValue: true, "adjustment.\(adjustment)")
        _showsOptions = SceneStorage(wrappedValue: false, "adjustment.\(adjustment).options")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                main
                if Options.self != EmptyView.self {
                    DisclosureGroup(isExpanded: $showsOptions) {
                        VStack(spacing: 6) { options }
                            .padding(.top, 7)
                            .padding(.bottom, 14)
                    } label: {
                        Text("Options")
                            .foregroundStyle(.secondary)
                    }
                    .disclosureGroupStyle(PhotosDisclosureStyle(contentIndent: 0))
                }
            }
            .padding(.top, 6)
            .disabled(isOn?.wrappedValue == false)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 14))
                Spacer()
                Button("Reset \(title)", systemImage: "arrow.uturn.backward") { model.reset(adjustment) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .disabled(model.isAtDefaults(adjustment))
                    .help("Back to the film's defaults")
                if let isOn {
                    Toggle(title, isOn: isOn)
                        .toggleStyle(CircleToggleStyle())
                        .help(isOn.wrappedValue ? "Turn off" : "Turn on")
                }
            }
            .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(PhotosDisclosureStyle(contentIndent: 14))
    }
}

extension AdjustmentGroup where Options == EmptyView {
    /// A group whose controls all show at once, with no Options.
    init(_ title: String, systemImage: String, adjustment: PhotoModel.Adjustment, isOn: Binding<Bool>? = nil,
         @ViewBuilder main: () -> Main) {
        self.init(title, systemImage: systemImage, adjustment: adjustment, isOn: isOn, main: main) { EmptyView() }
    }
}

/// Photos' disclosure: a small grey chevron before the label that turns as it opens, the label
/// also opening it, and the content under it, indented by `contentIndent`. A group (indented)
/// closed has a line under it, from its symbol.
private struct PhotosDisclosureStyle: DisclosureGroupStyle {
    let contentIndent: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.snappy) { configuration.isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 22, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(configuration.isExpanded ? "Close" : "Open")
                configuration.label
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.snappy) { configuration.isExpanded.toggle() }
                    }
            }
            .frame(minHeight: 22)
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, contentIndent)
            } else if contentIndent > 0 {
                Divider()
                    .padding(.leading, 15)
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
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The Film or Paper row, or a diffusion filter's: its choices in a pop-up menu (``ChoiceMenu``).
/// A row of its own, as `LabeledContent` gives its content at most about half the row, cutting
/// short names.
private struct ChoiceRow<Value: Hashable>: View {
    let title: String
    let sections: [ChoiceMenu<Value>.Section]
    @Binding var selection: Value
    @Binding var controls: Controls
    /// What choosing a value sets the controls to.
    let choosing: (Value) -> Controls

    var body: some View {
        HStack {
            Text(title)
                .fixedSize()
            Spacer(minLength: 8)
            ChoiceMenu(sections: sections, selection: $selection, controls: $controls, choosing: choosing)
                .layoutPriority(1)
                .accessibilityLabel(title)
        }
    }
}

/// Stocks under headings, from their profiles: slides, still negatives or papers, then cine stocks.
private func stockSections(_ stocks: [ProfileInfo]) -> [ChoiceMenu<String>.Section] {
    let groups = Dictionary(grouping: stocks) { stock -> String in
        if stock.type == .positive { return "Slide" }
        if stock.use == .cine { return "Cine" }
        return stock.stage == .filming ? "Negative" : "Still"
    }
    return ["Slide", "Negative", "Still", "Cine"].compactMap { heading in
        groups[heading].map { ChoiceMenu.Section(heading: heading, choices: $0.map { ($0.name, $0.stock) }) }
    }
}

/// A pop-up menu of choices, under headings where they have them. While it's open, the photo
/// shows the choice the pointer is on as choosing it would, and goes back to `controls` as they
/// were if the menu closes without a choice. As it opens, the model renders each choice's finished
/// look, nearest the current one first (``PhotoModel/preload(_:)``), so the pointer finds it ready.
/// AppKit's pop-up button: SwiftUI's menus don't say which item is highlighted, and an
/// `NSMenuDelegate` is told.
private struct ChoiceMenu<Value: Hashable>: NSViewRepresentable {
    struct Section {
        let heading: String?
        let choices: [(name: String, value: Value)]
    }

    @Environment(PhotoModel.self) private var model
    let sections: [Section]
    @Binding var selection: Value
    /// What choosing a value may change, as the menu found it.
    @Binding var controls: Controls
    /// What choosing a value sets the controls to.
    let choosing: (Value) -> Controls

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
        let values = sections.flatMap { $0.choices.map(\.value) }
        if coordinator.values != values {
            coordinator.values = values
            coordinator.measured = nil
            button.menu = menu(delegate: coordinator)
        }
        // While the menu is open, its check mark stays on the choice it opened with.
        if !coordinator.isOpen {
            button.select(button.itemArray.first { $0.representedObject as? Value == selection })
        }
        button.isEnabled = context.environment.isEnabled
    }

    /// The selected choice's width, as SwiftUI's picker has, rather than the widest choice's: the
    /// pop-up button sizes itself (`intrinsicContentSize`, its cell's `cellSize`) only to its
    /// widest item. Measured once per list of choices and selected choice and kept: each step of
    /// a slider lays out the panel again.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        let coordinator = context.coordinator
        let selected = button.titleOfSelectedItem ?? ""
        if coordinator.measured?.selected != selected {
            let widest = button.intrinsicContentSize
            func width(_ title: String) -> CGFloat { (title as NSString).size(withAttributes: [.font: button.font!]).width }
            let ideal = widest.width - (button.itemTitles.map(width).max() ?? 0) + width(selected)
            coordinator.measured = (selected, CGSize(width: ideal, height: widest.height))
        }
        let ideal = coordinator.measured!.size
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func menu(delegate: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = delegate
        for section in sections {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            if let heading = section.heading {
                menu.addItem(.sectionHeader(title: heading))
            }
            for choice in section.choices {
                let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
                item.representedObject = choice.value
                menu.addItem(item)
            }
        }
        return menu
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: ChoiceMenu
        /// The values the menu lists.
        var values: [Value] = []
        /// The button's size for the choice it shows (``sizeThatFits(_:nsView:context:)``), until
        /// the menu lists other choices.
        var measured: (selected: String, size: CGSize)?
        /// The controls the menu opened with, while it's open.
        private var opened: Controls?
        private var chosen: Value?
        var isOpen: Bool { opened != nil }

        init(parent: ChoiceMenu) {
            self.parent = parent
        }

        func menuWillOpen(_ menu: NSMenu) {
            opened = parent.controls
            chosen = nil
            // Outward from the current choice, as the pointer moves from it.
            let order = menu.items.compactMap { $0.representedObject as? Value }
            let current = order.firstIndex(of: parent.selection) ?? 0
            let nearestFirst = order.indices.sorted { (abs($0 - current), $0) < (abs($1 - current), $1) }
            parent.model.preload(nearestFirst.map { parent.choosing(order[$0]) })
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let opened else { return }
            show(item?.representedObject as? Value, from: opened)
        }

        @objc func choose(_ button: NSPopUpButton) {
            chosen = button.selectedItem?.representedObject as? Value
        }

        func menuDidClose(_ menu: NSMenu) {
            parent.model.stopPreloading()
            // The pop-up sends its action as the menu closes: settle once both have run.
            DispatchQueue.main.async { [self] in
                guard let opened else { return }
                self.opened = nil
                show(chosen, from: opened)
            }
        }

        /// The controls the menu opened with, `value` chosen from them unless it's theirs.
        private func show(_ value: Value?, from opened: Controls) {
            parent.controls = opened
            if let value, value != parent.selection {
                parent.selection = value
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
            ThumbnailStrip("Exposure", value: $model.exposureEV, in: range, step: 0.1, frames: model.strips[.exposure],
                           marks: Set(readings).sorted()) {
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

    static let stops = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
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

/// A diffusion filter on the camera's lens or the enlarger's: the filter and its strength, with its
/// glow's size and warmth under Options, each the controls at its key path.
private struct DiffusionGroup: View {
    @Environment(PhotoModel.self) private var model
    let adjustment: PhotoModel.Adjustment
    let isOn: WritableKeyPath<Controls, Bool>
    let family: WritableKeyPath<Controls, Parameters.DiffusionFilter.Family>
    let strength: WritableKeyPath<Controls, Double>
    let size: WritableKeyPath<Controls, Double>
    let warmth: WritableKeyPath<Controls, Double>

    var body: some View {
        @Bindable var model = model
        let controls = $model.controls
        AdjustmentGroup("Diffusion", systemImage: "camera.filters", adjustment: adjustment,
                        isOn: controls[dynamicMember: isOn]) {
            ChoiceRow(title: "Filter",
                      sections: [.init(heading: nil, choices: Parameters.DiffusionFilter.Family.allCases.map { ($0.name, $0) })],
                      selection: controls[dynamicMember: family], controls: controls) { choice in
                var choosing = model.controls
                choosing[keyPath: family] = choice
                return choosing
            }
            .help("Glimmerglass keeps detail and glows faintly; Black Pro-Mist gives a tight, punchy halo; Pro-Mist a broader pastel haze; CineBloom a wide glow that lifts the whole frame.")
            ValueSlider("Strength", value: controls[dynamicMember: strength], in: 0.125...2, step: 0.125,
                        format: .number.precision(.fractionLength(0...3)))
                .help("The filter's grade, as filters are sold: 1/8, 1/4, 1/2, 1 and 2. Stronger spreads more of the light into the glow.")
        } options: {
            ValueSlider("Size", value: controls[dynamicMember: size], in: 0...3, step: 0.05, neutral: 1,
                        format: .number.precision(.fractionLength(2)))
                .help("How far the glow reaches, over the filter's own.")
            ValueSlider("Warmth", value: controls[dynamicMember: warmth], in: -1.5...1.5, step: 0.05, neutral: 0,
                        format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
                .help("Warmer light at the glow's outer rim and cooler at its centre, over the filter's own; below 0, the reverse.")
        }
    }
}

extension Parameters.DiffusionFilter.Family {
    var name: String {
        switch self {
        case .glimmerglass: "Glimmerglass"
        case .blackProMist: "Black Pro-Mist"
        case .proMist: "Pro-Mist"
        case .cinebloom: "CineBloom"
        }
    }
}

/// A slider as Photos draws its adjustments: the name and value inside a bar that fills from
/// `neutral` (the lower bound unless given) to the value; under the pointer, a ruler along its top
/// and the value's line in the accent colour. Dragging anywhere on it moves the value
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
    let onEditingChanged: (Bool) -> Void
    @State private var width: CGFloat = 0
    /// The value when the drag began.
    @State private var dragStart: Double?
    @State private var isHovered = false
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, neutral: Double? = nil,
         format: FloatingPointFormatStyle<Double>, unit: String = "", onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.neutral = neutral
        self.format = format
        self.unit = unit
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        // Sizes and shades measured from Photos' (macOS 26) screenshots. Shades the system has are its
        // own (the measured text is `.secondary` in dark mode); the rest as the primary style's opacity.
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)")
                .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background {
            let x = fraction(of: value) * width, origin = fraction(of: neutral ?? range.lowerBound) * width
            let isActive = isHovered || dragStart != nil
            ZStack(alignment: .leading) {
                Rectangle().fill(.quinary)
                Rectangle().fill(.primary.opacity(0.19))
                    .frame(width: abs(x - origin))
                    .offset(x: min(x, origin))
                Rectangle().fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.22)))
                    .frame(width: 3)
                    .offset(x: min(max(x - 1.5, 0), width - 3))
                if isActive {
                    // Photos' ruler, over the line: a hairline every 6 pt either side of the neutral
                    // value, every fifth longer and every tenth brighter.
                    Canvas { context, size in
                        let hairline = 1 / displayScale
                        for tick in -Int(origin / 6)...Int((size.width - origin) / 6) {
                            let tickX = ((origin + CGFloat(tick) * 6) * displayScale).rounded() / displayScale
                            context.fill(Path(CGRect(x: tickX, y: 0, width: hairline, height: tick % 5 == 0 ? 5 : 3)),
                                         with: .style(tick % 10 == 0 ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.tertiary)))
                        }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 5))
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if dragStart == nil {
                    model.isAdjusting = true
                    onEditingChanged(true)
                }
                let start = dragStart ?? value
                dragStart = start
                guard width > 0 else { return }
                set(start + drag.translation.width / width * (range.upperBound - range.lowerBound))
            }
            .onEnded { _ in
                dragStart = nil
                model.isAdjusting = false
                onEditingChanged(false)
            })
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

/// A control as Photos shows its main adjustments: frames of the photo across its range
/// (``PhotoModel/Strip``), with a line at the value; `marks` are dots under it. As in Photos, the
/// value itself shows on the control's bar under Options. Clicking or dragging along it sets the
/// value there; with Full Keyboard Access the arrow keys step it, and the system slider stands in
/// for VoiceOver. Drawn here, as Photos' strip isn't one of SwiftUI's or AppKit's controls.
private struct ThumbnailStrip: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// None until the model has made them.
    let frames: [CGImage]?
    let marks: [Double]
    let onEditingChanged: (Bool) -> Void
    @State private var width: CGFloat = 0
    @State private var isDragging = false
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, frames: [CGImage]?,
         marks: [Double] = [], onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.frames = frames
        self.marks = marks
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(spacing: 4) {
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
            .frame(height: 38)
            .overlay(alignment: .leading) {
                Rectangle().fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: min(max(fraction(of: value) * width - 1, 0), width - 2))
            }
            .clipShape(.rect(cornerRadius: 5))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        model.isAdjusting = true
                        onEditingChanged(true)
                    }
                    guard width > 0 else { return }
                    set(range.lowerBound + drag.location.x / width * (range.upperBound - range.lowerBound))
                }
                .onEnded { _ in
                    isDragging = false
                    model.isAdjusting = false
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

// MARK: - Tone graph

/// The print's tone curve, drawn as Photos draws Levels: behind it, how much of the photo is at
/// each tone of the film's exposure. Both run over the photo's tones in stops over mid-grey, the
/// Exposure control's units (``ToneGraph``). The menu shows the neutral curve, or one colour's over
/// the other two, which spread apart with the filter shifts. Its points set the print exposure and
/// the contrasts (``ToneCurveLayer``). With the burn on, shading from a line at its threshold marks
/// the tones it takes, and a dashed line where they print
/// (``ToneCurve/burned(stops:threshold:exposures:)``). The sliders under Options and in Enlarger
/// give exact values, and stand in for it with VoiceOver and the keyboard.
private struct ToneGraphView: View {
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @SceneStorage("toneGraph.channel") private var channel = ToneChannel.neutral

    /// The contrasts' range, their sliders' too: the side points' whole way. By 3 they're at the
    /// paper's black or white (past 4 the middle drifts); below 0.1 they barely move closer to its
    /// mid-grey (measured on Portra Endura, 2383 and Crystal Archive).
    static let contrastRange = 0.1...3.0
    /// The burn's strength (EV) and threshold (stops over mid-grey), their sliders' too: its line's
    /// whole way. The threshold stays within ``tones``.
    static let burnStopsRange = 0.0...3.0
    static let burnThresholdRange = 0.0...6.0
    /// The tones the graph shows: the print is black or white past them.
    static let tones: ClosedRange<Float> = -6...6

    var body: some View {
        if let toneGraph = model.toneGraph {
            ToneChart(bins: histogram(toneGraph.graph), channel: channel) { proxy in
                ToneCurveLayer(proxy: proxy, channel: channel)
            }
            .equatable()
            .opacity(isEnabled ? 1 : 0.5)
            .overlay(alignment: .topLeading) {
                // Where the curve is darkest, so it's clear of the menu.
                Picker("Curve", selection: $channel) {
                    ForEach(ToneChannel.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .padding(4)
            }
            .frame(height: 130)
            .help("Drag the middle point sideways to set the print exposure, the side points up or down for the shadow and highlight contrast, or the curve elsewhere for the contrast. With the burn on, the shading is what it takes and the dashed line where those tones print: drag its line sideways for the threshold, or up or down for the strength.")
        } else {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                .frame(height: 130)
        }
    }

    /// The photo's share at each tone, as the menu shows it (neutral: the layers together), scaled
    /// so the tallest bin nearly fills the graph. Bins past the graph's tones count in its end ones,
    /// as the engine counts those past its range, so clipped tones still show.
    private func histogram(_ graph: ToneGraph) -> [HistogramBin] {
        let stops = ToneGraph.stops
        let width = (stops.upperBound - stops.lowerBound) / Float(graph.histogram.count)
        let tones = graph.histogram.indices.map { stops.lowerBound + (Float($0) + 0.5) * width }
        let shares = graph.histogram.map { share in channel.index.map { share[$0] } ?? share.sum() / 3 }
        let inside = tones.indices.filter { Self.tones.contains(tones[$0]) }
        guard let first = inside.first, let last = inside.last else { return [] }
        var shown = inside.map { shares[$0] }
        shown[0] += shares[..<first].reduce(0, +)
        shown[shown.count - 1] += shares[(last + 1)...].reduce(0, +)
        // The end bins left out: a photo with clipped tones would flatten the rest.
        let peak = shown.dropFirst().dropLast().max() ?? 0
        return inside.indices.map { index in
            HistogramBin(id: index, tone: tones[inside[index]], height: peak > 0 ? min(shown[index] / peak * 0.9, 1) : 0)
        }
    }
}

/// The tone graph's chart: the histogram, the axes and their lines, with `overlay` over its plot.
/// Drawn again only when those change, not at each step of a drag: Swift Charts takes 5–8 ms to
/// draw it (measured), most of a 120 Hz frame, so the curve that does change is drawn over it
/// from the chart's scales (``ToneCurveLayer``).
private struct ToneChart<Overlay: View>: View, Equatable {
    let bins: [HistogramBin]
    let channel: ToneChannel
    let overlay: (ChartProxy) -> Overlay

    init(bins: [HistogramBin], channel: ToneChannel, @ViewBuilder overlay: @escaping (ChartProxy) -> Overlay) {
        (self.bins, self.channel, self.overlay) = (bins, channel, overlay)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bins == rhs.bins && lhs.channel == rhs.channel
    }

    var body: some View {
        Chart(bins) { bin in
            AreaMark(x: .value("Tone", bin.tone), y: .value("Share", bin.height))
                .foregroundStyle(channel.colour.opacity(0.25))
        }
        .chartXScale(domain: ToneGraphView.tones)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: ToneGraphView.tones.lowerBound, through: ToneGraphView.tones.upperBound,
                                           by: 2))) { value in
                // Mid-grey brighter.
                AxisGridLine(stroke: StrokeStyle(lineWidth: value.as(Float.self) == 0 ? 1 : 0.5))
                // Centred under its line, none at the ends, which would stick out. Charts puts a
                // label's leading edge at its line and ignores a top anchor ("custom UnitPoint"),
                // so each is a fixed width, set back by half.
                if let stops = value.as(Float.self), stops != ToneGraphView.tones.lowerBound,
                   stops != ToneGraphView.tones.upperBound {
                    AxisValueLabel(horizontalSpacing: -15) {
                        Text(stops.formatted(.number.sign(strategy: .always(includingZero: false))))
                            .frame(width: 30)
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(.quinary).clipShape(.rect(cornerRadius: 5)) }
        .chartOverlay { proxy in overlay(proxy) }
    }
}

/// The tone graph's curve and its three points, over its chart (`proxy`), their dragging, and the
/// burn's marker. Those follow the controls each step, so they're drawn here, not by the chart. The
/// middle point is where the paper's exposure is 0 (a mid-grey negative's at a print exposure of
/// 1), the side points ``sideDistance`` stops either side. Dragging the middle one sideways sets
/// the print exposure; a side one up or down, the shadow or highlight contrast; the curve anywhere
/// else up or down, the contrast, about the middle point; and the burn's line sideways, its
/// threshold, and up or down, its strength. The curve follows the controls
/// at once, as a slider's bar does: it's predicted from the engine's last
/// (``ToneCurve/predicted(for:from:)``), which comes with the photo's preview, and each new one
/// sets the drag's control again from it, so the grabbed point stays under the pointer.
private struct ToneCurveLayer: View {
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    let proxy: ChartProxy
    let channel: ToneChannel
    /// While the pointer is pressed in the graph, and what it's moving, if anything.
    @State private var isPressed = false
    @State private var drag: ToneDrag?
    @State private var hovered: ToneHandle?

    /// How far the side points are from the middle one, in stops.
    private static let sideDistance: Float = 2
    /// How close to a point the pointer grabs it, in points.
    private static let grabDistance: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            if let toneGraph = model.toneGraph, let frame = proxy.plotFrame {
                let plot = geometry[frame]
                let controls = model.controls
                let shown = ToneCurve(toneGraph.graph, channel: channel).predicted(for: controls, from: toneGraph.controls)
                // The other colours' curves under the one shown, faint.
                let others = channel == .neutral ? [] : ToneChannel.colours.filter { $0 != channel }.map {
                    ToneCurve(toneGraph.graph, channel: $0).predicted(for: controls, from: toneGraph.controls)
                }
                let handles = shown.handles(sideDistance: Self.sideDistance)
                let active = drag?.handle ?? hovered
                // The burn's threshold and the curve it prints, while it's on. Its mask goes by the
                // layers' mean exposure, as the engine's `burn_threshold` kernel takes it.
                let threshold = Float(controls.burnThreshold)
                let burned = controls.burn ? shown.burned(stops: Float(controls.burnStops), threshold: threshold,
                                                          exposures: toneGraph.graph.curve.map { log2(exp2($0.film).sum() / 3) })
                    : nil
                let burnLine = burned == nil ? nil : location(of: SIMD2(threshold, 0), in: plot)?.x
                Canvas { context, _ in
                    context.clip(to: Path(roundedRect: plot, cornerRadius: 5))
                    // What burns, shaded from a line at the threshold, labelled at the top beside it
                    // (before it if there's no room after).
                    var labelFrame: CGRect?
                    if let line = burnLine {
                        context.fill(Path(CGRect(x: line, y: plot.minY, width: plot.maxX - line, height: plot.height)),
                                     with: .color(.orange.opacity(0.15)))
                        context.stroke(Path { $0.addLines([CGPoint(x: line, y: plot.minY), CGPoint(x: line, y: plot.maxY)]) },
                                       with: .color(.orange), lineWidth: active == .burn ? 2 : 1)
                        let label = context.resolve(Text("Burn from \(controls.burnThreshold.formatted(ExposureStrip.stops))")
                            .font(.caption2).foregroundStyle(.orange))
                        let size = label.measure(in: plot.size)
                        let x = line + 4 + size.width <= plot.maxX - 4 ? line + 4 : line - 4 - size.width
                        let frame = CGRect(origin: CGPoint(x: x, y: plot.minY + 3), size: size)
                        context.draw(label, in: frame)
                        labelFrame = frame
                    }
                    // In a layer of their own, so the label can be cut out of them where they run
                    // along the top.
                    context.drawLayer { curves in
                        for curve in others + [shown] {
                            let isShown = curve.channel == channel
                            curves.stroke(path(of: curve, in: plot), with: .style(curve.channel.colour.opacity(isShown ? 1 : 0.35)),
                                          lineWidth: isShown ? 1.5 : 1)
                        }
                        if let burned {
                            curves.stroke(path(of: burned, over: threshold...ToneGraphView.tones.upperBound, in: plot),
                                          with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        if let labelFrame {
                            curves.blendMode = .destinationOut
                            curves.fill(Path(labelFrame.insetBy(dx: -3, dy: -2)), with: .color(.black))
                        }
                    }
                    context.addFilter(.shadow(color: .black.opacity(0.5), radius: 1))
                    for handle in handles {
                        guard let at = location(of: SIMD2(handle.tone, handle.print), in: plot) else { continue }
                        context.fill(Path(ellipseIn: CGRect(x: at.x - 4.5, y: at.y - 4.5, width: 9, height: 9)),
                                     with: handle.id == active ? .style(.tint) : .color(.white))
                    }
                }
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressed {
                            isPressed = true
                            drag = beginDrag(at: value.startLocation, handles: handles, curve: shown, burnLine: burnLine,
                                             plot: plot)
                            if let drag {
                                model.isAdjusting = true
                                // As with a Burn slider held, the canvas shows what burns.
                                if drag.handle == .burn {
                                    model.isAdjustingBurn = true
                                }
                            }
                        }
                        guard var drag, let moved = movement(from: value.startLocation, to: value.location, plot: plot) else {
                            return
                        }
                        drag.moved = moved
                        self.drag = drag
                        move(drag)
                    }
                    .onEnded { _ in
                        if let drag {
                            model.isAdjusting = false
                            if drag.handle == .burn {
                                model.isAdjustingBurn = false
                            }
                        }
                        isPressed = false
                        drag = nil
                    })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location) where isEnabled:
                        hovered = grabbed(at: location, among: handles, plot: plot)?.id
                            ?? (isNear(burnLine, location) ? .burn : nil)
                    case .active, .ended:
                        hovered = nil
                    }
                }
                .pointerStyle(active.map { handle in
                    switch handle {
                    case .middle: .columnResize
                    case .shadows, .highlights: .rowResize
                    case .burn: drag == nil ? .grabIdle : .grabActive
                    }
                })
            }
        }
        // The engine's curve for the controls so far: the drag's control set again from it.
        .onChange(of: model.toneGraph?.controls) {
            if let drag {
                move(drag)
            }
        }
    }

    /// `position` (tone, brightness) in the view, if the chart has scales.
    private func location(of position: SIMD2<Float>, in plot: CGRect) -> CGPoint? {
        guard let x = proxy.position(forX: position.x), let y = proxy.position(forY: position.y) else { return nil }
        return CGPoint(x: plot.minX + x, y: plot.minY + y)
    }

    private func path(of curve: ToneCurve, over tones: ClosedRange<Float> = ToneGraphView.tones, in plot: CGRect) -> Path {
        Path { path in
            for position in curve.points(in: tones) {
                guard let at = location(of: position, in: plot) else { continue }
                if path.isEmpty {
                    path.move(to: at)
                } else {
                    path.addLine(to: at)
                }
            }
        }
    }

    /// The pointer's movement from `start` to `end` in tones and brightness.
    private func movement(from start: CGPoint, to end: CGPoint, plot: CGRect) -> SIMD2<Float>? {
        guard let startTone = proxy.value(atX: start.x - plot.minX, as: Float.self),
              let tone = proxy.value(atX: end.x - plot.minX, as: Float.self),
              let startPrint = proxy.value(atY: start.y - plot.minY, as: Float.self),
              let print = proxy.value(atY: end.y - plot.minY, as: Float.self) else { return nil }
        return SIMD2(tone - startTone, print - startPrint)
    }

    /// The point within ``grabDistance`` of `location`, the nearest.
    private func grabbed(at location: CGPoint, among handles: [ToneCurve.Handle], plot: CGRect) -> ToneCurve.Handle? {
        func distance(_ handle: ToneCurve.Handle) -> CGFloat {
            guard let at = self.location(of: SIMD2(handle.tone, handle.print), in: plot) else { return .infinity }
            return hypot(at.x - location.x, at.y - location.y)
        }
        return handles.filter { distance($0) <= Self.grabDistance }.min { distance($0) < distance($1) }
    }

    /// Whether `location` is within ``grabDistance`` of the burn's line, if it's shown (at `burnLine`).
    private func isNear(_ burnLine: CGFloat?, _ location: CGPoint) -> Bool {
        burnLine.map { abs(location.x - $0) <= Self.grabDistance } ?? false
    }

    /// What pressing at `location` grabs: a point of the curve shown under the pointer, else the
    /// burn's line (at `burnLine`, if it's shown), else the curve there, unless that's by the middle
    /// point, which the contrast leaves where it is.
    private func beginDrag(at location: CGPoint, handles: [ToneCurve.Handle], curve: ToneCurve, burnLine: CGFloat?,
                           plot: CGRect) -> ToneDrag? {
        guard isEnabled else { return nil }
        if let handle = grabbed(at: location, among: handles, plot: plot) {
            return ToneDrag(handle: handle.id, tone: handle.tone, print: handle.print, controls: model.controls)
        }
        if isNear(burnLine, location) {
            return ToneDrag(handle: .burn, tone: Float(model.controls.burnThreshold), print: 0, controls: model.controls)
        }
        guard let middle = handles.first(where: { $0.id == .middle }),
              let tone = proxy.value(atX: location.x - plot.minX, as: Float.self), abs(tone - middle.tone) > 0.5 else {
            return nil
        }
        return ToneDrag(handle: nil, tone: tone, print: curve.value(of: curve.print, at: tone), controls: model.controls)
    }

    /// Sets the control `drag` moves for the pointer's movement, so the grabbed point follows it:
    /// from the engine's last curve rather than the one shown, so each new curve corrects what the
    /// prediction misses.
    private func move(_ drag: ToneDrag) {
        guard let toneGraph = model.toneGraph else { return }
        let (curve, rendered) = (ToneCurve(toneGraph.graph, channel: channel), toneGraph.controls)
        switch drag.handle {
        case .middle:
            // The middle point is where the paper's exposure is 0, and the print exposure adds its
            // log₁₀ to it: this puts 0 at the pointer's tone.
            let paper = curve.value(of: curve.paper, at: drag.tone + drag.moved.x)
            set(\.printExposure, to: rendered.printExposure * pow(10, -Double(paper)), in: model.range(of: .printExposure))
        case .shadows:
            scale(\.printShadowContrast, of: curve, rendered: rendered, at: drag.tone, to: drag.print + drag.moved.y)
        case .highlights:
            scale(\.printHighlightContrast, of: curve, rendered: rendered, at: drag.tone, to: drag.print + drag.moved.y)
        case nil:
            scale(\.printContrast, of: curve, rendered: rendered, at: drag.tone, to: drag.print + drag.moved.y)
        case .burn:
            // The line follows the pointer sideways; down burns more, the graph's height for the
            // strength's whole range.
            let strengths = ToneGraphView.burnStopsRange
            set(\.burnThreshold, to: drag.controls.burnThreshold + Double(drag.moved.x),
                in: ToneGraphView.burnThresholdRange)
            set(\.burnStops, to: drag.controls.burnStops - Double(drag.moved.y) * (strengths.upperBound - strengths.lowerBound),
                in: strengths)
        }
    }

    /// The contrasts scale the paper's response about its exposure 0 (``ToneGraph/Point/paper``): a
    /// factor f gives exposure E the response `curve` has at f·E. So for brightness `print` at
    /// `tone`, f is the paper's exposure where `curve` has that brightness, over the one at `tone`.
    private func scale(_ contrast: WritableKeyPath<Controls, Double>, of curve: ToneCurve, rendered: Controls,
                       at tone: Float, to print: Float) {
        let reached = curve.tone(where: curve.print, is: print, near: tone)
        let factor = curve.value(of: curve.paper, at: reached) / curve.value(of: curve.paper, at: tone)
        guard factor.isFinite else { return }
        set(contrast, to: rendered[keyPath: contrast] * Double(max(factor, 0)), in: ToneGraphView.contrastRange)
    }

    /// Sets `control` to `value` within `range`, to a ten-thousandth: finer than shows, so the drag
    /// is smooth, and a new curve that agrees changes nothing.
    private func set(_ control: WritableKeyPath<Controls, Double>, to value: Double, in range: ClosedRange<Double>) {
        let value = min(max((value * 10_000).rounded() / 10_000, range.lowerBound), range.upperBound)
        // Setting the controls renders, even to what they are.
        if model.controls[keyPath: control] != value {
            model.controls[keyPath: control] = value
        }
    }
}

/// The tone graph menu's choices: the neutral curve, or a colour's.
private enum ToneChannel: String, CaseIterable {
    case neutral = "Neutral", red = "Red", green = "Green", blue = "Blue"

    static let colours: [ToneChannel] = [.red, .green, .blue]

    /// Its layer and the print's channel; none for neutral.
    var index: Int? {
        switch self {
        case .neutral: nil
        case .red: 0
        case .green: 1
        case .blue: 2
        }
    }

    var colour: Color {
        switch self {
        case .neutral: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }
}

/// The tone graph's points: the print exposure's in the middle, the shadow and highlight
/// contrasts' either side. And the burn's line.
private enum ToneHandle {
    case shadows, middle, highlights, burn
}

/// One bar of the tone graph's histogram, its height 0–1.
private struct HistogramBin: Identifiable, Equatable {
    let id: Int
    let tone: Float
    let height: Float
}

/// A drag on the tone graph: the point it grabbed (none for the curve) where it was, the controls
/// then, which the burn's line moves from, and how far the pointer has moved since, in tones and
/// brightness.
private struct ToneDrag {
    let handle: ToneHandle?
    let tone: Float
    let print: Float
    let controls: Controls
    var moved = SIMD2<Float>.zero
}

/// One colour's tone curve, or the neutral one, from a ``ToneGraph``: per grey of its ramp, the
/// tone (the film's exposure, in stops), the paper's log₁₀ exposure and the print's brightness.
private struct ToneCurve {
    struct Handle {
        let id: ToneHandle
        let tone: Float
        let print: Float
    }

    let channel: ToneChannel
    let tones: [Float]
    let paper: [Float]
    let print: [Float]

    init(channel: ToneChannel, tones: [Float], paper: [Float], print: [Float]) {
        (self.channel, self.tones, self.paper, self.print) = (channel, tones, paper, print)
    }

    init(_ graph: ToneGraph, channel: ToneChannel) {
        self.channel = channel
        if let index = channel.index {
            tones = graph.curve.map { $0.film[index] }
            paper = graph.curve.map { $0.paper[index] }
            print = graph.curve.map { $0.print[index] }
        } else {
            // The layers' mean, as the histogram has them together; the brightness as Rec. 709 luma.
            tones = graph.curve.map { $0.film.sum() / 3 }
            paper = graph.curve.map { $0.paper.sum() / 3 }
            print = graph.curve.map { ($0.print * SIMD3(0.2126, 0.7152, 0.0722)).sum() }
        }
    }

    /// The curve `controls` would make, from this one made with `rendered`: the print exposure
    /// adds its log₁₀ to the paper's exposure, and the contrasts scale that about 0 (Contrast all
    /// of it, Shadow contrast above 0, Highlight contrast below), the print's brightness for each
    /// paper exposure staying this curve's. Exact for the print exposure (but for preflash) and
    /// Contrast; near for the other two, as their sub-layers aren't all of the paper's response.
    /// The other controls change nothing here: the engine's next curve shows them.
    func predicted(for controls: Controls, from rendered: Controls) -> ToneCurve {
        let shift = Float(log10(controls.printExposure / rendered.printExposure))
        let contrast = Float(controls.printContrast / rendered.printContrast)
        let change = SIMD3(shift, contrast * Float(controls.printShadowContrast / rendered.printShadowContrast),
                           contrast * Float(controls.printHighlightContrast / rendered.printHighlightContrast))
        guard shift.isFinite, change != SIMD3(0, 1, 1) else { return self }
        return ToneCurve(channel: channel, tones: tones, paper: paper.map { $0 + shift },
                         print: tones.map { brightness(at: $0, change) })
    }

    /// The brightness at `tone` with `change`: the paper's exposure shifted by its x, then scaled
    /// by its y above 0 and its z below (``predicted(for:from:)``), looked up on this curve.
    private func brightness(at tone: Float, _ change: SIMD3<Float>) -> Float {
        let exposure = value(of: paper, at: tone) + change.x
        let scaled = exposure > 0 ? exposure * change.y : exposure * change.z
        return value(of: print, at: self.tone(where: paper, is: scaled, near: tone))
    }

    /// This curve burned in (``Parameters/Burn``) as the engine burns a photo, but with a mask not
    /// fitted to its edges: each grey's paper exposure up by `stops` × its mask, log₁₀ 2 a stop, and
    /// the brightness for that looked up on this curve, as ``predicted(for:from:)`` looks it up. The
    /// mask is the `burn_threshold` kernel's over each grey's exposure in `exposures` (stops over
    /// mid-grey): 0 under `threshold`, 1 from a stop over, smoothly between.
    func burned(stops: Float, threshold: Float, exposures: [Float]) -> ToneCurve {
        let burned = paper.indices.map { index in
            paper[index] + log10(2) * stops * simd_smoothstep(threshold, threshold + 1, exposures[index])
        }
        let print = burned.indices.map { index in
            value(of: self.print, at: tone(where: paper, is: burned[index], near: tones[index]))
        }
        return ToneCurve(channel: channel, tones: tones, paper: burned, print: print)
    }

    /// The middle point where the paper's exposure is 0 (a mid-grey negative's at a print exposure
    /// of 1), and the side points `sideDistance` stops either side; none if it's never 0.
    func handles(sideDistance: Float) -> [Handle] {
        guard paper.contains(where: { $0 <= 0 }), paper.contains(where: { $0 >= 0 }) else { return [] }
        let middle = tone(where: paper, is: 0, near: 0)
        return [(ToneHandle.shadows, middle - sideDistance), (.middle, middle), (.highlights, middle + sideDistance)]
            .map { Handle(id: $0, tone: $1, print: value(of: print, at: $1)) }
    }

    /// The ramp's greys within `range` as (tone, brightness), and the nearest past each end, so a
    /// line through them reaches them.
    func points(in range: ClosedRange<Float>) -> [SIMD2<Float>] {
        let first = max((tones.firstIndex { $0 >= range.lowerBound } ?? 0) - 1, 0)
        let last = min((tones.lastIndex { $0 <= range.upperBound } ?? tones.count - 1) + 1, tones.count - 1)
        return (first...last).map { SIMD2(tones[$0], print[$0]) }
    }

    /// `values` at `tone`, between the ramp's greys; past its ends, the end's.
    func value(of values: [Float], at tone: Float) -> Float {
        guard let above = tones.firstIndex(where: { $0 >= tone }) else { return values[values.count - 1] }
        guard above > 0 else { return values[0] }
        let fraction = (tone - tones[above - 1]) / (tones[above] - tones[above - 1])
        return values[above - 1] + fraction * (values[above] - values[above - 1])
    }

    /// The tone nearest `near` where `values` are `target`, brought within their range.
    func tone(where values: [Float], is target: Float, near: Float) -> Float {
        let target = min(max(target, values.min()!), values.max()!)
        var nearest = near
        var nearestDistance = Float.infinity
        for index in values.indices.dropLast() {
            let (from, to) = (values[index], values[index + 1])
            guard min(from, to) <= target && target <= max(from, to) else { continue }
            let fraction = from == to ? 0 : (target - from) / (to - from)
            let tone = tones[index] + fraction * (tones[index + 1] - tones[index])
            if abs(tone - near) < nearestDistance {
                (nearest, nearestDistance) = (tone, abs(tone - near))
            }
        }
        return nearest
    }
}

// MARK: - Canvas

/// The photo fitted to the canvas below the toolbar and beside the settings panel. Scrolling (or
/// pinching) zooms around the pointer, dragging moves the zoomed photo, and double-clicking shows
/// all of it again. The canvas reaches under the toolbar and the panel, so a zoomed photo shows
/// through them, as in Photos.
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

    private var canvas: some View {
        // A stack, not a group: without a photo, the canvas is still there to measure and to shade.
        ZStack {
            if let image = model.displayImage {
                // The reader takes the canvas's size and passes nothing back: a frame sized by the
                // photo would make that the window's minimum.
                GeometryReader { _ in
                    let fitted = fittedSize(in: visibleSize)
                    Image(decorative: image, scale: 1)
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
                .onTapGesture(count: 2) { zoom = 1; offset = .zero }
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
