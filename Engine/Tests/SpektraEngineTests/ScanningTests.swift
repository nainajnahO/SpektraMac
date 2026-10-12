import simd
import Testing
@testable import SpektraEngine

@Test(arguments: goldenCases)
func scanMatchesPythonBeforeGamutCompression(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film),
                                    print: golden.printProfile(), gpu: gpu, tables: Tables.load())
    let cmy = try SpektraEngineTests.golden(caseName, golden.params.io.scanFilm ? "cmy_film" : "cmy_print")
    let input = gpu.upload(rgb: cmy.values, width: cmy.shape[1], height: cmy.shape[0])
    let output = try gpu.run { simulation.encodeDensityToRGB(input, on: $0) }
    let difference = Difference(gpu.download(output), try SpektraEngineTests.golden(caseName, "rgb_uncompressed").values,
                                floor: 1)
    print("\(caseName) scanned RGB: \(difference)")
    #expect(difference.maxAbsolute < 1e-5)
}

/// The Portra chart's `cmy_print` scanned into each other output space Spektrafilm offers: its
/// matrices, C_max table and transfer function.
@Test(arguments: ["DCI-P3", "Display P3", "Adobe RGB (1998)", "ITU-R BT.2020", "ProPhoto RGB", "ACES2065-1"])
func scanMatchesPythonInOutputSpace(space: String) throws {
    let caseName = "chart-kodak_portra_400-kodak_portra_endura"
    let golden = try GoldenCase(caseName)
    var parameters = golden.params
    parameters.io.outputColorSpace = space
    let gpu = try GPU()
    let simulation = try Simulation(parameters: parameters, film: Profile.load(golden.film),
                                    print: golden.printProfile(), gpu: gpu, tables: Tables.load())
    let cmy = try SpektraEngineTests.golden(caseName, "cmy_print")
    let input = gpu.upload(rgb: cmy.values, width: cmy.shape[1], height: cmy.shape[0])
    let result = gpu.download(try gpu.run { simulation.encodeScan(input, on: $0) })
    let fileName = space.replacing(" ", with: "_").replacing("(", with: "").replacing(")", with: "")
    let reference = try SpektraEngineTests.golden(caseName, "rgb_out_\(fileName)").values
    #expect(result.map(\.isNaN) == reference.map(\.isNaN))
    let difference = Difference(result, reference, floor: 1)
    print("\(space) rgb_out from cmy_print: \(difference)")
    #expect(difference.maxAbsolute < 2e-5)
}

/// The whole deterministic chain, `rgb_in → rgb_out`, also as 8-bit values.
@Test(arguments: goldenCases)
func chainMatchesPython(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film),
                                    print: golden.printProfile(), gpu: gpu, tables: Tables.load())
    let rgbIn = try SpektraEngineTests.golden(caseName, "rgb_in").image
    let result = gpu.download(try gpu.run { simulation.encode(rgbIn, on: $0) })
    let reference = try SpektraEngineTests.golden(caseName, "rgb_out").values
    let difference = Difference(result, reference, floor: 1)
    func eightBit(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    let steps = zip(result, reference).map { abs(eightBit($0) - eightBit($1)) }
    let identical = Double(steps.filter { $0 == 0 }.count) / Double(steps.count)
    print("\(caseName) rgb_out: \(difference); 8-bit: max \(steps.max()!) steps, \(identical * 100)% identical")
    #expect(difference.maxAbsolute < 2e-5)
    #expect(steps.max()! <= 2 && identical >= 0.999)
}

/// The LUT creator's QA oracle: ΔE2000 between this chain and Python on its 50k random sRGB
/// samples, read as its metric reads them (clipped to [0, 1], sRGB → XYZ → L*a*b* under D65).
@Test(arguments: ["kodak_portra_400-kodak_portra_endura", "kodak_vision3_500t-kodak_2383"])
func qaOracleDeltaE(pair: String) throws {
    let caseName = "qa-\(pair)"
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let tables = try Tables.load()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film),
                                    print: golden.printProfile(), gpu: gpu, tables: tables)
    let samples = try SpektraEngineTests.golden(caseName, "samples").image
    let result = gpu.download(try gpu.run { simulation.encode(samples, on: $0) })
    let reference = try SpektraEngineTests.golden(caseName, "reference_xyz").values
    let sRGB = tables.colourSpaces["sRGB"]!
    let toXYZ = simd_double3x3(rows: sRGB.rgbToXYZ)
    let deltaEs = stride(from: 0, to: result.count, by: 3).map { i in
        let rgb = SIMD3(Double(result[i]), Double(result[i + 1]), Double(result[i + 2])).clamped(lowerBound: .zero, upperBound: .one)
        let xyz = SIMD3(Double(reference[i]), Double(reference[i + 1]), Double(reference[i + 2]))
        return deltaE2000(lab(fromXYZ: toXYZ * rgb, white: sRGB.whitepoint), lab(fromXYZ: xyz, white: sRGB.whitepoint))
    }
    let sorted = deltaEs.sorted()
    print("QA oracle \(pair), \(deltaEs.count) samples: ΔE2000 max \(sorted.last!), p99 \(sorted[sorted.count * 99 / 100]), mean \(deltaEs.reduce(0, +) / Double(deltaEs.count))")
    #expect(sorted.last! <= 0.5)
}
