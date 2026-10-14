import Accelerate
import CoreGraphics
import CoreVideo
import Vision

/// The marks on the exposure scale: the exposure each way of metering gives a photo, in stops
/// over the photo as shot. As shot is the camera's own exposure; Centre-weighted is
/// Spektrafilm's auto-exposure (a film camera's meter). The others are SpektraMac's own: they
/// meter what Apple's Vision finds in the photo, so a bright sky or background can't darken the
/// subject the way it does on a film camera's meter. ``Controls/exposureMark`` picks one.
public enum MeteringMark: Int, CaseIterable, Codable, Sendable {
    case asShot, centreWeighted, objects, people, faces
}

/// What Vision found in a photo for the Objects, People and Faces marks, over the whole frame.
struct MeteringRegions: Sendable {
    /// Objectness saliency (Vision's heat map, 68 × 68) and person segmentation (the accurate
    /// mask): weights 0…1, row 0 at the top.
    var objects: WeightMap
    var people: WeightMap
    /// Face bounding boxes, normalised, origin at the lower left (Vision's).
    var faces: [CGRect]

    /// Runs Vision on `image`, an upright view of the photo exposed so dim scenes are readable:
    /// about 0.1 s for a 1024 px view on an M1 Pro. The blocking `VNImageRequestHandler` rather
    /// than Vision's async requests: the engine waits on its own serial queue, and an `await` in
    /// ``Engine/open(_:)`` would let a waiting render in while no photo is open.
    init(finding image: CGImage) throws {
        let people = VNGeneratePersonSegmentationRequest()
        people.qualityLevel = .accurate
        people.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([people, objects, faces])
        guard let mask = people.results?.first, let heatMap = objects.results?.first else {
            throw VisionError()
        }
        self.people = try WeightMap(mask.pixelBuffer)
        self.objects = try WeightMap(heatMap.pixelBuffer)
        self.faces = faces.results?.map(\.boundingBox) ?? []
    }

    init(objects: WeightMap, people: WeightMap, faces: [CGRect]) {
        (self.objects, self.people, self.faces) = (objects, people, faces)
    }

    struct VisionError: Error, CustomStringConvertible {
        var description: String { "Vision returned no person mask or heat map" }
    }

    /// `mark`'s weights over a `width × height` grid, row-major from the top: Centre-weighted's
    /// centre weights, or what Vision found.
    func weights(for mark: MeteringMark, width: Int, height: Int) -> [Double] {
        switch mark {
        case .asShot: preconditionFailure("As shot meters nothing")
        case .centreWeighted: centreWeights(width: width, height: height)
        case .objects: objects.resampled(width: width, height: height)
        case .people: people.resampled(width: width, height: height)
        case .faces: faceWeights(width: width, height: height)
        }
    }

    /// The face boxes filled in, edges antialiased, so a face smaller than a cell still counts.
    private func faceWeights(width: Int, height: Int) -> [Double] {
        // Core Graphics' origin is at the lower left too, and a bitmap context keeps its top row
        // first.
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        for face in faces {
            context.fill(CGRect(x: face.minX * Double(width), y: face.minY * Double(height),
                                width: face.width * Double(width), height: face.height * Double(height)))
        }
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(width * height)).map { Double(bytes[$0 / width * context.bytesPerRow + $0 % width]) / 255 }
    }
}

/// A one-channel float map, row-major from the top.
struct WeightMap: Sendable {
    let values: [Float]
    let width: Int
    let height: Int

    init(values: [Float], width: Int, height: Int) {
        precondition(values.count == width * height)
        (self.values, self.width, self.height) = (values, width, height)
    }

    /// Copies a `OneComponent32Float` buffer.
    init(_ buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else {
            throw UnexpectedFormat()
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let (width, height) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let values = (0..<height).flatMap { row in
            UnsafeBufferPointer(start: (base + row * rowBytes).assumingMemoryBound(to: Float.self), count: width)
        }
        self.init(values: values, width: width, height: height)
    }

    struct UnexpectedFormat: Error, CustomStringConvertible {
        var description: String { "Vision returned a map that isn't 32-bit float" }
    }

    /// The map scaled to `width × height` (vImage's high-quality resampling), clamped to 0…1.
    func resampled(width: Int, height: Int) -> [Double] {
        var source = values
        var output = [Float](repeating: 0, count: width * height)
        source.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { output in
                var from = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(self.height),
                                         width: vImagePixelCount(self.width), rowBytes: self.width * 4)
                var to = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
                precondition(vImageScale_PlanarF(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError)
            }
        }
        return output.map { Double(min(max($0, 0), 1)) }
    }
}

/// The exposure each mark gives one image of the photo, metered on the luminance Spektrafilm
/// meters (``meteredLuminance(of:colourSpace:cctfDecoding:)``).
public struct MeteringReadings: Sendable, Equatable {
    /// Per mark, by raw value: the exposure in stops over the photo as shot, or nil where Vision
    /// found nothing to meter (under 1 % of the frame; no face at all for Faces).
    public let ev: [Double?]

    /// Meters `y` (`width × height`, row-major) at each mark; with no regions, only As shot and
    /// Centre-weighted have readings.
    init(luminance y: [Double], width: Int, height: Int, regions: MeteringRegions?) {
        var ev = [Double?](repeating: nil, count: MeteringMark.allCases.count)
        ev[MeteringMark.asShot.rawValue] = 0
        // Python's black frame gives 0 EV.
        ev[MeteringMark.centreWeighted.rawValue] = exposureEV(y, weights: centreWeights(width: width, height: height)) ?? 0
        for mark in [MeteringMark.objects, .people, .faces] {
            guard let weights = regions?.weights(for: mark, width: width, height: height) else { continue }
            let coverage = weights.reduce(0, +) / Double(weights.count)
            if mark == .faces ? coverage > 0 : coverage >= 0.01 {
                ev[mark.rawValue] = exposureEV(y, weights: weights)
            }
        }
        self.ev = ev
    }

    /// `mark`'s reading, or where it has none, the next broader mark's that has one: Faces →
    /// People → Objects → Centre-weighted.
    public func reading(resolving mark: MeteringMark) -> (mark: MeteringMark, ev: Double) {
        var mark = mark
        while ev[mark.rawValue] == nil {
            mark = MeteringMark(rawValue: mark.rawValue - 1)!
        }
        return (mark, ev[mark.rawValue]!)
    }
}

extension MeteringRegions {
    /// The region each mark with a reading meters, as an image for the canvas to tint: white,
    /// with the weight as alpha, at most `maxSize` on the long side of a `width × height` photo.
    /// As shot meters nothing, so has none.
    func overlays(for readings: MeteringReadings, width: Int, height: Int,
                  maxSize: Int = 512) -> [MeteringMark: CGImage] {
        let scale = min(1, Double(maxSize) / Double(max(width, height)))
        let (overlayWidth, overlayHeight) = (max(Int(Double(width) * scale), 1), max(Int(Double(height) * scale), 1))
        let marks = MeteringMark.allCases.filter { $0 != .asShot && readings.ev[$0.rawValue] != nil }
        return Dictionary(uniqueKeysWithValues: marks.map { mark in
            var weights = weights(for: mark, width: overlayWidth, height: overlayHeight)
            let peak = weights.max() ?? 0
            if peak > 0 {
                weights = weights.map { $0 / peak }
            }
            // Premultiplied white: every channel is the alpha.
            let bytes = weights.flatMap { Array(repeating: UInt8(($0 * 255).rounded()), count: 4) }
            let image = CGImage(width: overlayWidth, height: overlayHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: overlayWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent)!
            return (mark, image)
        })
    }
}
