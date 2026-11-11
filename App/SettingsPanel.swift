import SpektraEngine
import SwiftUI

// MARK: - Settings

/// The steps of the process the settings are in, one at a time, chosen in the toolbar over the
/// panel: the camera's exposure, the film, and the print made from it.
enum SettingsCategory: String, CaseIterable {
    case camera = "Camera", film = "Film", print = "Print"
}

/// The settings of one step of the process, laid out as Photos' Adjust panel: a group per effect.
struct SettingsPanel: View {
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
                        ValueSlider("Exposure", value: $model.controls.exposureEV, in: model.exposureRange, step: 0.1, neutral: 0,
                                    format: ExposureStrip.stops, unit: "EV")
                            .disabled(model.photo == nil)
                        ValueSlider("Highlight boost", value: $model.controls.highlightBoost, in: Controls.range(\.highlightBoost), step: 0.5,
                                    format: .number.precision(.fractionLength(1)), unit: "EV")
                            .help("Raises the brightest highlights before they reach the film, rebuilding light the camera clipped, so bright lights glow more.")
                    }
                    DiffusionGroup(title: "Lens diffusion", adjustment: .cameraDiffusion, filter: \.cameraDiffusion)
                case .film:
                    ChoiceRow(title: "Film", sections: stockSections(model.films), selection: $model.film,
                              controls: $model.controls, choosing: model.controls(choosing:))
                    DevelopmentRow(stock: model.controls.film, minutes: \.filmDevelopmentTime)
                    AdjustmentGroup("Halation", systemImage: "sun.haze", adjustment: .halation,
                                    isOn: $model.controls.halation) {
                        ValueSlider("Strength", value: $model.controls.halationAmount, in: Controls.range(\.halationAmount), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("The glow from light bouncing back off the film base, over the film's own.")
                    } options: {
                        ValueSlider("Size", value: $model.controls.halationSize, in: Controls.range(\.halationSize), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How far the glow reaches, over the film's own.")
                        ValueSlider("Scatter", value: $model.controls.scatterAmount, in: Controls.range(\.scatterAmount), step: 0.05,
                                    format: .number.precision(.fractionLength(2)))
                            .help("Light spreading inside the emulsion, which softens fine detail.")
                        ValueSlider("Scatter size", value: $model.controls.scatterSize, in: Controls.range(\.scatterSize), step: 0.05, neutral: 1,
                                    format: .number.precision(.fractionLength(2)))
                            .help("How far light spreads inside the emulsion, over the film's own.")
                    }
                    let edgeContrast = ValueSlider("Edge contrast", value: $model.controls.couplerEdgeContrast,
                                                   in: Controls.range(\.couplerEdgeContrast), step: 0.05, neutral: 1,
                                                   format: .number.precision(.fractionLength(2)))
                        .help("How strongly each layer holds back its own development nearby: more gives crisper edges in fine detail. The overall contrast stays the film's.")
                    if model.isBlackAndWhiteFilm {
                        // One layer: no others to hold back, so no saturation to set.
                        AdjustmentGroup("Couplers", systemImage: "drop.halffull", adjustment: .couplers,
                                        isOn: $model.controls.couplers) {
                            edgeContrast
                        }
                    } else {
                        AdjustmentGroup("Couplers", systemImage: "drop.halffull", adjustment: .couplers,
                                        isOn: $model.controls.couplers) {
                            ThumbnailStrip("Saturation", value: $model.controls.couplerSaturation,
                                           in: model.range(of: .couplerSaturation), step: 0.05,
                                           format: .number.precision(.fractionLength(2)), frames: model.strips[.couplerSaturation])
                                .help("How strongly each colour layer holds back the others as it develops: more gives purer colours.")
                        } options: {
                            ValueSlider("Saturation", value: $model.controls.couplerSaturation,
                                        in: model.range(of: .couplerSaturation), step: 0.05, neutral: 1,
                                        format: .number.precision(.fractionLength(2)))
                                .help("How strongly each colour layer holds back the others as it develops: more gives purer colours.")
                            edgeContrast
                        }
                    }
                    AdjustmentGroup("Grain", systemImage: "aqi.medium", adjustment: .grain, isOn: $model.controls.grain) {
                        ValueSlider("Size", value: $model.controls.grainSize, in: Controls.range(\.grainSize), step: 0.05,
                                    format: .number.precision(.fractionLength(2)), unit: "µm²")
                            .help("The area of one silver halide particle: about 0.1 µm² for ISO 100, 0.4 µm² for ISO 400.")
                    } options: {
                        ValueSlider("Softness", value: $model.controls.grainSoftness, in: Controls.range(\.grainSoftness), step: 0.05,
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
                        ChoiceRow(title: "Paper", sections: stockSections(model.papers),
                                  selection: Binding(get: { model.controls.paper },
                                                     set: { model.controls = model.controls.choosing(paper: $0) }),
                                  controls: $model.controls) { model.controls.choosing(paper: $0) }
                        DevelopmentRow(stock: model.controls.paper, minutes: \.paperDevelopmentTime)
                        AdjustmentGroup("Contrast", systemImage: "circle.lefthalf.filled", adjustment: .contrast) {
                            ToneGraphView()
                        } options: {
                            ValueSlider("Contrast", value: $model.controls.printContrast, in: Controls.range(\.printContrast),
                                        step: 0.05, neutral: 1, format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast around mid-grey: lower brings a bright sky and dark faces closer together.")
                            ValueSlider("Highlight contrast", value: $model.controls.printHighlightContrast,
                                        in: Controls.range(\.printHighlightContrast), step: 0.05, neutral: 1,
                                        format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the light tones alone: lower keeps more detail in a bright sky.")
                            ValueSlider("Shadow contrast", value: $model.controls.printShadowContrast,
                                        in: Controls.range(\.printShadowContrast), step: 0.05, neutral: 1,
                                        format: .number.precision(.fractionLength(2)))
                                .help("The paper's contrast in the dark tones alone: lower opens up faces in shadow.")
                        }
                        AdjustmentGroup("Enlarger", systemImage: "lightbulb", adjustment: .enlarger) {
                            ThumbnailStrip("Print exposure", value: $model.controls.printExposure,
                                           in: model.range(of: .printExposure), step: 0.02,
                                           format: .number.precision(.fractionLength(2)), frames: model.strips[.printExposure])
                        } options: {
                            ValueSlider("Print exposure", value: $model.controls.printExposure, in: model.range(of: .printExposure),
                                        step: 0.02, neutral: 1, format: .number.precision(.fractionLength(2)))
                            // The filters balance the print's colour. A black-and-white film on a
                            // black-and-white paper has none: there they'd only change how much
                            // light the paper gets, as the print exposure does.
                            if !(model.isBlackAndWhiteFilm && model.isBlackAndWhitePaper) {
                                ValueSlider("Y filter shift", value: $model.controls.yFilterShift, in: Controls.range(\.yFilterShift), step: 1, neutral: 0,
                                            format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                            unit: "CC")
                                ValueSlider("M filter shift", value: $model.controls.mFilterShift, in: Controls.range(\.mFilterShift), step: 1, neutral: 0,
                                            format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)),
                                            unit: "CC")
                            }
                            ValueSlider("Preflash", value: $model.controls.preflash, in: Controls.range(\.preflash), step: 0.001,
                                        format: .number.precision(.fractionLength(3)))
                                .help("A flash of plain light on the paper before the print, so light tones such as a bright sky gain some tone. It darkens the whole print: lower the print exposure to bring the mid-tones back.")
                        }
                        AdjustmentGroup("Burn", systemImage: "sun.horizon", adjustment: .burn, isOn: $model.controls.burn) {
                            ValueSlider("Strength", value: $model.controls.burnStops, in: Controls.range(\.burnStops), step: 0.1,
                                        format: .number.precision(.fractionLength(1)), unit: "EV") {
                                model.isAdjustingBurn = $0
                            }
                            .help("Extra enlarger exposure where the photo is bright, as a darkroom printer burns in a sky: a pale sky darkens and gets its \(model.isBlackAndWhiteFilm ? "tone" : "colour") back, and the rest of the print stays as it is.")
                            ValueSlider("Threshold", value: $model.controls.burnThreshold, in: Controls.range(\.burnThreshold),
                                        step: 0.1, format: ExposureStrip.stops, unit: "EV") {
                                model.isAdjustingBurn = $0
                            }
                            .help("How bright a part of the photo must be to burn, in stops over mid-grey. About +2.5 is where a screen's white sits; lower takes in more. Holding a Burn slider shows what burns, white on black.")
                        }
                        DiffusionGroup(title: "Enlarger diffusion", adjustment: .enlargerDiffusion,
                                       filter: \.enlargerDiffusion)
                        AdjustmentGroup("Glare", systemImage: "sun.max", adjustment: .glare, isOn: $model.controls.glare) {
                            ValueSlider("Amount", value: $model.controls.glareAmount, in: Controls.range(\.glareAmount), step: 0.01,
                                        format: .number.precision(.fractionLength(2)), unit: "%")
                                .help("Stray light over the print as it's viewed, in percent of the light: it lifts the blacks.")
                        } options: {
                            ValueSlider("Roughness", value: $model.controls.glareRoughness, in: Controls.range(\.glareRoughness), step: 0.05,
                                        format: .number.precision(.fractionLength(2)))
                                .help("How unevenly the stray light falls.")
                            ValueSlider("Softness", value: $model.controls.glareSoftness, in: Controls.range(\.glareSoftness), step: 0.1,
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
    let adjustment: Controls.Adjustment
    let isOn: Binding<Bool>?
    let main: Main
    let options: Options
    @SceneStorage private var isExpanded: Bool
    @SceneStorage private var showsOptions: Bool

    init(_ title: String, systemImage: String, adjustment: Controls.Adjustment, isOn: Binding<Bool>? = nil,
         @ViewBuilder main: () -> Main, @ViewBuilder options: () -> Options) {
        self.title = title
        self.systemImage = systemImage
        self.adjustment = adjustment
        self.isOn = isOn
        self.main = main()
        self.options = options()
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
                        Button("Options") {
                            withAnimation(.snappy) { showsOptions.toggle() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(title) options")
                        .accessibilityValue(showsOptions ? "Expanded" : "Collapsed")
                    }
                    .disclosureGroupStyle(PhotosDisclosureStyle(contentIndent: 0) {})
                }
            }
            .padding(.top, 6)
            .disabled(isOn?.wrappedValue == false)
        } label: {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                    Text(title)
                        .font(.system(size: 14))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        .disclosureGroupStyle(PhotosDisclosureStyle(contentIndent: 14) {
            // Borderless draws it grey and greys it further when disabled; a foreground style
            // over it, inherited or set, would hold it at one shade.
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
        })
    }
}

extension AdjustmentGroup where Options == EmptyView {
    /// A group whose controls all show at once, with no Options.
    init(_ title: String, systemImage: String, adjustment: Controls.Adjustment, isOn: Binding<Bool>? = nil,
         @ViewBuilder main: () -> Main) {
        self.init(title, systemImage: systemImage, adjustment: adjustment, isOn: isOn, main: main) { EmptyView() }
    }
}

/// Photos' disclosure: a small grey chevron before the label that turns as it opens, and the
/// content under it, indented by `contentIndent`. The label is a button that opens it too, named
/// with the disclosure and whether it's open, so VoiceOver and the keyboard have that and the
/// chevron is for the pointer alone. `accessories` follow the label in its row, apart from it:
/// macOS gives everything in a disclosure group's label the disclosure triangle's role, so a
/// button there would read as one (#316). A group (indented) closed has a line under it, from its
/// symbol.
private struct PhotosDisclosureStyle<Accessories: View>: DisclosureGroupStyle {
    let contentIndent: CGFloat
    @ViewBuilder let accessories: Accessories

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 22, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.snappy) { configuration.isExpanded.toggle() }
                    }
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    configuration.label
                    accessories
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

/// Photos' on/off circle for an adjustment: a ring when it's off, a check when it's on. A switch
/// stands in for it with VoiceOver, its label hidden, so the label names the switch instead of
/// being an element of its own, never drawn.
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
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// The Film or Paper row, or a diffusion filter's: its choices in a pop-up menu (``ChoiceMenu``).
/// A row of its own, as `LabeledContent` gives its content at most about half the row, cutting
/// short names. The menu carries the title for assistive apps, as a slider or switch does here,
/// so the title beside it isn't an element of its own, read twice.
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
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            ChoiceMenu(sections: sections, selection: $selection, controls: $controls, choosing: choosing)
                .layoutPriority(1)
                .accessibilityLabel(title)
        }
    }
}

