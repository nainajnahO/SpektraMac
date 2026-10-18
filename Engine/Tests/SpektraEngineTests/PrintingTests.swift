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

/// The burn raises the print's log exposure by its stops × log10 2 at the top, fading linearly to
/// none at its reach (pixel centres), below which the print is exactly as without it.
@Test func burnRaisesTheTopOfThePrint() throws {
    var parameters = Parameters()
    let (film, print, tables) = (try Profile.load("kodak_portra_400"), try Profile.load("kodak_portra_endura"),
                                 try Tables.load())
    let gpu = try GPU()
    let (width, height) = (3, 10)
    let input = gpu.upload(rgb: [Float](repeating: 0.8, count: width * height * 3), width: width, height: height)
    func logExposure() throws -> [Float] {
        let simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables)
        return gpu.download(try gpu.run { simulation.encodePrintExpose(input, on: $0) })
    }
    let plain = try logExposure()
    parameters.enlarger.burn = Parameters.Burn(stops: 1.5, reach: 0.4)
    let burned = try logExposure()
    for y in 0..<height {
        let ramp = max(0, 1 - (Double(y) + 0.5) / (0.4 * Double(height)))
        for index in (y * width * 3)..<((y + 1) * width * 3) {
            if ramp == 0 {
                #expect(burned[index] == plain[index], "row \(y)")
            } else {
                #expect(abs(Double(burned[index] - plain[index]) - 1.5 * ramp * log10(2)) < 1e-5, "row \(y)")
            }
        }
    }
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
        print("\(name) \(paper): \(difference)")
        #expect(difference.maxRelative < 1e-6)
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
    print("\(caseName) cmy_print: \(difference)")
    #expect(difference.maxAbsolute < 1e-4)
}
