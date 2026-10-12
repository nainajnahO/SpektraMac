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
