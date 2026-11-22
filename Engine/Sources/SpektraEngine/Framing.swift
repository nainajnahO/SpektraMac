import CoreGraphics
import CoreImage

/// How a photo is framed: turned a quarter at a time, straightened, and cropped. The crop is
/// measured where all of the photo lies turned, from its top left: straightened, the photo turns
/// about its middle there, and the crop keeps inside it.
public struct Framing: Equatable, Sendable {
    /// Quarter turns to the left, 0 to 3.
    public private(set) var quarterTurns: Int
    /// Degrees the photo is turned to the right after its quarter turns, to straighten it.
    public var angle: Double
    /// The part kept, in pixels: nil for all of it. Straightened, the photo has corners past where
    /// it lies unstraightened, and the crop can reach them.
    public var crop: CGRect?

    public init(quarterTurns: Int = 0, angle: Double = 0, crop: CGRect? = nil) {
        self.quarterTurns = (quarterTurns % 4 + 4) % 4
        self.angle = angle
        self.crop = crop
    }

    /// All of the photo as it opened.
    public static let whole = Framing()

    /// A photo of `size`, turned: the size the crop is measured in.
    public func turned(_ size: CGSize) -> CGSize {
        quarterTurns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    /// Turned `quarters` more to the left (to the right for fewer than none), for a photo of
    /// `size`: the crop turns with it.
    public func turned(left quarters: Int, in size: CGSize) -> Framing {
        var box = turned(size)
        var crop = crop
        for _ in 0..<((quarters % 4 + 4) % 4) {
            crop = crop.map { CGRect(x: $0.minY, y: box.width - $0.maxX, width: $0.height, height: $0.width) }
            box = CGSize(width: box.height, height: box.width)
        }
        return Framing(quarterTurns: quarterTurns + quarters, angle: angle, crop: crop)
    }

    /// From a point of a photo of `size`, in pixels from its top left, to where it lies framed: the
    /// photo turned about its middle, which stays where the middle of all of it turned is.
    public func transform(for size: CGSize) -> CGAffineTransform {
        Self.turn(from: size, to: turned(size), degrees: angle - 90 * Double(quarterTurns))
    }

    /// `image`, all of a photo of `size` from Core Image's origin, turned and straightened, with all
    /// of it turned, unstraightened, from the origin. Straightened, its corners reach past that.
    /// Its edges reach on past it, so a crop of whole pixels just past a straightened photo's edge
    /// has no bare pixels.
    public func applied(to image: CIImage, size: CGSize) -> CIImage {
        // Core Image measures up, so the same turn is the other way round.
        let transform = Self.turn(from: size, to: turned(size), degrees: 90 * Double(quarterTurns) - angle)
        return image.clampedToExtent()
            .transformed(by: transform)
            .cropped(to: CGRect(origin: .zero, size: size).applying(transform))
    }

    /// A turn by `degrees` about the middle of `size`, ending at the middle of `turned`: clockwise
    /// measuring down, anticlockwise measuring up. Exact at quarter turns, so they move whole pixels.
    private static func turn(from size: CGSize, to turned: CGSize, degrees: Double) -> CGAffineTransform {
        let quarters = degrees / 90
        let rotation: CGAffineTransform
        if quarters == quarters.rounded() {
            let (cos, sin): (CGFloat, CGFloat) = switch (Int(quarters) % 4 + 4) % 4 {
            case 0: (1, 0)
            case 1: (0, 1)
            case 2: (-1, 0)
            default: (0, -1)
            }
            rotation = CGAffineTransform(a: cos, b: sin, c: -sin, d: cos, tx: 0, ty: 0)
        } else {
            rotation = CGAffineTransform(rotationAngle: degrees * .pi / 180)
        }
        return CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(rotation)
            .concatenating(CGAffineTransform(translationX: turned.width / 2, y: turned.height / 2))
    }
}
