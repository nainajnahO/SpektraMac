import Testing
@testable import SpektraEngine

private let printedCases = goldenCases.filter { $0.hasPrefix("photo") && !$0.hasSuffix("scan") }

@Test(arguments: printedCases)
func neutralFiltersMatchDigest(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    var parameters = Parameters()
    parameters.applyNeutralPrintFilters(film: try Profile.load(golden.film), print: try Profile.load(golden.print!),
                                        database: try Tables.loadNeutralPrintFilters())
    #expect(parameters.enlarger.printFilters == golden.params.enlarger.printFilters)
}

@Test(arguments: printedCases)
func enlargerLightMatchesPython(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let tables = try Tables.load()
    var enlarger = golden.params.enlarger
    let lamp = tables.illuminants[enlarger.illuminant]!
    func check(_ light: [Double], _ name: String) throws {
        let difference = Difference(light, try SpektraEngineTests.golden("primitives", "\(name)_\(golden.film)").values,
                                    floor: 1e-3)
        print("\(name) \(golden.film): \(difference)")
        #expect(difference.maxRelative < 1e-6)
    }
    try check(enlargerLight(lamp, filters: enlarger.printFilters, dichroics: tables.dichroicFilters), "enlarger")
    enlarger.mFilterShift = 12
    enlarger.yFilterShift = -7
    enlarger.preflashMFilterShift = 5
    enlarger.preflashYFilterShift = -3
    try check(enlargerLight(lamp, filters: enlarger.printFilters, dichroics: tables.dichroicFilters), "enlarger_shifted")
    try check(enlargerLight(lamp, filters: enlarger.preflashFilters, dichroics: tables.dichroicFilters), "preflash")
}

@Test(arguments: goldenCases.filter { !$0.hasSuffix("scan") })
func printExposeMatchesLogEPrint(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film),
                                    print: golden.printProfile(), gpu: gpu, tables: Tables.load())
    let cmyFilm = try SpektraEngineTests.golden(caseName, "cmy_film")
    let input = gpu.upload(rgb: cmyFilm.values, width: cmyFilm.shape[1], height: cmyFilm.shape[0])
    let output = try gpu.run { simulation.encodePrintExpose(input, on: $0) }
    let difference = Difference(gpu.download(output), try SpektraEngineTests.golden(caseName, "log_e_print").values, floor: 1)
    print("\(caseName) log_e_print: \(difference)")
    #expect(difference.maxAbsolute < 1e-4)
}

/// Print exposure 1.3, +0.7 EV balanced at the enlarger (compensated mid-grey), 0.3 preflash.
@Test func printExposeMatchesPythonWithPreflashAndCompensation() throws {
    var parameters = try GoldenCase("chart-kodak_portra_400-kodak_portra_endura").params
    parameters.enlarger.printExposure = 1.3
    parameters.enlarger.printExposureCompensation = true
    parameters.camera.exposureCompensationEv = 0.7
    parameters.enlarger.preflashExposure = 0.3
    parameters.enlarger.preflashMFilterShift = 5
    parameters.enlarger.preflashYFilterShift = -3
    let gpu = try GPU()
    let simulation = try Simulation(parameters: parameters, film: Profile.load("kodak_portra_400"),
                                    print: Profile.load("kodak_portra_endura"), gpu: gpu, tables: Tables.load())
    let cmyFilm = try golden("primitives", "print_variant_cmy_film")
    let input = gpu.upload(rgb: cmyFilm.values, width: cmyFilm.shape[1], height: cmyFilm.shape[0])
    let output = try gpu.run { simulation.encodePrintExpose(input, on: $0) }
    let difference = Difference(gpu.download(output), try golden("primitives", "print_variant_log_e_print").values, floor: 1)
    print("print variant log_e_print: \(difference)")
    #expect(difference.maxAbsolute < 1e-4)
}