/// The Development row under a black-and-white film or print film with a choice of development
/// times: those its curves were measured at, in minutes. Choosing the standard one sets none, as
/// the controls are before a choice. Under any other stock, nothing.
///
/// To try (#352), the time shows five ways at once: the menu, and under it a time to scroll through
/// (``TimeWheel``), a clock face drawn here (``TimerFace``), the same as a stopwatch and the Mac's
/// own clock, a date picker's. Each sets the one time. One of them is to be kept.
private struct DevelopmentRow: View {
    @Environment(PhotoModel.self) private var model
    let stock: String
    let minutes: WritableKeyPath<Controls, Double?>

    var body: some View {
        @Bindable var model = model
        if let times = model.developmentTimes(of: stock, asking: model.controls[keyPath: minutes]) {
            let developing = { (time: Double) -> Controls in
                var controls = model.controls
                controls[keyPath: minutes] = time == times.standard ? nil : time
                return controls
            }
            let name = { (time: Double) -> String in
                let name = Measurement(value: time, unit: UnitDuration.minutes)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided))
                return time == times.standard ? "\(name) (standard)" : name
            }
            let time = Binding(get: { times.developed }, set: { model.controls = developing($0) })
            let help = "How long it's developed for, from the times its curves were measured at. Longer gives more contrast."
            ChoiceRow(title: "Development", sections: [.init(heading: nil, choices: times.measured.map { (name($0), $0) })],
                      selection: time, controls: $model.controls, choosing: developing)
                .help(help)
            HStack {
                Text("Development")
                    .fixedSize()
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                TimeWheel(title: "Development wheel", value: time, stops: times.measured, name: name)
                    .help(help)
            }
            HStack {
                clockTitle(name(times.developed))
                Spacer(minLength: 8)
                TimerFace(title: "Development clock", look: .clock, value: time, stops: times.measured,
                          standard: times.standard, valueText: name(times.developed))
                    .help(help)
            }
            HStack {
                clockTitle(name(times.developed))
                Spacer(minLength: 8)
                TimerFace(title: "Development stopwatch", look: .stopwatch, value: time, stops: times.measured,
                          standard: times.standard, valueText: name(times.developed))
                    .help(help)
            }
            HStack {
                clockTitle(name(times.developed))
                Spacer(minLength: 8)
                DatePicker("Development, the Mac's clock", selection: clock(time, stops: times.measured),
                           displayedComponents: .hourAndMinute)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    // The clock's hours are counted from the reference date, in its own time zone.
                    .environment(\.timeZone, .gmt)
                    .help(help)
            }
        }
    }

    /// A clock's title with the time under it: on one line beside the clock, they'd be wider than
    /// the panel.
    private func clockTitle(_ time: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Development")
            Text(time)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// `time` as the Mac's clock shows it: its minutes as the clock's hours, so the hour hand points
    /// at them as ``TimerFace``'s hand does, 6.5 minutes at half past six. A time the clock is set
    /// to lands on the nearest of `stops`. Minutes and seconds can't be the clock's own: a Mac's
    /// date picker has no seconds (`hourMinuteAndSecond` is watchOS's alone).
    private func clock(_ time: Binding<Double>, stops: [Double]) -> Binding<Date> {
        Binding {
            Date(timeIntervalSinceReferenceDate: time.wrappedValue.truncatingRemainder(dividingBy: TimerFace.turn) * 3600)
        } set: { date in
            time.wrappedValue = TimerFace.nearest(to: date.timeIntervalSinceReferenceDate / 3600, of: stops)
        }
    }
}

