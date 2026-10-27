import Foundation
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
        expectParity(difference.maxRelative, below: 1e-6, "\(name) light max rel", case: caseName)
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
    // 3× the most measured: 6.0e-7, on the Pro 400H chart.
    expectParity(difference.maxAbsolute, below: 2e-6, "log_e_print max abs", case: caseName)
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
    expectParity(difference.maxAbsolute, below: 1e-4, "log_e_print max abs", case: "print variant")
}

/// The burn gives what's over its threshold its stops of extra print exposure and leaves the rest
/// as it was, up to the edge between them: a film exposure of mid-grey on the left half and 4 stops
/// over on the right, the negative itself the same all over.
@Test func burnDarkensOnlyWhatIsBright() throws {
    var parameters = Parameters()
    parameters.enlarger.burn = Parameters.Burn(stops: 1.5, threshold: 2)
    let simulation = try Simulation(parameters: parameters, film: Profile.load("kodak_portra_400"),
                                    print: Profile.load("kodak_portra_endura"), gpu: GPU(), tables: Tables.load())
    let gpu = simulation.gpu
    let (width, height) = (64, 16)
    let logExposure = (0..<height).flatMap { _ in
        (0..<width).flatMap { x in [Float](repeating: x < width / 2 ? 0 : Float(4 * log10(2.0)), count: 3) }
    }
    let film = gpu.upload(rgb: logExposure, width: width, height: height)
    let cmy = gpu.upload(rgb: [Float](repeating: 0.8, count: width * height * 3), width: width, height: height)
    let plain = gpu.download(try gpu.run { simulation.encodePrintExpose(cmy, on: $0) })
    let burned = gpu.download(try gpu.run { encoder in
        simulation.encodePrintExpose(cmy, burnMask: simulation.encodeBurnMask(film, on: encoder), on: encoder)
    })
    var (darkest, brightest) = (0.0, Double.infinity)
    for y in 0..<height {
        for x in 0..<width {
            let stops = Double(burned[(y * width + x) * 3 + 1] - plain[(y * width + x) * 3 + 1]) / log10(2)
            if x < width / 2 { darkest = max(darkest, abs(stops)) } else { brightest = min(brightest, stops) }
        }
    }
    print("burn: dark half up to \(darkest) stops, bright half at least \(brightest)")
    #expect(darkest < 0.01)
    #expect(abs(brightest - 1.5) < 0.01)
}

@Test(arguments: ["kodak_portra_endura", "kodak_2383"])
func printCurvesMatchPython(paper: String) throws {
    let profile = try Profile.load(paper)
    var morph = Parameters.PrintCurvesMorph()
    func check(_ name: String) throws {
        let curves = printCurves(profile.data.densityCurvesModel, logExposure: profile.data.logExposure, morph: morph,
                                 positive: profile.info.type == .positive)
        let difference = Difference(curves.flatMap { [$0.x, $0.y, $0.z] },
                                    try golden("primitives", "\(name)_\(paper)").values, floor: 1e-3)
        expectParity(difference.maxRelative, below: 1e-6, "\(name) max rel", case: paper)
    }
    try check("print_curves")
    morph = Parameters.PrintCurvesMorph(active: true, gammaFactor: 1.2, gammaFactorFast: 0.9, gammaFactorSlow: 1.1,
                                        gammaFactorRed: 1.05, gammaFactorGreen: 0.97, gammaFactorBlue: 1.02,
                                        developerExhaustion: 0.4)
    try check("print_curves_morphed")
}

@Test(arguments: goldenCases.filter { !$0.hasSuffix("scan") })
func printDevelopMatchesCMYPrint(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film),
                                    print: golden.printProfile(), gpu: gpu, tables: Tables.load())
    let logEPrint = try SpektraEngineTests.golden(caseName, "log_e_print")
    let input = gpu.upload(rgb: logEPrint.values, width: logEPrint.shape[1], height: logEPrint.shape[0])
    let output = try gpu.run { simulation.encodePrintDevelop(input, on: $0) }
    let difference = Difference(gpu.download(output), try SpektraEngineTests.golden(caseName, "cmy_print").values, floor: 1)
    // 3× the most measured: 4.8e-7, one float32 step between 4 and 8, in 7 cases.
    expectParity(difference.maxAbsolute, below: 2e-6, "cmy_print max abs", case: caseName)
}
