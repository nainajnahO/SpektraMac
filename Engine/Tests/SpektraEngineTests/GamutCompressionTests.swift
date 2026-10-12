import Foundation
import simd
import Testing
@testable import SpektraEngine

/// The tc LUT's cells decoded to xy, as remap_tc_lut_for_compression does.
private let lutCells = (0..<192).flatMap { i in
    (0..<192).map { j in quadToTri(SIMD2(Double(i) / 191, Double(j) / 191)) }
}

@Test(arguments: ["D55", "T"])
func locusDistanceMatchesPython(illuminant: String) throws {
    let tables = try Tables.load()
    let white = tables.chromaticity(of: tables.illuminants[illuminant]!)
    let distances = lutCells.map {
        InputGamutCompression.normalizedDistance(of: $0, white: white, locus: tables.spectralLocus).normalized
    }
    let reference = try golden("primitives", "locus_dnorm_\(illuminant)")
    let difference = Difference(distances, reference.values, floor: 1e-3)
    print("locus distance around \(illuminant): \(difference)")
    #expect(difference.maxRelative < 1e-6)
}

@Test func insideLocusMatchesMatplotlib() throws {
    // Inside the visible gamut ⇔ normalised distance below 1, from any interior white.
    let tables = try Tables.load()
    let white = tables.chromaticity(of: tables.illuminants["D55"]!)
    let inside = try golden("primitives", "locus_inside").values.map { $0 == 1 }
    let mismatches = zip(lutCells, inside).filter { xy, isInside in
        let normalized = InputGamutCompression.normalizedDistance(of: xy, white: white, locus: tables.spectralLocus).normalized
        return (normalized < 1) != isInside
    }
    print("inside/outside: \(inside.filter { $0 }.count) of \(inside.count) cells inside, \(mismatches.count) mismatches")
    #expect(mismatches.isEmpty)
}

@Test(arguments: ["sRGB", "ProPhoto RGB"])
func outputCompressionMatchesPython(space: String) throws {
    let tables = try Tables.load()
    let suffix = space.split(separator: " ")[0]
    let start = ContinuousClock.now
    let compression = OutputGamutCompression(spec: .init(), space: tables.colourSpaces[space]!,
                                             cat16: tables.chromaticAdaptation["CAT16"]!)
    let elapsed = ContinuousClock.now - start
    let table = try golden("primitives", "cmax_cam16ucs_\(suffix)").values
    let differing = zip(compression.maxChroma, table).filter { Float($0) != $1 }.count
    let tableDifference = Difference(compression.maxChroma, table, floor: 1)
    print("C_max table for \(space) (built in \(elapsed)): \(differing) of \(table.count) cells differ, \(tableDifference)")
    #expect(tableDifference.maxAbsolute < 1e-4)

    let x = try golden("primitives", "output_compress_x_\(suffix)").values.map(Double.init)
    let pixels = stride(from: 0, to: x.count, by: 3).map { SIMD3(x[$0], x[$0 + 1], x[$0 + 2]) }
    let variant = OutputGamutCompression(spec: .init(knee: [0.2, 1.1, 4.0], lightnessCompression: nil),
                                         space: tables.colourSpaces[space]!, cat16: tables.chromaticAdaptation["CAT16"]!)
    for (name, compression) in [("out", compression), ("variant_out", variant)] {
        let result = pixels.flatMap { compression.compress($0).scalars }
        let reference = try golden("primitives", "output_compress_\(name)_\(suffix)").values
        #expect(result.map(\.isNaN) == reference.map(\.isNaN))
        let difference = Difference(result, reference, floor: 1e-3)
        print("output compression \(name) in \(space): \(difference)")
        #expect(difference.maxRelative < 1e-6)
    }
}

/// The scanned RGB of every golden case through its run's output gamut compression.
@Test(arguments: goldenCases)
func outputCompressionMatchesPythonOnScans(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let tables = try Tables.load()
    let compression = OutputGamutCompression(spec: golden.params.io.outputGamutCompress,
                                             space: tables.colourSpaces[golden.params.io.outputColorSpace]!,
                                             cat16: tables.chromaticAdaptation["CAT16"]!)
    let x = try SpektraEngineTests.golden(caseName, "rgb_uncompressed").values.map(Double.init)
    let result = stride(from: 0, to: x.count, by: 3)
        .flatMap { compression.compress(SIMD3(x[$0], x[$0 + 1], x[$0 + 2])).scalars }
    let difference = Difference(result, try SpektraEngineTests.golden(caseName, "rgb_compressed").values, floor: 1e-3)
    print("\(caseName) output compression: \(difference)")
    #expect(difference.maxRelative < 1e-6)
}