/// A time to scroll through, one of `stops`, as an iPhone's timer wheel is: macOS has no wheel
/// picker (`WheelPickerStyle` is iOS's and watchOS's). The stops are one above the other, shortest
/// first, in a window a row tall, which they fade into and out of at its edges. It's SwiftUI's
/// scroll view, which stops on a row (`viewAligned`): the row in the window is the value. With
/// Full Keyboard Access the up and down arrows go a stop. While it's scrolled, the model renders
/// previews alone and the change is one step to undo, as while a slider is held, and the trackpad
/// clicks at each stop. To try for the development time (#352).
private struct TimeWheel: View {
    let title: String
    @Binding var value: Double
    let stops: [Double]
    let name: (Double) -> String
    /// The stop in the window, as the scroll view has it.
    @State private var shown: Double?
    @Environment(PhotoModel.self) private var model

    private static let rowHeight: CGFloat = 24
    private static let height: CGFloat = 30

    init(title: String, value: Binding<Double>, stops: [Double], name: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.stops = stops
        self.name = name
        _shown = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        ScrollViewReader { wheel in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(stops, id: \.self) { stop in
                        Text(name(stop))
                            .monospacedDigit()
                            .foregroundStyle(stop == value ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.rowHeight)
                    }
                }
                .scrollTargetLayout()
            }
            // On the value from the start: the scroll position's own first value doesn't turn it there.
            .onAppear { wheel.scrollTo(value, anchor: .center) }
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $shown, anchor: .center)
        .scrollIndicators(.hidden)
        // So the first and the last stop reach the window's middle.
        .contentMargins(.vertical, (Self.height - Self.rowHeight) / 2, for: .scrollContent)
        .frame(width: 140, height: Self.height)
        // The rows fade out at the window's edges, as a wheel's turn away. After the frame, for the
        // window's own height: the scroll view makes itself taller, by its margins.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                   .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .background(.quinary, in: .rect(cornerRadius: 5))
        .onChange(of: shown) { _, stop in
            if let stop, stop != value {
                value = stop
            }
        }
        // Set elsewhere, by the menu or Undo, say: the wheel goes to it, at once. Turning there, it
        // would pass the stops between, and set each as the value.
        .onChange(of: value) { _, value in
            if shown != value {
                shown = value
            }
        }
        // While it's scrolled by hand, and as it comes to rest: not while it turns to a value set elsewhere.
        .onScrollPhaseChange { _, phase in
            model.isAdjusting = phase == .interacting || phase == .decelerating
        }
        .sensoryFeedback(.alignment, trigger: value) { _, _ in model.isAdjusting }
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .up: step(by: -1)
            case .down: step(by: 1)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(name(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(by: 1)
            case .decrement: step(by: -1)
            @unknown default: break
            }
        }
    }

    /// To the stop `places` on from the value, if there is one.
    private func step(by places: Int) {
        guard let index = stops.firstIndex(of: value), stops.indices.contains(index + places) else { return }
        value = stops[index + places]
    }
}

