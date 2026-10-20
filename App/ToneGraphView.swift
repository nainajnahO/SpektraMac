import Charts
import simd
import SpektraEngine
import SwiftUI

// MARK: - Tone graph

/// The print's tone curve, drawn as Photos draws Levels: behind it, how much of the photo is at
/// each tone of the film's exposure. Both run over the photo's tones in stops over mid-grey, the
/// Exposure control's units (``ToneGraph``). The menu shows the neutral curve, or one colour's over
/// the other two, which spread apart with the filter shifts. Its points set the print exposure and
/// the contrasts (``ToneCurveLayer``). With the burn on, shading from a line at its threshold marks
/// the tones it takes, and a dashed line where they print
/// (``ToneCurve/burned(stops:threshold:exposures:)``). The sliders under Options and in Enlarger
/// give exact values, and stand in for it with VoiceOver and the keyboard.
struct ToneGraphView: View {
    @Environment(PhotoModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @SceneStorage("toneGraph.channel") private var channel = ToneChannel.neutral

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
                    .onEnded { _ in endDrag() })
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
        // A drag cut off as the graph goes (its window closed, say) never ends otherwise.
        .onDisappear {
            if isPressed {
                endDrag()
            }
        }
    }

    private func endDrag() {
        if let drag {
            model.isAdjusting = false
            if drag.handle == .burn {
                model.isAdjustingBurn = false
            }
        }
        isPressed = false
        drag = nil
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
            set(\.printExposure, to: rendered.printExposure * pow(10, -Double(paper)))
        case .shadows:
            scale(\.printShadowContrast, of: curve, rendered: rendered, at: drag.tone, to: drag.print + drag.moved.y)
        case .highlights:
            scale(\.printHighlightContrast, of: curve, rendered: rendered, at: drag.tone, to: drag.print + drag.moved.y)
        case nil:
            scale(\.printContrast, of: curve, rendered: rendered, at: drag.tone, to: drag.print + drag.moved.y)
        case .burn:
            // The line follows the pointer sideways; down burns more, the graph's height for the
            // strength's whole range.
            let strengths = Controls.range(\.burnStops)
            set(\.burnThreshold, to: drag.controls.burnThreshold + Double(drag.moved.x))
            set(\.burnStops, to: drag.controls.burnStops - Double(drag.moved.y) * (strengths.upperBound - strengths.lowerBound))
        }
    }

    /// The contrasts scale the paper's response about its exposure 0 (``ToneGraph/Point/paper``): a
    /// factor f gives exposure E the response `curve` has at f·E. So for brightness `print` at
    /// `tone`, f is the paper's exposure where `curve` has that brightness, over the one at `tone`.
    private func scale(_ contrast: WritableKeyPath<Controls, Double> & Sendable, of curve: ToneCurve, rendered: Controls,
                       at tone: Float, to print: Float) {
        let reached = curve.tone(where: curve.print, is: print, near: tone)
        let factor = curve.value(of: curve.paper, at: reached) / curve.value(of: curve.paper, at: tone)
        guard factor.isFinite else { return }
        set(contrast, to: rendered[keyPath: contrast] * Double(max(factor, 0)))
    }

    /// Sets `control` to `value` within its range, to a ten-thousandth: finer than shows, so the
    /// drag is smooth, and a new curve that agrees changes nothing.
    private func set(_ control: WritableKeyPath<Controls, Double> & Sendable, to value: Double) {
        let range = Controls.range(control)
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
