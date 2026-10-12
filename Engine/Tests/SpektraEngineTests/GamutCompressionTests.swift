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

private extension SIMD3<Double> {
    var scalars: [Double] { [x, y, z] }
}