/// A clock face to set a time among `stops` on, as on an analog timer. A turn is 12 minutes, which
/// both stocks' times are within, so a time is where a clock has that hour: 6.5 minutes at half
/// past six. It's drawn one of two ways (``Look``), each with a dot at each stop, the `standard`
/// one's larger and brighter, and a hand to the value. A click or a drag on the face turns the hand
/// to the stop nearest the pointer's direction from the centre, with a trackpad click at each stop
/// a drag reaches; meanwhile the model renders previews alone and the change is one step to undo,
/// as while a slider is held. With Full Keyboard Access the arrow keys go a stop. Accessibility
/// finds an AppKit slider in its place (``SliderElement``), as for a ``ValueSlider``. Drawn here:
/// AppKit's circular slider is a 24-point knob that draws no marks, the Mac's clock, a date
/// picker's, is for a time of day, and the Clock app's stopwatch is no control of the system's.
/// To try for the development time (#352).
private struct TimerFace: View {
    /// How a face is drawn.
    enum Look {
        /// Small and plain, on a disc: a tick at each minute, longer at each quarter turn, and a
        /// hand from the centre, in the accent colour under the pointer and while dragged.
        case clock
        /// After the Clock app's stopwatch, larger and with no disc: a rim of fine ticks, ten a
        /// minute, the stops' dots and the minutes' numbers within it, and a thin orange hand
        /// through a ring at the centre. As wide as the row has room for beside the longest time.
        case stopwatch

        var diameter: CGFloat {
            switch self {
            case .clock: 72
            case .stopwatch: 132
            }
        }
    }

    let title: String
    let look: Look
    @Binding var value: Double
    let stops: [Double]
    let standard: Double
    let valueText: String
    @State private var isDragging = false
    @State private var isHovered = false
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled

    /// The minutes of a full turn.
    nonisolated static let turn = 12.0

    /// Of `stops`, the one nearest `minutes` around the face, where a turn's end is its start.
    static func nearest(to minutes: Double, of stops: [Double]) -> Double {
        func apart(_ stop: Double) -> Double {
            let gap = abs(stop - minutes).truncatingRemainder(dividingBy: turn)
            return min(gap, turn - gap)
        }
        // Never empty: a stock with a choice of times has at least two.
        return stops.min { apart($0) < apart($1) }!
    }

    var body: some View {
        let handStyle = isHovered || isDragging ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(size.width, size.height) / 2
            /// Where the hand points for `minutes`, `inset` from the rim.
            func point(at minutes: Double, inset: CGFloat) -> CGPoint {
                let angle = minutes / Self.turn * 2 * .pi
                return CGPoint(x: centre.x + sin(angle) * (radius - inset), y: centre.y - cos(angle) * (radius - inset))
            }
            func dot(at point: CGPoint, radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
            }
            func line(from start: CGPoint, to end: CGPoint) -> Path {
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                return line
            }
            /// A dot at each stop, `inset` from the rim.
            func drawStops(inset: CGFloat) {
                for stop in stops {
                    context.fill(dot(at: point(at: stop, inset: inset), radius: stop == standard ? 3 : 2),
                                 with: .style(stop == standard ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                }
            }
            switch look {
            case .clock:
                for minute in 1...Int(Self.turn) {
                    context.stroke(line(from: point(at: Double(minute), inset: 3),
                                        to: point(at: Double(minute), inset: minute.isMultiple(of: 3) ? 8 : 6)),
                                   with: .style(.tertiary), lineWidth: 1)
                }
                drawStops(inset: 14)
                context.stroke(line(from: centre, to: point(at: value, inset: 20)), with: .style(handStyle),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.fill(dot(at: centre, radius: 3), with: .style(handStyle))
            case .stopwatch:
                let ticksAMinute = 10
                for tick in 0..<Int(Self.turn) * ticksAMinute {
                    let minutes = Double(tick) / Double(ticksAMinute)
                    let isMinute = tick.isMultiple(of: ticksAMinute), isHalfMinute = tick.isMultiple(of: ticksAMinute / 2)
                    context.stroke(line(from: point(at: minutes, inset: 0),
                                        to: point(at: minutes, inset: isMinute ? 8 : isHalfMinute ? 6 : 4)),
                                   with: .style(isMinute ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)),
                                   lineWidth: isMinute ? 1.5 : 1)
                }
                for minute in 1...Int(Self.turn) {
                    context.draw(Text(verbatim: "\(minute)").font(.system(size: 13)),
                                 at: point(at: Double(minute), inset: 25))
                }
                drawStops(inset: 13)
                // The hand goes on through the centre, a fifth of the radius past it, around a ring there.
                let ring: CGFloat = 3.5, back = value + Self.turn / 2
                let orange = GraphicsContext.Shading.color(.orange)
                context.stroke(line(from: point(at: value, inset: 2), to: point(at: value, inset: radius - ring)),
                               with: orange, lineWidth: 1.5)
                context.stroke(line(from: point(at: back, inset: radius - ring), to: point(at: back, inset: radius * 0.8)),
                               with: orange, lineWidth: 1.5)
                context.stroke(dot(at: centre, radius: ring), with: orange, lineWidth: 1.5)
            }
        }
        .frame(width: look.diameter, height: look.diameter)
        .background {
            if look == .clock {
                Circle().fill(.quinary)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(.circle)
        .onHover { isHovered = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !isDragging {
                    isDragging = true
                    model.isAdjusting = true
                }
                let across = drag.location.x - look.diameter / 2, down = drag.location.y - look.diameter / 2
                // At the centre the pointer has no direction, and a tremble there would spin the hand.
                guard hypot(across, down) >= 6 else { return }
                let stop = Self.nearest(to: atan2(across, -down) / (2 * .pi) * Self.turn, of: stops)
                if stop != value {
                    value = stop
                }
            }
            .onEnded { _ in endDrag() })
        .sensoryFeedback(.alignment, trigger: value) { _, _ in isDragging }
        // A drag cut off as the face goes (its window closed, say) never ends otherwise.
        .onDisappear {
            if isDragging {
                endDrag()
            }
        }
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: step(by: -1)
            case .right, .up: step(by: 1)
            default: break
            }
        }
        // Accessibility finds the AppKit slider behind it instead.
        .accessibilityHidden(true)
        .background {
            SliderElement(title: title, value: value, range: stops[0]...stops[stops.count - 1], valueText: valueText,
                          set: { asked in
                              // Never empty, as in `nearest(to:of:)`.
                              value = stops.min { abs($0 - asked) < abs($1 - asked) }!
                          },
                          move: { step(by: $0 ? 1 : -1) })
        }
    }

