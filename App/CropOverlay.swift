import SwiftUI

/// The shapes the crop bar keeps a crop to.
enum CropShape: String, CaseIterable {
    case custom = "Custom"
    case asShot = "As Shot"
    case threeTwo = "3:2"
    case fourFive = "4:5"
    case square = "1:1"

    /// Width over height for a part of a photo of `whole`'s size: nil for any. 3:2 and 4:5 stand
    /// upright if `upright`, and otherwise lie on their side. Custom keeps to the width and height
    /// typed for it, as typed, if any.
    func ratio(upright: Bool, typed: CGSize?, in whole: CGSize) -> CGFloat? {
        switch self {
        case .custom: typed.map { $0.width / $0.height }
        case .asShot: whole.width / whole.height
        case .threeTwo: upright ? 2.0 / 3 : 3.0 / 2
        case .fourFive: upright ? 4.0 / 5 : 5.0 / 4
        case .square: 1
        }
    }
}

/// All of the photo as crop mode marks a part of it: its size turned, and turned `angle` degrees
/// to the right about its middle to straighten it. The part marked keeps inside it.
struct StraightenedPhoto {
    /// Its size, turned: where it lies, unstraightened, from the top left.
    let size: CGSize
    let angle: Double

    /// Where `point` of the photo unstraightened lies straightened: turned clockwise about the
    /// middle, measuring down.
    func straightened(_ point: CGPoint) -> CGPoint {
        turned(point, by: angle)
    }

    /// Where `point` is on the photo unstraightened.
    func unstraightened(_ point: CGPoint) -> CGPoint {
        turned(point, by: -angle)
    }

