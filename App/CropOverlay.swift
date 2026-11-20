import SwiftUI

/// The shapes the crop bar keeps a crop to.
enum CropShape: String, CaseIterable {
    case free = "Free"
    case asShot = "As Shot"
    case threeTwo = "3:2"
    case fourFive = "4:5"
    case square = "1:1"

    /// Width over height for a selection of `selection`'s size in a photo of `whole`'s: nil for any.
    /// 3:2 and 4:5 lie as the selection does, on its side or upright.
    func ratio(of selection: CGSize, in whole: CGSize) -> CGFloat? {
        let upright = selection.height > selection.width
        return switch self {
        case .free: nil
        case .asShot: whole.width / whole.height
        case .threeTwo: upright ? 2.0 / 3 : 3.0 / 2
        case .fourFive: upright ? 4.0 / 5 : 5.0 / 4
        case .square: 1
        }
    }
}

/// The part of the photo to keep, marked on the whole photo in crop mode: the rest is dimmed, and
/// the frame is dragged by its corners and edges, or moved by its middle.
///
/// Drawn and dragged here: SwiftUI and AppKit have no crop control. ImageKit's `IKImageView` has a
/// crop tool, but it's a view of its own image that crops it itself, so it can't mark a crop on
/// the canvas's render.
struct CropOverlay: View {
    /// The part to keep, in the photo's pixels from its top left.
    @Binding var selection: CGRect
    /// The photo's size in pixels.
    let whole: CGSize
    /// Width over height the selection keeps to, if any.
    let ratio: CGFloat?
    /// The selection as the drag under way found it.
    @State private var start: CGRect?

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
            let scale = geometry.size.width / whole.width
            let frame = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                               width: selection.width * scale, height: selection.height * scale)
            ZStack {
                marks(of: frame, in: geometry.size)
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
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .gesture(drag(scale: scale) { moved($0, by: $1) })
                    .pointerStyle(start == nil ? .grabIdle : .grabActive)
                    .accessibilityHidden(true)
                ForEach(Handle.allCases, id: \.self) { handle in
                    let area = handle.area(on: frame)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: area.width, height: area.height)
                        .position(x: area.midX, y: area.midY)
                        .gesture(drag(scale: scale) { resized($0, by: $1, at: handle, scale: scale) })
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
            // The handles move as they're dragged: the drag is measured on the photo, which doesn't.
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

    /// The photo dimmed outside `frame`, and the frame: its outline, the thirds, and a mark on each
    /// corner and edge.
    private func marks(of frame: CGRect, in size: CGSize) -> some View {
        Canvas { context, _ in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(frame)
            context.fill(outside, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
            // White lines on a pale photo show by their shadow.
            context.addFilter(.shadow(color: .black.opacity(0.5), radius: 1))
            var thirds = Path()
            for third in [1.0 / 3, 2.0 / 3] {
                thirds.move(to: CGPoint(x: frame.minX + frame.width * third, y: frame.minY))
                thirds.addLine(to: CGPoint(x: frame.minX + frame.width * third, y: frame.maxY))
                thirds.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * third))
                thirds.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * third))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
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

    /// A drag that sets the selection to what `change` makes of it as the drag began and how far the
    /// drag has gone, in pixels.
    private func drag(scale: CGFloat, _ change: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("crop"))
            .onChanged { drag in
                let from = start ?? selection
                start = from
                selection = change(from, CGSize(width: drag.translation.width / scale, height: drag.translation.height / scale))
            }
            .onEnded { _ in start = nil }
    }

    /// `start` moved by `offset`, inside the photo.
    private func moved(_ start: CGRect, by offset: CGSize) -> CGRect {
        CGRect(x: min(max(0, start.minX + offset.width), whole.width - start.width),
               y: min(max(0, start.minY + offset.height), whole.height - start.height),
               width: start.width, height: start.height)
    }

    /// `start` with `handle` moved by `offset`, inside the photo and no smaller than can be held.
    /// Keeping to ``ratio``, a corner leaves the opposite corner where it is, and an edge the
    /// middle of the opposite edge.
    private func resized(_ start: CGRect, by offset: CGSize, at handle: Handle, scale: CGFloat) -> CGRect {
        let unit = handle.unit
        // The shortest a side gets: 32 points on screen.
        let least = min(32 / scale, whole.width, whole.height)
        var (left, right, top, bottom) = (start.minX, start.maxX, start.minY, start.maxY)
        if unit.x == 0 { left = min(max(0, left + offset.width), right - least) }
        if unit.x == 1 { right = max(min(whole.width, right + offset.width), left + least) }
        if unit.y == 0 { top = min(max(0, top + offset.height), bottom - least) }
        if unit.y == 1 { bottom = max(min(whole.height, bottom + offset.height), top + least) }
        var size = CGSize(width: right - left, height: bottom - top)
        guard let ratio else { return CGRect(x: left, y: top, width: size.width, height: size.height) }
        if unit.y == 0.5 {
            // As tall as the width asks, about the same middle: no taller than the photo has room.
            let room = 2 * min(start.midY, whole.height - start.midY)
            size.width = min(size.width, room * ratio)
            size.height = size.width / ratio
            return CGRect(x: unit.x == 0 ? start.maxX - size.width : start.minX, y: start.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        if unit.x == 0.5 {
            let room = 2 * min(start.midX, whole.width - start.midX)
            size.height = min(size.height, room / ratio)
            size.width = size.height * ratio
            return CGRect(x: start.midX - size.width / 2, y: unit.y == 0 ? start.maxY - size.height : start.minY,
                          width: size.width, height: size.height)
        }
        // A corner follows the pointer on the side it has gone further, as far as the photo reaches
        // from the opposite corner.
        let room = CGSize(width: unit.x == 0 ? start.maxX : whole.width - start.minX,
                          height: unit.y == 0 ? start.maxY : whole.height - start.minY)
        size.width = min(max(size.width, size.height * ratio), room.width, room.height * ratio)
        size.height = size.width / ratio
        return CGRect(x: unit.x == 0 ? start.maxX - size.width : start.minX,
                      y: unit.y == 0 ? start.maxY - size.height : start.minY, width: size.width, height: size.height)
    }
}