    /// To the stop `places` on from the value, if there is one.
    private func step(by places: Int) {
        guard let index = stops.firstIndex(of: value), stops.indices.contains(index + places) else { return }
        value = stops[index + places]
    }

    private func endDrag() {
        isDragging = false
        model.isAdjusting = false
    }
}

/// Stocks under headings, from their profiles: slides, still negatives or papers, cine stocks,
/// then the black-and-white ones, whatever else they are.
private func stockSections(_ stocks: [ProfileInfo]) -> [ChoiceMenu<String>.Section] {
    let groups = Dictionary(grouping: stocks) { stock -> String in
        if stock.channelModel == .blackAndWhite { return "Black & White" }
        if stock.type == .positive { return "Slide" }
        if stock.use == .cine { return "Cine" }
        return stock.stage == .filming ? "Negative" : "Still"
    }
    return ["Slide", "Negative", "Still", "Cine", "Black & White"].compactMap { heading in
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
            // What the pointer shows and what's chosen undo in one step.
            parent.model.beginChange()
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
                parent.model.endChange()
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

/// The exposure, in stops over the photo as shot, where each photo opens. Its dots are where each
/// way of metering puts it for this photo (``MeteringMark``): a click on one puts the exposure
/// there. A dot is in the accent colour while the exposure is on it. With the pointer on a dot, a
/// bubble says what its mark meters, and the canvas tints the region it meters. As a drag passes a
/// dot, the trackpad clicks. Marks whose dots would be less than a dot apart share one, at the mean
/// of their readings, whose bubble has each.
struct ExposureStrip: View {
    @Environment(PhotoModel.self) private var model
    /// The strip's width, for how near two readings put their dots.
    @State private var width: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        let readings = model.photo.map { photo in
            MeteringMark.allCases.compactMap { mark in photo.metering.ev[mark.rawValue].map { (mark: mark, ev: $0) } }
        } ?? []
        let exposure = model.controls.exposureEV
        let range = model.exposureRange
        // Two dots' width, in stops: readings nearer than that would draw dots less than a dot apart,
        // which read as one, and a click between them could be for either. Before the strip is
        // measured, only the same reading.
        let nearby = width > 0 ? 2 * ThumbnailStrip.dotSize / width * (range.upperBound - range.lowerBound) : 0
        let dots = Self.dots(of: readings, within: nearby)
        let marks = dots.map { dot in
            // On it within half of a drag's step: a drag stops nearest it there.
            ThumbnailStrip.Mark(items: dot.marks.map { (systemImage: $0.systemImage, name: $0.name, about: $0.about) },
                                value: dot.value, isOn: abs(exposure - dot.value) < 0.05) {
                model.controls.exposureEV = dot.value
            }
        }
        // The dot under the pointer.
        let hoveredDot = Binding<Double?> {
            dots.first { !Set($0.marks).isDisjoint(with: model.hoveredMarks) }?.value
        } set: { value in
            model.hoveredMarks = dots.first { $0.value == value }?.marks ?? []
        }
        ThumbnailStrip("Exposure", value: $model.controls.exposureEV, in: range, step: 0.1, format: Self.stops,
                       unit: "EV", frames: model.strips[.exposure], marks: marks, hoveredMark: hoveredDot) {
            model.isAdjustingExposure = $0
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A click as a drag passes a dot, one for a dot marks share: a fast drag jumps over the
        // step nearest it between two of the pointer's moves, so a click on landing there would miss it.
        .sensoryFeedback(.alignment, trigger: exposure) { old, new in
            model.isAdjustingExposure && dots.contains { (old < $0.value && $0.value <= new) || (new <= $0.value && $0.value < old) }
        }
        .disabled(model.photo == nil)
        // The pointer may be on a dot as the tab changes: no longer.
        .onDisappear { model.hoveredMarks = [] }
    }

    static let stops = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        .sign(strategy: .always(includingZero: false))

    /// The dots of `readings`: one for each run of readings no more than `nearby` stops from the
    /// one before, at their mean, with its marks in ``MeteringMark``'s order.
    static func dots(of readings: [(mark: MeteringMark, ev: Double)], within nearby: Double)
        -> [(marks: [MeteringMark], value: Double)] {
        var runs: [[(mark: MeteringMark, ev: Double)]] = []
        for reading in readings.sorted(by: { $0.ev < $1.ev }) {
            if let last = runs.last?.last, reading.ev - last.ev <= nearby {
                runs[runs.count - 1].append(reading)
            } else {
                runs.append([reading])
            }
        }
        return runs.map { run in
            (marks: run.map(\.mark).sorted { $0.rawValue < $1.rawValue }, value: run.map(\.ev).reduce(0, +) / Double(run.count))
        }
    }
}

private extension MeteringMark {
    /// Its symbol, in its dot's bubble.
    var systemImage: String {
        switch self {
        case .asShot: "camera"
        case .centreWeighted: "camera.metering.center.weighted"
        case .objects: "viewfinder"
        case .people: "person.2"
        case .faces: "face.smiling"
        }
    }

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
        case .centreWeighted: "meters the whole frame, the centre counting most"
        case .objects: "meters what stands out in the frame"
        case .people: "meters the people in the frame"
        case .faces: "meters the faces in the frame"
        }
    }
}

/// A diffusion filter on the camera's lens or the enlarger's: the filter and its strength, with its
/// glow's size and warmth under Options, each the controls at its key path.
private struct DiffusionGroup: View {
    @Environment(PhotoModel.self) private var model
    let title: String
    let adjustment: Controls.Adjustment
    let filter: WritableKeyPath<Controls, Parameters.DiffusionFilter>