/// The `compress_cam16ucs` kernel on the golden samples, against Python and the f64 reference, on
/// the samples the scan can produce: XYZ ≥ 0 (it floors XYZ at 1e-10). Negative luminance is
/// outside CAM16's domain, where float and f64 diverge (down to which samples come out NaN).
@Test(arguments: ["sRGB", "ProPhoto RGB"])
func outputCompressionKernelMatchesPython(space: String) throws {
    let tables = try Tables.load()
    let gpu = try GPU()
    let suffix = space.split(separator: " ")[0]
    let x = try golden("primitives", "output_compress_x_\(suffix)")
    let toXYZ = simd_double3x3(rows: tables.colourSpaces[space]!.rgbToXYZ)
    let inDomain = stride(from: 0, to: x.values.count, by: 3).flatMap { i in
        let xyz = toXYZ * SIMD3(Double(x.values[i]), Double(x.values[i + 1]), Double(x.values[i + 2]))
        return Array(repeating: xyz.min() >= 0, count: 3)
    }
    func scanDomain<T>(_ values: [T]) -> [T] { zip(values, inDomain).filter(\.1).map(\.0) }
    let specs: [(String, Parameters.OutputGamutCompressSpec)] = [
        ("out", .init()), ("variant_out", .init(knee: [0.2, 1.1, 4.0], lightnessCompression: nil)),
    ]
    for (name, spec) in specs {
        let compression = OutputGamutCompression(spec: spec, space: tables.colourSpaces[space]!,
                                                 cat16: tables.chromaticAdaptation["CAT16"]!)
        let result = scanDomain(try compressOnGPU(x, with: compression, gpu: gpu))
        let reference = scanDomain(try golden("primitives", "output_compress_\(name)_\(suffix)").values)
        let cpu = scanDomain(stride(from: 0, to: x.values.count, by: 3).flatMap {
            compression.compress(SIMD3(Double(x.values[$0]), Double(x.values[$0 + 1]), Double(x.values[$0 + 2]))).scalars
        })
        #expect(result.map(\.isNaN) == reference.map(\.isNaN))
        let python = Difference(result, reference, floor: 1)
        let f64 = Difference(result, cpu, floor: 1)
        print("compress_cam16ucs \(name) in \(space), \(result.count / 3) samples with XYZ ≥ 0: vs Python \(python); vs f64 reference \(f64)")
        #expect(python.maxAbsolute < 2e-5)
    }
}

/// The kernel on every golden case's scanned RGB.
@Test(arguments: goldenCases)
func outputCompressionKernelMatchesPythonOnScans(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let tables = try Tables.load()
    let compression = OutputGamutCompression(spec: golden.params.io.outputGamutCompress,
                                             space: tables.colourSpaces[golden.params.io.outputColorSpace]!,
                                             cat16: tables.chromaticAdaptation["CAT16"]!)
    let result = try compressOnGPU(try SpektraEngineTests.golden(caseName, "rgb_uncompressed"), with: compression,
                                   gpu: try GPU())
    let difference = Difference(result, try SpektraEngineTests.golden(caseName, "rgb_compressed").values, floor: 1)
    print("\(caseName) compress_cam16ucs: \(difference)")
    #expect(difference.maxAbsolute < 1e-5)
}

private func compressOnGPU(_ array: NPYArray, with compression: OutputGamutCompression, gpu: GPU) throws -> [Float] {
    let table = compression.maxChroma.map(Float.init)
    let maxChroma = gpu.device.makeBuffer(bytes: table, length: table.count * MemoryLayout<Float>.stride)!
    let input = gpu.upload(rgb: array.values, width: array.shape[1], height: array.shape[0])
    return gpu.download(try gpu.run { gpu.encodeOutputCompression(compression, maxChroma: maxChroma, on: $0, input: input) })
}

private extension SIMD3<Double> {
    var scalars: [Double] { [x, y, z] }
}

/// The per-pixel compression in f64, step for step as Python: the reference the GPU kernel is
/// checked against.
extension OutputGamutCompression {
    /// `compress_rgb_cam16ucs_chroma` on one linear RGB value of the output space.
    func compress(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let jab = model.jab(fromXYZ: rgbToXYZ * rgb)
        var lightness = jab.x
        if let knee = spec.lightnessCompression {
            lightness = reinhardKnee(lightness / whiteLightness, knee) * whiteLightness
        }
        let (chroma, hue) = (hypot(jab.y, jab.z), atan2(jab.z, jab.y))
        // fmax: a NaN lookup gives the floor, as in Python.
        let limit = Double.maximum(maxChroma(lightness: lightness, hue: hue), 1e-9)
        let compressed = reinhardKnee(chroma / limit, spec.knee) * limit
        return xyzToRGB * model.xyz(fromJab: SIMD3(lightness, compressed * cos(hue), compressed * sin(hue)))
    }

    /// `_c_max_lookup`: bilinear in the table, J' clamped to the grid, h' wrapping around.
    func maxChroma(lightness: Double, hue: Double) -> Double {
        guard !lightness.isNaN, !hue.isNaN else { return .nan }
        let (lightnessGrid, hueGrid) = (Self.lightnessGrid, Self.hueGrid)
        let clamped = min(max(lightness, lightnessGrid[0]), lightnessGrid[63])
        let hueIndex = (hue - hueGrid[0]) / (hueGrid[1] - hueGrid[0])
        let hueLow = (Int(hueIndex.rounded(.down)) % 720 + 720) % 720
        let hueHigh = (hueLow + 1) % 720
        let hueFraction = hueIndex - hueIndex.rounded(.down)
        let lightnessIndex = (clamped - lightnessGrid[0]) / (lightnessGrid[63] - lightnessGrid[0]) * 63
        let lightnessLow = min(max(Int(lightnessIndex.rounded(.down)), 0), 62)
        let lightnessFraction = lightnessIndex - Double(lightnessLow)
        func value(_ i: Int, _ j: Int) -> Double { maxChroma[i * 720 + j] }
        return value(lightnessLow, hueLow) * (1 - lightnessFraction) * (1 - hueFraction)
            + value(lightnessLow, hueHigh) * (1 - lightnessFraction) * hueFraction
            + value(lightnessLow + 1, hueLow) * lightnessFraction * (1 - hueFraction)
            + value(lightnessLow + 1, hueHigh) * lightnessFraction * hueFraction
    }
}