    /// Its corners, straightened.
    var corners: [CGPoint] {
        [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            .map(straightened)
    }

    /// `rect` is inside it, to a hundredth of a pixel.
    func contains(_ rect: CGRect) -> Bool {
        let reach = reach(of: rect.size)
        let middle = unstraightened(CGPoint(x: rect.midX, y: rect.midY))
        let slack = 0.01
        return middle.x - reach.width >= -slack && middle.x + reach.width <= size.width + slack
            && middle.y - reach.height >= -slack && middle.y + reach.height <= size.height + slack
    }

    /// `rect` inside it: made smaller about its middle if it's too large to go in, then moved the
    /// least way across and down the photo. Unstraightened, that's within the photo's edges.
    func fitted(_ rect: CGRect) -> CGRect {
        var reach = reach(of: rect.size)
        let scale = min(1, size.width / 2 / reach.width, size.height / 2 / reach.height)
        reach = CGSize(width: reach.width * scale, height: reach.height * scale)
        var middle = unstraightened(CGPoint(x: rect.midX, y: rect.midY))
        middle.x = min(max(middle.x, reach.width), size.width - reach.width)
        middle.y = min(max(middle.y, reach.height), size.height - reach.height)
        let centre = straightened(middle)
        let fitted = CGSize(width: rect.width * scale, height: rect.height * scale)
        return CGRect(x: centre.x - fitted.width / 2, y: centre.y - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// How far a part of `size` reaches from its middle across and down the photo unstraightened:
    /// half the width and height of what it covers there.
    private func reach(of size: CGSize) -> CGSize {
        let radians = angle * .pi / 180
        let (cos, sin) = (abs(Foundation.cos(radians)), abs(Foundation.sin(radians)))
        return CGSize(width: (cos * size.width + sin * size.height) / 2, height: (sin * size.width + cos * size.height) / 2)
    }

    private func turned(_ point: CGPoint, by degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let (cos, sin) = (Foundation.cos(radians), Foundation.sin(radians))
        let (x, y) = (point.x - size.width / 2, point.y - size.height / 2)
        return CGPoint(x: size.width / 2 + x * cos - y * sin, y: size.height / 2 + x * sin + y * cos)
    }
}

/// The part of the photo to keep, marked on the whole photo in crop mode: the rest is dimmed, and
/// the frame is dragged by its corners and edges. A drag on the photo moves the frame, or, as in
/// Photos, the photo under the frame.
///
/// Drawn and dragged here: SwiftUI and AppKit have no crop control. ImageKit's `IKImageView` has a
/// crop tool, but it's a view of its own image that crops it itself, so it can't mark a crop on
/// the canvas's render.
struct CropOverlay: View, Animatable {
    /// The part to keep, in the photo's pixels from its top left.
    @Binding var selection: CGRect
    /// The photo's size in pixels, turned as it's marked.
    let whole: CGSize
    /// Degrees the photo is turned to the right to straighten it.
    let angle: Double
    /// Where all of the photo turned is, unstraightened, in the overlay's coordinates: the canvas's.
    var photoFrame: CGRect
    /// Width over height the selection keeps to, if any.
    let ratio: CGFloat?
    /// A drag on the photo moves the photo under the frame, rather than the frame over it.
    let movesPhoto: Bool
    /// While the photo is being straightened: a fine grid in the frame, in place of the thirds, to
    /// line things up with.
    let showsFineGrid: Bool
    /// While a corner or edge is dragged with the photo moving: the selection the canvas stays laid
    /// out around, so the frame follows the pointer. Let go, the canvas fits the frame again.
    @Binding var held: CGRect?
    /// The selection as the drag under way found it.
    @State private var start: CGRect?

    /// The frame and the dimming follow the photo as it moves to fit the frame.
    var animatableData: CGRect.AnimatableData {
        get { photoFrame.animatableData }
        set { photoFrame.animatableData = newValue }
    }

    /// Where the frame is held to change its size: its corners and edges.
    private enum Handle: CaseIterable {
        case topLeading, top, topTrailing, leading, trailing, bottomLeading, bottom, bottomTrailing

        /// Where it is on the frame: 0, ½ or 1 of the way across and down.
        var unit: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeading: (0, 0)
            case .top: (0.5, 0)
            case .topTrailing: (1, 0)
            case .leading: (0, 0.5)
            case .trailing: (1, 0.5)
            case .bottomLeading: (0, 1)
            case .bottom: (0.5, 1)
            case .bottomTrailing: (1, 1)
            }
        }

        var position: FrameResizePosition {
            switch self {
            case .topLeading: .topLeading
            case .top: .top
            case .topTrailing: .topTrailing
            case .leading: .leading
            case .trailing: .trailing
            case .bottomLeading: .bottomLeading
            case .bottom: .bottom
            case .bottomTrailing: .bottomTrailing
            }
        }

        /// An edge's name and the side of the photo it's measured from, for VoiceOver: a corner has
        /// none, as the edges reach every crop.
        var edge: (name: String, side: String)? {
            switch self {
            case .top: ("Top edge", "top")
            case .leading: ("Left edge", "left")
            case .trailing: ("Right edge", "right")
            case .bottom: ("Bottom edge", "bottom")
            default: nil
            }
        }

        /// Where it takes hold, on a frame at `frame`: a square on a corner, the edge between the
        /// corners' squares.
        func area(on frame: CGRect) -> CGRect {
            let (corner, edge): (CGFloat, CGFloat) = (28, 16)
            let size = CGSize(width: unit.x == 0.5 ? max(0, frame.width - corner) : (unit.y == 0.5 ? edge : corner),
                              height: unit.y == 0.5 ? max(0, frame.height - corner) : (unit.x == 0.5 ? edge : corner))
            return CGRect(x: frame.minX + frame.width * unit.x - size.width / 2,
                          y: frame.minY + frame.height * unit.y - size.height / 2, width: size.width, height: size.height)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            // Points to a pixel.
            let scale = photoFrame.width / whole.width
            let frame = CGRect(x: photoFrame.minX + selection.minX * scale, y: photoFrame.minY + selection.minY * scale,
                               width: selection.width * scale, height: selection.height * scale)
            // The photo's edges, straightened, on the canvas.
            let outline = photo.corners.map { CGPoint(x: photoFrame.minX + $0.x * scale, y: photoFrame.minY + $0.y * scale) }
            // Where a drag moves what's moved: the frame, or the photo where it's on the canvas.
            let moveArea = movesPhoto ? Path { $0.addLines(outline) }.boundingRect.intersection(CGRect(origin: .zero, size: geometry.size))
                                      : frame
            ZStack {
                marks(of: frame, in: outline)
                // The size marked, in pixels, in the frame's corner where there's room for it.
                if frame.width >= 120, frame.height >= 44 {
                    let size = "\(Int(selection.width.rounded()).formatted()) × \(Int(selection.height.rounded()).formatted())"
                    Text(size)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .padding(8)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Crop size")
                        .accessibilityValue("\(size) pixels")
                }
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: moveArea.width, height: moveArea.height)
                    .position(x: moveArea.midX, y: moveArea.midY)
                    // The photo goes with the pointer: the part marked, the other way.
                    .gesture(drag(scale: scale) { moved($0, by: movesPhoto ? CGSize(width: -$1.width, height: -$1.height) : $1) })
                    .pointerStyle(start == nil ? .grabIdle : .grabActive)
                    .accessibilityHidden(true)
                ForEach(Handle.allCases, id: \.self) { handle in
                    let area = handle.area(on: frame)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: area.width, height: area.height)
                        .position(x: area.midX, y: area.midY)
                        .gesture(drag(scale: scale, holdsCanvas: movesPhoto) { resized($0, by: $1, at: handle, scale: scale) })
                        .pointerStyle(.frameResize(position: handle.position))
                        .accessibilityElement()
                        .accessibilityHidden(handle.edge == nil)
                        .accessibilityLabel(handle.edge?.name ?? "")
                        .accessibilityValue(handle.edge.map { "\(distance(of: handle).formatted()) pixels from the \($0.side)" } ?? "")
                        .accessibilityAdjustableAction { direction in
                            // A hundredth of the photo's side at a time, inwards to increment.
                            let step = (handle.unit.y == 0.5 ? whole.width : whole.height) / 100
                            let inwards = (handle.unit.x == 0 || handle.unit.y == 0) ? step : -step
                            let by = direction == .increment ? inwards : -inwards
                            selection = resized(selection, by: CGSize(width: by, height: by), at: handle, scale: scale)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // The handles and the photo move as they're dragged: the drag is measured on the
            // canvas, which doesn't.
            .coordinateSpace(.named("crop"))
        }
    }

    /// How far `handle`'s edge is from its own side of the photo, in pixels.
    private func distance(of handle: Handle) -> Int {
        switch handle {
        case .top: Int(selection.minY.rounded())
        case .leading: Int(selection.minX.rounded())
        case .trailing: Int((whole.width - selection.maxX).rounded())
        default: Int((whole.height - selection.maxY).rounded())
        }
    }

    /// The photo, whose edges are `outline`, dimmed outside `frame`, and the frame: its outline, the
    /// thirds or the fine grid, and a mark on each corner and edge.
    private func marks(of frame: CGRect, in outline: [CGPoint]) -> some View {
        Canvas { context, _ in
            var outside = Path { $0.addLines(outline) }
            outside.addRect(frame)
            context.fill(outside, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
            // White lines on a pale photo show by their shadow.
            context.addFilter(.shadow(color: .black.opacity(0.5), radius: 1))
            var lines = Path()
            // Square, about the frame's middle, eight across its short side.
            let step = showsFineGrid ? max(12, min(frame.width, frame.height) / 8) : 0
            let xs = showsFineGrid ? Self.lines(across: frame.minX...frame.maxX, every: step)
                                   : [frame.minX + frame.width / 3, frame.minX + frame.width * 2 / 3]
            let ys = showsFineGrid ? Self.lines(across: frame.minY...frame.maxY, every: step)
                                   : [frame.minY + frame.height / 3, frame.minY + frame.height * 2 / 3]
            for x in xs {
                lines.move(to: CGPoint(x: x, y: frame.minY))
                lines.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
            for y in ys {
                lines.move(to: CGPoint(x: frame.minX, y: y))
                lines.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.stroke(lines, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
            context.stroke(Path(frame), with: .color(.white), lineWidth: 1)
            var holds = Path()
            let length = min(20, frame.width / 4, frame.height / 4)
            for handle in Handle.allCases {
                let (x, y) = handle.unit
                let point = CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
                if x == 0.5 {
                    holds.move(to: CGPoint(x: point.x - length / 2, y: point.y))
                    holds.addLine(to: CGPoint(x: point.x + length / 2, y: point.y))
                } else if y == 0.5 {
                    holds.move(to: CGPoint(x: point.x, y: point.y - length / 2))
                    holds.addLine(to: CGPoint(x: point.x, y: point.y + length / 2))
                } else {
                    // A corner's mark reaches along both its edges, into the frame.
                    holds.move(to: CGPoint(x: point.x + (x == 0 ? length : -length), y: point.y))
                    holds.addLine(to: point)
                    holds.addLine(to: CGPoint(x: point.x, y: point.y + (y == 0 ? length : -length)))
                }
            }
            context.stroke(holds, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter))
        }
        .allowsHitTesting(false)
    }

    /// Lines `step` apart inside `span`, placed about its middle.
    private static func lines(across span: ClosedRange<CGFloat>, every step: CGFloat) -> [CGFloat] {
        let middle = (span.lowerBound + span.upperBound) / 2
        let count = Int(((span.upperBound - span.lowerBound) / 2 / step).rounded(.down))
        return (-count...count).map { middle + CGFloat($0) * step }
            .filter { $0 > span.lowerBound + 1 && $0 < span.upperBound - 1 }
    }

    /// The photo the selection keeps inside.
    private var photo: StraightenedPhoto { StraightenedPhoto(size: whole, angle: angle) }

    /// A drag that sets the selection to what `change` makes of it as the drag began and how far the
    /// drag has gone, in pixels: holding the canvas where it is till it ends, if `holdsCanvas`.
    private func drag(scale: CGFloat, holdsCanvas: Bool = false,
                      _ change: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("crop"))
            .onChanged { drag in
                let from = start ?? selection
                if start == nil, holdsCanvas {
                    held = from
                }
                start = from
                selection = change(from, CGSize(width: drag.translation.width / scale, height: drag.translation.height / scale))
            }
            .onEnded { _ in
                start = nil
                guard held != nil else { return }
                withAnimation(.snappy(duration: 0.3)) { held = nil }
            }
    }

    /// `start` moved by `offset`, inside the photo: along its edge, where it meets one.
    private func moved(_ start: CGRect, by offset: CGSize) -> CGRect {
        photo.fitted(start.offsetBy(dx: offset.width, dy: offset.height))
    }

    /// `start` with `handle` moved by `offset`, inside the photo and no smaller than can be held.
    /// Past the photo's edge it goes as far as the photo reaches, a corner as far across and then
    /// as far down as it can.
    private func resized(_ start: CGRect, by offset: CGSize, at handle: Handle, scale: CGFloat) -> CGRect {
        let photo = photo
        let all = reshaped(start, by: offset, at: handle, scale: scale)
        guard !photo.contains(all) else { return all }
        let across = Self.largest { photo.contains(reshaped(start, by: CGSize(width: offset.width * $0, height: 0),
                                                            at: handle, scale: scale)) }
        let down = Self.largest { photo.contains(reshaped(start, by: CGSize(width: offset.width * across, height: offset.height * $0),
                                                          at: handle, scale: scale)) }
        return reshaped(start, by: CGSize(width: offset.width * across, height: offset.height * down), at: handle, scale: scale)
    }

    /// The largest share of the way, from none to all, for which `fits`: it fits for none, and past
    /// where it stops fitting, no more.
    private static func largest(_ fits: (CGFloat) -> Bool) -> CGFloat {
        var (fitting, not): (CGFloat, CGFloat) = (0, 1)
        guard !fits(1) else { return 1 }
        // To a millionth of the way.
        for _ in 0..<20 {
            let half = (fitting + not) / 2
            if fits(half) { fitting = half } else { not = half }
        }
        return fitting
    }

    /// `start` with `handle` moved by `offset`, no smaller than can be held, wherever the photo is.
    /// Keeping to ``ratio``, a corner leaves the opposite corner where it is, and an edge the middle
    /// of the opposite edge.
    private func reshaped(_ start: CGRect, by offset: CGSize, at handle: Handle, scale: CGFloat) -> CGRect {
        let unit = handle.unit
        // The shortest a side gets: 32 points on screen.
        let least = min(32 / scale, whole.width, whole.height)
        var (left, right, top, bottom) = (start.minX, start.maxX, start.minY, start.maxY)
        if unit.x == 0 { left = min(left + offset.width, right - least) }
        if unit.x == 1 { right = max(right + offset.width, left + least) }
        if unit.y == 0 { top = min(top + offset.height, bottom - least) }
        if unit.y == 1 { bottom = max(bottom + offset.height, top + least) }
        var size = CGSize(width: right - left, height: bottom - top)
        guard let ratio else { return CGRect(x: left, y: top, width: size.width, height: size.height) }
        if unit.y == 0.5 {
            // As tall as the width asks, about the same middle.
            size.height = size.width / ratio
            return CGRect(x: unit.x == 0 ? start.maxX - size.width : start.minX, y: start.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        if unit.x == 0.5 {
            size.width = size.height * ratio
            return CGRect(x: start.midX - size.width / 2, y: unit.y == 0 ? start.maxY - size.height : start.minY,
                          width: size.width, height: size.height)
        }
        // A corner follows the pointer on the side it has gone further.
        size.width = max(size.width, size.height * ratio)
        size.height = size.width / ratio
        return CGRect(x: unit.x == 0 ? start.maxX - size.width : start.minX,
                      y: unit.y == 0 ? start.maxY - size.height : start.minY, width: size.width, height: size.height)
    }
}