    var body: some View {
        @Bindable var model = model
        let settings = $model.controls[dynamicMember: filter]
        AdjustmentGroup(title, systemImage: "camera.filters", adjustment: adjustment, isOn: settings.active) {
            ChoiceRow(title: "Filter",
                      sections: [.init(heading: nil, choices: Parameters.DiffusionFilter.Family.allCases.map { ($0.name, $0) })],
                      selection: settings.filterFamily, controls: $model.controls) { choice in
                var choosing = model.controls
                choosing[keyPath: filter].filterFamily = choice
                return choosing
            }
            .help("Glimmerglass keeps detail and glows faintly; Black Pro-Mist gives a tight, punchy halo; Pro-Mist a broader pastel haze; CineBloom a wide glow that lifts the whole frame.")
            ValueSlider("Strength", value: settings.strength, in: range(\.strength), step: 0.125,
                        format: .number.precision(.fractionLength(0...3)))
                .help("The filter's grade, as filters are sold: 1/8, 1/4, 1/2, 1 and 2. Stronger spreads more of the light into the glow.")
        } options: {
            ValueSlider("Size", value: settings.spatialScale, in: range(\.spatialScale), step: 0.05, neutral: 1,
                        format: .number.precision(.fractionLength(2)))
                .help("How far the glow reaches, over the filter's own.")
            ValueSlider("Warmth", value: settings.haloWarmth, in: range(\.haloWarmth), step: 0.05, neutral: 0,
                        format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
                .help("Warmer light at the glow's outer rim and cooler at its centre, over the filter's own; below 0, the reverse.")
        }
    }

    /// The range of one of this filter's settings (``Controls/ranges``).
    private func range(_ setting: WritableKeyPath<Parameters.DiffusionFilter, Double>) -> ClosedRange<Double> {
        Controls.range(filter.appending(path: setting))
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
/// (``SliderRuler``) and the value's line in the accent colour. Dragging anywhere on it moves the
/// value from where it was, the bar's width for the whole range, from line to line, with a
/// trackpad click at each: a stronger one at a long line. Clicking the value opens it for typing,
/// to any step, between lines too. With Full Keyboard Access the arrow keys move it a line and
/// Return opens it for typing. With Increase Contrast, the fill and the line are stronger.
/// SwiftUI's `Slider` can't be restyled (there's no slider style to conform to), so the bar is
/// drawn here, and accessibility finds an AppKit slider in its place (``SliderElement``).
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
    /// Where the value is written on the bar, in ``bar``'s space: a click there opens it for typing.
    @State private var valueFrame: CGRect = .zero
    @State private var isTyping = false
    @State private var typedText = ""
    @FocusState private var isFieldFocused: Bool
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

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

    /// The bar's coordinate space, where the drag and ``valueFrame`` are measured.
    nonisolated private static let bar = "bar"
    /// How far a click can move and still be a click: less than half the space between two lines,
    /// so it never moves the value, even one typed between lines.
    private static let clickTolerance = SliderRuler.minimumSpacing / 2

    var body: some View {
        let ruler = SliderRuler(range: range, step: step, neutral: neutral, width: width)
        // Sizes and shades measured from Photos' (macOS 26) screenshots. Shades the system has are its
        // own (the measured text is `.secondary` in dark mode); the rest as the primary style's opacity.
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(valueText)
                .monospacedDigit()
                .opacity(isTyping ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.bar)) } action: { valueFrame = $0 }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background {
            let x = range.fraction(of: value) * width, origin = range.fraction(of: neutral ?? range.lowerBound) * width
            let isActive = isHovered || dragStart != nil
            ZStack(alignment: .leading) {
                Rectangle().fill(.quinary)
                Rectangle().fill(.primary.opacity(contrast == .increased ? 0.35 : 0.19))
                    .frame(width: abs(x - origin))
                    .offset(x: min(x, origin))
                Rectangle().fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(contrast == .increased ? 0.6 : 0.22)))
                    .frame(width: 3)
                    .offset(x: min(max(x - 1.5, 0), width - 3))
                if isActive {
                    // Photos' ruler, over the line, its lines on the values a drag stops on, each
                    // centred under the value line as it stops there.
                    Canvas { context, size in
                        let hairline = 1 / displayScale
                        for line in ruler.lines {
                            let lineX = ((range.fraction(of: line.value) * size.width - hairline / 2) * displayScale).rounded() / displayScale
                            context.fill(Path(CGRect(x: min(max(lineX, 0), size.width - hairline), y: 0, width: hairline,
                                                     height: line.rank == .short ? 3 : 5)),
                                         with: .style(line.rank == .bright ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.tertiary)))
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
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.bar))
            .onChanged { drag in
                if dragStart == nil {
                    finishTyping()
                    model.isAdjusting = true
                    onEditingChanged(true)
                }
                let start = dragStart ?? value
                dragStart = start
                // A click's tremble leaves the value as it is, even between two lines.
                guard width > 0, value != start || abs(drag.translation.width) >= Self.clickTolerance else { return }
                value = ruler.nearestLine(to: start + drag.translation.width / width * (range.upperBound - range.lowerBound))
            }
            .onEnded { drag in
                endDrag()
                if abs(drag.translation.width) < Self.clickTolerance, valueFrame.contains(drag.startLocation) {
                    startTyping()
                }
            })
        .coordinateSpace(.named(Self.bar))
        // A click at each line the drag reaches, the strongest of them when it passes several at once.
        // A Mac's trackpad plays only these two: SwiftUI's other feedback, `impact(weight:intensity:)`
        // with it, plays only on iOS and watchOS.
        .sensoryFeedback(trigger: value) { old, new in
            guard dragStart != nil else { return nil }
            return switch ruler.strongestLine(from: old, to: new) {
            case .short: .alignment
            case .long, .bright: .levelChange
            case nil: nil
            }
        }
        // A drag cut off as the slider goes (its window closed, say) never ends otherwise.
        .onDisappear {
            if dragStart != nil {
                endDrag()
            }
        }
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left: moveOneLine(upward: false, on: ruler)
            case .right: moveOneLine(upward: true, on: ruler)
            default: break
            }
        }
        .onKeyPress(.return) {
            startTyping()
            return .handled
        }
        // Accessibility finds the AppKit slider behind it instead.
        .accessibilityHidden(true)
        .background {
            SliderElement(title: title, value: value, range: range, valueText: valueText,
                          set: { value = range.stepped($0, by: step) },
                          move: { moveOneLine(upward: $0, on: ruler) })
                .accessibilityAction(named: "Type Value", startTyping)
        }
        // Over the bar rather than in it: outside what accessibility hides, and out of the drag's way.
        .overlay(alignment: .trailing) {
            if isTyping {
                HStack(spacing: 4) {
                    TextField(title, text: $typedText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: valueFrame.width + 16)
                        .focused($isFieldFocused)
                        .onAppear { isFieldFocused = true }
                        .onSubmit(finishTyping)
                        .onExitCommand { isTyping = false }
                        .onChange(of: isFieldFocused) { _, isFocused in
                            if !isFocused {
                                finishTyping()
                            }
                        }
                    if !unit.isEmpty {
                        Text(unit)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(.trailing, 8)
            }
        }
    }

    private var valueText: String {
        unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)"
    }

    private func moveOneLine(upward: Bool, on ruler: SliderRuler) {
        if let line = ruler.line(after: value, upward: upward) {
            value = line
        }
    }

    private func startTyping() {
        typedText = value.formatted(format)
        isTyping = true
    }

    /// Sets the typed value, to its nearest step within the range (between lines too). Either "." or
    /// "," is the decimal separator: no value here reaches a thousand, and the locale's parsing would
    /// read the other one as a thousands separator, "1.25" as 125 where the decimals are ",". Text
    /// that doesn't read as a number leaves the value as it was, with the beep a Mac's own number
    /// fields give.
    private func finishTyping() {
        guard isTyping else { return }
        isTyping = false
        guard typedText != value.formatted(format) else { return }
        let text = typedText.replacing(/[.,]/, with: format.locale.decimalSeparator ?? ".")
        do {
            value = range.stepped(try format.parseStrategy.parse(text), by: step)
        } catch {
            NSSound.beep()
        }
    }

    private func endDrag() {
        dragStart = nil
        model.isAdjusting = false
        onEditingChanged(false)
    }
}

