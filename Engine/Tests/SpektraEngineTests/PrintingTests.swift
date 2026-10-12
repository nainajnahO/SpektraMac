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
