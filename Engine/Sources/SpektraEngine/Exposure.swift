import Accelerate
import Dispatch
import Foundation
import Metal

/// Spektrafilm's centre-weighted `measure_autoexposure_ev` on `ResizingService.small_preview`:
/// the exposure in stops that brings the Gaussian-weighted (σ = 0.2 of the long edge) mean
/// luminance of a ≤256 px preview to 0.184.
///
/// Runs on the CPU in f64: it reads only the preview's pixels, and the preview has to be
/// scikit-image's `rescale(order=0)` exactly (see ``smallPreview(of:maxSize:)``).
public func autoExposureEV(of image: RGBImage, colourSpace: Tables.ColourSpace, cctfDecoding: Bool) -> Double {
    image.pixels.withUnsafeBufferPointer { pixels in
        autoExposureEV(of: Pixels(base: pixels.baseAddress!, width: image.width, height: image.height, components: 3,
                                  rowLength: image.width * 3),
                       colourSpace: colourSpace, cctfDecoding: cctfDecoding)
    }
}

/// ``autoExposureEV(of:colourSpace:cctfDecoding:)-(RGBImage,_,_)`` of a texture made by
/// ``GPU/makeReadableTexture(width:height:)``, read in place.
func autoExposureEV(of texture: any MTLTexture, colourSpace: Tables.ColourSpace, cctfDecoding: Bool) -> Double {
    let base = texture.buffer!.contents().assumingMemoryBound(to: Float.self)
    return autoExposureEV(of: Pixels(base: base, width: texture.width, height: texture.height, components: 4,
                                     rowLength: texture.bufferBytesPerRow / 4),
                          colourSpace: colourSpace, cctfDecoding: cctfDecoding)
}

/// An image's floats where they are: RGB first in each pixel's `components`, rows `rowLength`
/// floats apart.
struct Pixels {
    let base: UnsafePointer<Float>
    let width: Int
    let height: Int
    let components: Int
    let rowLength: Int
}

private func autoExposureEV(of image: Pixels, colourSpace: Tables.ColourSpace, cctfDecoding: Bool) -> Double {
    let (preview, width, height) = smallPreview(of: image)
    // Y of colour.RGB_to_XYZ without chromatic adaptation.
    let yRow = colourSpace.rgbToXYZ[1]
    let longEdge = Double(max(width, height))
    let xs = (0..<width).map { (Double($0) / Double(width) - 0.5) * Double(width) / longEdge }
    let ys = (0..<height).map { (Double($0) / Double(height) - 0.5) * Double(height) / longEdge }
    let sigma = 0.2
    var weightedSum = 0.0, maskSum = 0.0
    for row in 0..<height {
        for column in 0..<width {
            let mask = exp(-(xs[column] * xs[column] + ys[row] * ys[row]) / (2 * sigma * sigma))
            let index = (row * width + column) * 3
            var rgb = SIMD3(preview[index], preview[index + 1], preview[index + 2])
            if cctfDecoding {
                rgb = SIMD3(colourSpace.decode(rgb.x), colourSpace.decode(rgb.y), colourSpace.decode(rgb.z))
            }
            weightedSum += (yRow * rgb).sum() * mask
            maskSum += mask
        }
    }
    let ev = -log2(weightedSum / maskSum / 0.184)
    // Python falls back to 0 EV for a black frame.
    return ev.isInfinite ? 0 : ev
}

/// scikit-image `rescale(image, maxSize / longEdge, order=0, channel_axis=2)` as Spektrafilm's
/// `small_preview` calls it, in f64: a Gaussian anti-alias with σ = (factor − 1)/2 per axis
/// (scipy `gaussian_filter`, truncate 4, `mirror` edges), then nearest-neighbour samples at
/// `floor((o + 0.5)·n/m)`. Only the sampled pixels are filtered. Images within `maxSize` are
/// returned unchanged. The result is RGB, row-major.
func smallPreview(of image: Pixels, maxSize: Int = 256) -> (pixels: [Double], width: Int, height: Int) {
    let (width, height, components) = (image.width, image.height, image.components)
    guard max(width, height) > maxSize else {
        let rgb = (0..<(width * height)).flatMap { pixel in
            (0..<3).map { Double(image.base[pixel / width * image.rowLength + pixel % width * components + $0]) }
        }
        return (rgb, width, height)
    }
    let scale = Double(maxSize) / Double(max(width, height))
    let outHeight = max(Int((scale * Double(height)).rounded(.toNearestOrEven)), 1)
    let outWidth = max(Int((scale * Double(width)).rounded(.toNearestOrEven)), 1)

    // Per axis: the sampled source indices and the anti-alias kernel.
    func axis(_ n: Int, _ m: Int) -> (samples: [Int], weights: [Double], radius: Int) {
        let factor = Double(n) / Double(m)
        let samples = (0..<m).map { Int(floor((Double($0) + 0.5) * factor - 0.5 + 0.5)) }
        let sigma = max(0, (factor - 1) / 2)
        guard sigma > 1e-15 else { return (samples, [1], 0) }
        let radius = Int(4 * sigma + 0.5)
        let weights = (-radius...radius).map { exp(-0.5 / (sigma * sigma) * Double($0 * $0)) }
        let total = weights.reduce(0, +)
        return (samples, weights.map { $0 / total }, radius)
    }
    let rows = axis(height, outHeight), columns = axis(width, outWidth)

    // Vertical pass on the sampled rows (all columns), then the horizontal pass on the sampled
    // columns: scipy filters axis 0 before axis 1.
    // vDSP so the bulk of the work (the full-width rows) stays fast in Debug builds too.
    let rowLength = width * components
    var vertical = [Double](repeating: 0, count: outHeight * rowLength)
    vertical.withUnsafeMutableBufferPointer { vertical in
        // Each iteration writes only its own output row, and only reads the image.
        nonisolated(unsafe) let (vertical, image) = (vertical, image)
        DispatchQueue.concurrentPerform(iterations: outHeight) { o in
            var row = [Double](repeating: 0, count: rowLength)
            let destination = vertical.baseAddress! + o * rowLength
            for (k, weight) in rows.weights.enumerated() {
                let source = image.base + mirror(rows.samples[o] + k - rows.radius, height) * image.rowLength
                vDSP_vspdp(source, 1, &row, 1, vDSP_Length(rowLength))
                var weight = weight
                vDSP_vsmaD(row, 1, &weight, destination, 1, destination, 1, vDSP_Length(rowLength))
            }
        }
    }
    var preview = [Double](repeating: 0, count: outHeight * outWidth * 3)
    for o in 0..<outHeight {
        for p in 0..<outWidth {
            for (k, weight) in columns.weights.enumerated() {
                let source = o * rowLength + mirror(columns.samples[p] + k - columns.radius, width) * components
                let destination = (o * outWidth + p) * 3
                for c in 0..<3 {
                    preview[destination + c] += weight * vertical[source + c]
                }
            }
        }
    }
    return (preview, outWidth, outHeight)
}

/// scipy `mode="mirror"` index: d c b | a b c d | c b a.
private func mirror(_ i: Int, _ n: Int) -> Int {
    guard n > 1 else { return 0 }
    let period = 2 * (n - 1)
    let j = ((i % period) + period) % period
    return j < n ? j : period - j
}