/// A ``ValueSlider`` or a ``ThumbnailStrip`` as accessibility sees it: a horizontal slider, reading
/// the value as the control shows it. VoiceOver's increment and decrement move it as the arrow keys
/// do, a slider a line and a strip a step; an assistive app that sets the value, such as Voice
/// Control, sets it to the nearest step, as typing or a drag does. An AppKit view, as SwiftUI can't
/// give an element an orientation: its stand-in, a `Slider` in `accessibilityRepresentation`, has
/// none, and assistive apps and XCUITest's `adjust(toNormalizedSliderPosition:)` need it to know
/// which way the slider runs (#317, #339).
private struct SliderElement: NSViewRepresentable {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let set: (Double) -> Void
    let move: (_ upward: Bool) -> Void

    func makeNSView(context: Context) -> Element { Element() }

    func updateNSView(_ element: Element, context: Context) {
        let oldValue = element.slider?.value
        element.slider = self
        element.isEnabled = context.environment.isEnabled
        if let oldValue, oldValue != value {
            NSAccessibility.post(element: element, notification: .valueChanged)
        }
    }

    final class Element: NSView, NSAccessibilitySlider {
        fileprivate var slider: SliderElement?
        fileprivate var isEnabled = true

        // The pointer goes through to the control, which SwiftUI draws and drags.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .slider }
        override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }
        override func accessibilityLabel() -> String? { slider?.title }
        override func accessibilityValue() -> Any? { slider?.value }
        override func accessibilityValueDescription() -> String? { slider?.valueText }
        override func accessibilityMinValue() -> Any? { slider?.range.lowerBound }
        override func accessibilityMaxValue() -> Any? { slider?.range.upperBound }
        override func isAccessibilityEnabled() -> Bool { isEnabled }

        override func setAccessibilityValue(_ value: Any?) {
            guard isEnabled, let number = value as? NSNumber else { return }
            slider?.set(number.doubleValue)
        }

        override func accessibilityPerformIncrement() -> Bool { perform { $0.move(true) } }
        override func accessibilityPerformDecrement() -> Bool { perform { $0.move(false) } }

        private func perform(_ action: (SliderElement) -> Void) -> Bool {
            guard isEnabled, let slider else { return false }
            action(slider)
            return true
        }
    }
}

/// A control as Photos shows its main adjustments: frames of the photo across its range
/// (``Controls/Strip``), with a line at the value; `marks` are dots under it, each with a bubble
/// (a popover) under the pointer. As in Photos, the value itself shows on the control's bar under
/// Options. Clicking or dragging along it sets the value there, and clicking a dot chooses its
/// mark; with Full Keyboard Access the arrow keys step it. Accessibility finds an AppKit slider in
/// its place (``SliderElement``), reading the value in `format` and `unit`, with an action to choose
/// each mark, as a click on its dot does. Drawn here, as Photos' strip isn't one of SwiftUI's or
/// AppKit's controls.
private struct ThumbnailStrip: View {
    /// A dot under the strip, at `value`.
    struct Mark {
        /// What it stands for, which its bubble shows: a symbol, a name and what it is, for each.
        let items: [(systemImage: String, name: String, about: String)]
        let value: Double
        /// Whether the value is on it: it's then in the accent colour.
        let isOn: Bool
        /// What a click on its dot does.
        let choose: () -> Void

