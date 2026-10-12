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
    let output = try gpu.run { simulation.encodeScan(input, on: $0) }
    let difference = Difference(gpu.download(output), try SpektraEngineTests.golden(caseName, "rgb_uncompressed").values,
                                floor: 1)
    print("\(caseName) scanned RGB: \(difference)")
    #expect(difference.maxAbsolute < 1e-5)
}

/// The whole deterministic chain from `rgb_in` through output gamut compression.
@Test(arguments: goldenCases)
func chainMatchesPythonThroughGamutCompression(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film),
                                    print: golden.printProfile(), gpu: gpu, tables: Tables.load())
    let rgbIn = try SpektraEngineTests.golden(caseName, "rgb_in").image
    let output = try gpu.run { simulation.encode(rgbIn, on: $0) }
    let difference = Difference(gpu.download(output), try SpektraEngineTests.golden(caseName, "rgb_compressed").values,
                                floor: 1)
    print("\(caseName) chain to compressed RGB: \(difference)")
    #expect(difference.maxAbsolute < 1e-4)
}
