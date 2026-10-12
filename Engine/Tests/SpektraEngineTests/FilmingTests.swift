import Metal
import Testing
@testable import SpektraEngine

@Test(arguments: goldenCases)
func preprocessMatchesRGBPre(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let tables = try Tables.load()
    let rgbIn = try SpektraEngineTests.golden(caseName, "rgb_in").image
    let reference = try SpektraEngineTests.golden(caseName, "rgb_pre")

    if golden.params.camera.autoExposure {
        let ev = autoExposureEV(of: rgbIn, colourSpace: tables.colourSpaces[golden.params.io.inputColorSpace]!,
                                cctfDecoding: golden.params.io.inputCctfDecoding)
        print("\(caseName) auto-exposure: \(ev) EV, Python \(golden.autoexposureEv) EV")
        #expect(abs(ev - golden.autoexposureEv) < 1e-6)
    }

    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film), gpu: gpu, tables: tables)
    let output = try gpu.run { simulation.encodePreprocess(rgbIn, on: $0) }
    let difference = Difference(gpu.download(output), reference.values, floor: 1e-3)
    print("\(caseName) rgb_pre: \(difference)")
    #expect(difference.maxRelative < 1e-4)
}

@Test func transferFunctionsMatchColourScience() throws {
    // colour.cctf_decoding(v, function=...) for each space's transfer function.
    let tables = try Tables.load()
    let cases: [(String, [Double], [Double])] = [
        ("sRGB", [-0.1, 0.02, 0.040449936, 0.5, 1.2],
         [-0.007739938080495357, 0.0015479876160990713, 0.0031308, 0.21404114048223255, 1.5168374366863642]),
        ("ProPhoto RGB", [-0.1, 0.02, 0.03125, 0.5, 1.2],
         [-0.00625, 0.00125, 0.0019531249999999998, 0.2871745887492587, 1.388437205763783]),
        ("ITU-R BT.2020", [-0.1, 0.05, 0.081, 0.5, 1.2],
         [-0.022222222222222223, 0.011111111111111112, 0.018000000000000002, 0.25958940050628576, 1.4499692663588764]),
        ("Adobe RGB (1998)", [0.02, 0.5, 1.2], [0.00018348193467219382, 0.21775552814439456, 1.4932649827486288]),
        ("DCI-P3", [0.02, 0.5, 1.2], [3.825409999160147e-05, 0.16493848884661177, 1.6064648952909515]),
        ("ACES2065-1", [-0.1, 0.5], [-0.1, 0.5]),
    ]
    for (name, encoded, linear) in cases {
        let space = try #require(tables.colourSpaces[name])
        #expect(Difference(encoded.map(space.decode), linear, floor: 1e-6).maxRelative < 1e-12, "\(name)")
    }
}

@Test(arguments: ["kodak_portra_400", "kodak_vision3_500t", "fujifilm_velvia_100"])
func rawLUTMatchesPython(film: String) throws {
    var parameters = Parameters()
    parameters.io.inputGamutCompress.active = false
    let lut = filmingTCLUT(film: try Profile.load(film), parameters: parameters, tables: try Tables.load(),
                           spectra: try Tables.loadSpectraLUT())
    let reference = try golden("primitives", "tc_lut_raw_\(film)")
    let difference = Difference(lut.flatMap { [$0.x, $0.y, $0.z] }, reference.values, floor: 1e-3)
    print("\(film) raw tc LUT: \(difference)")
    #expect(difference.maxRelative < 1e-6)
}

/// The LUT each golden run actually used: gamut compression baked in.
@Test(arguments: goldenCases.filter { $0.hasPrefix("chart") })
func filmingLUTMatchesPython(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let lut = filmingTCLUT(film: try Profile.load(golden.film), parameters: golden.params, tables: try Tables.load(),
                           spectra: try Tables.loadSpectraLUT())
    let reference = try SpektraEngineTests.golden(caseName, "tc_lut")
    let difference = Difference(lut.flatMap { [$0.x, $0.y, $0.z] }, reference.values, floor: 1e-3)
    print("\(golden.film) compressed tc LUT: \(difference)")
    #expect(difference.maxRelative < 1e-6)
}

/// Chart: per-pixel (lut_mode). Photo: sRGB decoding, auto-exposed input, scatter and halation.
@Test(arguments: goldenCases)
func exposeMatchesLogEFilm(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film), gpu: gpu,
                                    tables: Tables.load())
    let rgbPre = try SpektraEngineTests.golden(caseName, "rgb_pre")
    let input = gpu.upload(rgb: rgbPre.values, width: rgbPre.shape[1], height: rgbPre.shape[0])
    let output = try gpu.run { simulation.encodeExpose(input, on: $0) }
    let reference = try SpektraEngineTests.golden(caseName, "log_e_film")
    // log10 exposure: absolute error is relative error of the exposure / ln 10.
    let difference = Difference(gpu.download(output), reference.values, floor: 1)
    print("\(caseName) log_e_film: \(difference)")
    #expect(difference.maxAbsolute < 1e-4)
}

@Test func boostHighlightsMatchesPython() throws {
    let gpu = try GPU()
    let x = try golden("primitives", "boost_x")
    let input = gpu.upload(rgb: x.values, width: x.shape[1], height: x.shape[0])
    let output = try gpu.run {
        gpu.encodeBoostHighlights(on: $0, input: input, boostEv: 2, boostRange: 0.3, protectEv: 1)
    }
    let difference = Difference(gpu.download(output), try golden("primitives", "boost_out").values, floor: 1)
    print("boost: \(difference)")
    #expect(difference.maxRelative < 1e-6)
}

@Test func halationMatchesPythonAtFullResolutionScale() throws {
    // Portra 400's digested halation at a 5 µm pixel: σ_h = 13 px, so the IIR path runs too.
    let halation = try GoldenCase("photo-kodak_portra_400-kodak_portra_endura").params.filmRender.halation
    let gpu = try GPU()
    let x = try golden("primitives", "halation_x")
    let input = gpu.upload(rgb: x.values, width: x.shape[1], height: x.shape[0])
    let output = try gpu.run { gpu.encodeHalation(on: $0, input: input, halation: halation, pixelSizeUm: 5) }
    let difference = Difference(gpu.download(output), try golden("primitives", "halation_out").values, floor: 1)
    print("halation at 5 µm: \(difference)")
    #expect(difference.maxAbsolute < 1e-6)
}

@Test(arguments: goldenCases.filter { $0.hasPrefix("photo") })
func halationPresetMatchesDigest(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    var parameters = Parameters()
    parameters.applyFilmSpecifics(try Profile.load(golden.film))
    #expect(parameters.filmRender.halation.halationStrength == golden.params.filmRender.halation.halationStrength)
    #expect(parameters.filmRender.halation.halationFirstSigmaUm == golden.params.filmRender.halation.halationFirstSigmaUm)
}