        var name: String { items.map(\.name).formatted(.list(type: .and)) }
    }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: FloatingPointFormatStyle<Double>
    let unit: String
    /// None until the model has made them.
    let frames: [CGImage]?
    let marks: [Mark]
    /// The value of the mark whose dot the pointer is on.
    @Binding var hoveredMark: Double?
    let onEditingChanged: (Bool) -> Void
    @State private var width: CGFloat = 0
    @State private var isDragging = false
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         format: FloatingPointFormatStyle<Double>, unit: String = "", frames: [CGImage]?,
         marks: [Mark] = [], hoveredMark: Binding<Double?> = .constant(nil),
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
        self.unit = unit
        self.frames = frames
        self.marks = marks
        _hoveredMark = hoveredMark
        self.onEditingChanged = onEditingChanged
    }

    /// A dot's width, in points: 6 under the pointer.
    static let dotSize: CGFloat = 4
    /// How far from a dot, in points, a click still lands on it: about a third of a stop, where the
    /// dots alone are ``dotSize`` across.
    private static let dotReach: CGFloat = 8
    /// The height of the dots' row, the dots 4 points under the frames.
    private static let dotsHeight: CGFloat = 8
    /// How far under the dots' row a click or the pointer still reaches its dots: into the space
    /// above the next control, so the row is taller to point at than it is in the layout.
    private static let dotsReachBelow: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
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
                    .offset(x: min(max(range.fraction(of: value) * width - 1, 0), width - 2))
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
                    value = range.stepped(range.lowerBound + drag.location.x / width * (range.upperBound - range.lowerBound), by: step)
                }
                .onEnded { _ in endDrag() })
            // A drag cut off as the strip goes (its window closed, say) never ends otherwise.
            .onDisappear {
                if isDragging {
                    endDrag()
                }
            }
            if !marks.isEmpty {
                ZStack {
                    ForEach(marks, id: \.value) { mark in
                        let size = mark.value == hoveredMark ? Self.dotSize + 2 : Self.dotSize
                        Circle().fill(mark.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: size, height: size)
                            // As tall as the row reaches, so the bubble hangs from below where the
                            // pointer can be on the dot: under the pointer, it would take the hover
                            // away from the dot, and close.
                            .frame(height: Self.dotsHeight + Self.dotsReachBelow)
                            .popover(isPresented: Binding {
                                hoveredMark == mark.value
                            } set: { isPresented in
                                if !isPresented, hoveredMark == mark.value {
                                    hoveredMark = nil
                                }
                            }, attachmentAnchor: .point(.bottom), arrowEdge: .bottom) {
                                bubble(for: mark)
                                    // It follows the pointer: a click outside it is for the strip.
                                    .interactiveDismissDisabled()
                            }
                            .position(x: range.fraction(of: mark.value) * width,
                                      y: (Self.dotsHeight + Self.dotsReachBelow) / 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.dotsHeight + Self.dotsReachBelow,
                       maxHeight: Self.dotsHeight + Self.dotsReachBelow)
                .contentShape(.rect)
                .onContinuousHover { phase in
                    var hovered: Double?
                    if case .active(let location) = phase {
                        hovered = dot(at: location.x)?.value
                    }
                    if hovered != hoveredMark {
                        hoveredMark = hovered
                    }
                }
                .onTapGesture { location in
                    dot(at: location.x)?.choose()
                }
                // In the layout, only the row: what it reaches below lies in the space over the
                // next control.
                .padding(.bottom, -Self.dotsReachBelow)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left: moveOneStep(upward: false)
            case .right: moveOneStep(upward: true)
            default: break
            }
        }
        // Accessibility finds the AppKit slider behind it instead.
        .accessibilityHidden(true)
        .background {
            SliderElement(title: title, value: value, range: range,
                          valueText: unit.isEmpty ? value.formatted(format) : "\(value.formatted(format)) \(unit)",
                          set: { value = range.stepped($0, by: step) },
                          move: { moveOneStep(upward: $0) })
                .accessibilityActions {
                    ForEach(marks, id: \.value) { mark in
                        Button(mark.name, action: mark.choose)
                    }
                }
        }
    }

    private func moveOneStep(upward: Bool) {
        value = range.stepped(value + (upward ? step : -step), by: step)
    }

    /// What a dot's bubble shows: each thing it stands for, its symbol beside its name and what it
    /// is.
    private func bubble(for mark: Mark) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(mark.items, id: \.name) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.systemImage)
                        .font(.title)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .fontWeight(.semibold)
                        Text("\(item.about.prefix(1).uppercased())\(item.about.dropFirst()).")
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The mark whose dot is nearest `x`, within ``dotReach``.
    private func dot(at x: CGFloat) -> Mark? {
        func distance(_ mark: Mark) -> CGFloat { abs(range.fraction(of: mark.value) * width - x) }
        return marks.filter { distance($0) <= Self.dotReach }.min { distance($0) < distance($1) }
    }

    private func endDrag() {
        isDragging = false
        model.isAdjusting = false
        onEditingChanged(false)
    }
}

/// A ``ValueSlider``'s ruler: a line at each value a drag stops on. A line for every step when
/// they're at least ``minimumSpacing`` apart; when they aren't, every 2nd, 5th, 10th… step, so
/// the lines still fall on round values. Lines are counted from the neutral value (0 without
/// one), every 5th long and every 10th bright, and the range's two ends are lines too.
struct SliderRuler {
    enum Rank: Comparable {
        case short, long, bright
    }

    struct Line: Equatable {
        let value: Double
        let rank: Rank
    }

    /// The closest two lines get, in points. Closer, they blur into grey, and a trackpad click at
    /// each buzzes.
    static let minimumSpacing: CGFloat = 4

    /// From the lower bound up.
    let lines: [Line]
    /// Half a step: values closer than this to a line are on it.
    private let tolerance: Double

    init(range: ClosedRange<Double>, step: Double, neutral: Double?, width: CGFloat) {
        let steps = Int(((range.upperBound - range.lowerBound) / step).rounded())
        let pointsPerStep = width / CGFloat(steps)
        let stepsPerLine = [1, 2, 5, 10, 20, 50, 100].first { CGFloat($0) * pointsPerStep >= Self.minimumSpacing } ?? steps
        let anchor = Int((((neutral ?? 0) - range.lowerBound) / step).rounded())
        lines = (0...steps).compactMap { index in
            let fromAnchor = index - anchor
            let isCounted = fromAnchor.isMultiple(of: stepsPerLine)
            guard isCounted || index == 0 || index == steps else { return nil }
            let count = fromAnchor / stepsPerLine
            let rank: Rank = !isCounted ? .short : count.isMultiple(of: 10) ? .bright : count.isMultiple(of: 5) ? .long : .short
            // The value as `stepped(_:by:)` makes it, so a step typed and the line are one value, and
            // the upper end exactly, as rounding can land it a hair either side.
            return Line(value: index == steps ? range.upperBound : range.lowerBound + Double(index) * step, rank: rank)
        }
        tolerance = step / 2
    }

    /// The line nearest `value`: where a drag to it stops.
    func nearestLine(to value: Double) -> Double {
        // Never empty: the lower bound is always a line.
        lines.min { abs($0.value - value) < abs($1.value - value) }!.value
    }

    /// The next line above `value`, or below it, from a line or from between two; nil past the last.
    func line(after value: Double, upward: Bool) -> Double? {
        upward ? lines.first { $0.value > value + tolerance }?.value : lines.last { $0.value < value - tolerance }?.value
    }

    /// The strongest line a move from `old` to `new` reaches: those it passes and the one it stops
    /// on, not the one it leaves.
    func strongestLine(from old: Double, to new: Double) -> Rank? {
        lines.filter { line in
            new > old
                ? line.value > old + tolerance && line.value < new + tolerance
                : line.value < old - tolerance && line.value > new - tolerance
        }
        .map(\.rank)
        .max()
    }
}

extension ClosedRange<Double> {
    /// Where `value` lies along the range: 0 at its lower bound, 1 at its upper.
    func fraction(of value: Double) -> Double {
        (value - lowerBound) / (upperBound - lowerBound)
    }

    /// `value` at the nearest `step` from the lower bound, within the range: what a slider sets.
    func stepped(_ value: Double, by step: Double) -> Double {
        let stepped = lowerBound + ((value - lowerBound) / step).rounded() * step
        return Swift.min(Swift.max(stepped, lowerBound), upperBound)
    }
}
