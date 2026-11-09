import Metal
import Testing
@testable import SpektraEngine

/// The black-and-white stocks against Spektrafilm's `dev`, which has them (`main`, which the rest
/// of these tests check against, doesn't): the cases tools/black_and_white.py writes, stage by
/// stage, each stage fed the reference data of the one before it, and the whole chain.
///
/// `dev` renders through newer steps than the engine ports, so that script pins them to the
/// engine's. A case here is therefore the engine's own parameters for its film and paper
/// (``BlackAndWhiteCase``), not parameters read from `dev`.
///
/// The tolerances are the colour stocks' for the same stage (FilmingTests, PrintingTests,
/// ScanningTests), but for the one noted below.
private let blackAndWhiteCases = [
    "chart-kodak_doublex-kodak_2302", "chart-kodak_doublex-kodak_2302-developed_8_2.5",
    "chart-kodak_doublex-kodak_portra_endura", "chart-kodak_doublex-scan", "chart-kodak_trix-scan",
    "chart-kodak_portra_400-kodak_2302", "photo-kodak_doublex-kodak_2302",
]
private let printedCases = blackAndWhiteCases.filter { !$0.hasSuffix("scan") }

/// A case named `<chart or photo>-<film>-<paper, or scan>`, then `-developed_<minutes>_<minutes>`
/// where the film and the paper were asked to be developed for other than their standard times
/// (8 and 2.5 minutes, which are developed as the nearest measured, 9 and 2): its profiles, and
/// the parameters the app exports that film on that paper with, as the reference run has them:
/// the chart in linear ProPhoto RGB and per pixel, the photo in sRGB, encoded sRGB out, and no
/// grain or glare.
private struct BlackAndWhiteCase {
    let film: Profile
    let paper: Profile
    let parameters: Parameters

    init(_ name: String) throws {
        let parts = name.split(separator: "-").map(String.init)
        var controls = Controls()
        controls.film = parts[1]
        controls.scanFilm = parts[2] == "scan"
        if !controls.scanFilm {
            controls.paper = parts[2]
        }
        if parts.count == 4 {
            let minutes = parts[3].split(separator: "_").compactMap { Double($0) }
            (controls.filmDevelopmentTime, controls.paperDevelopmentTime) = (minutes[0], minutes[1])
        }
        film = try Profile.load(controls.film)
        paper = try Profile.load(controls.paper)
        var parameters = Engine.parameters(for: controls, film: film, print: paper,
                                           database: try Tables.loadNeutralPrintFilters(), mode: .export)
        parameters.io.outputColorSpace = "sRGB"
        parameters.filmRender.grain.active = false
        parameters.printRender.glare.active = false
        if parts[0] == "chart" {
            parameters.io.inputColorSpace = "ProPhoto RGB"
            parameters.applyPerPixelMode()
        } else {
            parameters.io.inputColorSpace = "sRGB"
            parameters.io.inputCctfDecoding = true
        }
        self.parameters = parameters
    }

    func simulation(on gpu: GPU) throws -> Simulation {
        try Simulation(parameters: parameters, film: film, print: paper, gpu: gpu, tables: Tables.load(),
                       intermediateFormat: .rgba32Float)
    }
}

/// One tap of a case as the engine holds it: a one-layer stock's single channel in all three
/// (``Profile``).
private func tap(_ caseName: String, _ name: String) throws -> RGBImage {
    let array = try golden(caseName, name)
    return RGBImage(width: array.shape[1], height: array.shape[0],
                    pixels: array.shape[2] == 1 ? array.values.flatMap { [$0, $0, $0] } : array.values)
}

/// A stage's output for `input`, the tap before it.
private func run(_ caseName: String, from input: String,
                 _ stage: (Simulation, any MTLTexture, Encoder) -> any MTLTexture) throws -> [Float] {
    let gpu = try GPU()
    let simulation = try BlackAndWhiteCase(caseName).simulation(on: gpu)
    let reference = try tap(caseName, input)
    let texture = gpu.upload(rgb: reference.pixels, width: reference.width, height: reference.height)
    return gpu.download(try gpu.run { stage(simulation, texture, $0) })
}

@Test(arguments: blackAndWhiteCases.filter { $0.hasPrefix("chart") })
func blackAndWhiteFilmingLUTMatchesDev(caseName: String) throws {
    let golden = try BlackAndWhiteCase(caseName)
    let lut = filmingTCLUT(film: golden.film, parameters: golden.parameters, tables: try Tables.load(),
                           spectra: try Tables.loadSpectraLUT())
    let difference = Difference(lut.flatMap { [$0.x, $0.y, $0.z] }, try tap(caseName, "tc_lut").pixels, floor: 1e-3)
    expectParity(difference.maxRelative, below: 1e-6, "compressed tc LUT max rel", case: caseName)
}

@Test(arguments: blackAndWhiteCases)
func blackAndWhiteExposeMatchesDev(caseName: String) throws {
    let result = try run(caseName, from: "rgb_pre") { $0.encodeExpose($1, on: $2) }
    let difference = Difference(result, try tap(caseName, "log_e_film").pixels, floor: 1)
    expectParity(difference.maxAbsolute, below: 2e-5, "log_e_film max abs", case: caseName)
}

@Test(arguments: blackAndWhiteCases)
func blackAndWhiteDevelopMatchesDev(caseName: String) throws {
    let result = try run(caseName, from: "log_e_film") { $0.encodeDevelop($1, on: $2) }
    let difference = Difference(result, try tap(caseName, "cmy_film").pixels, floor: 1)
    expectParity(difference.maxAbsolute, below: hasPhotoEffects(caseName) ? 5e-2 : 4e-6, "cmy_film max abs", case: caseName)
}

@Test(arguments: printedCases)
func blackAndWhitePrintExposeMatchesDev(caseName: String) throws {
    let result = try run(caseName, from: "cmy_film") { $0.encodePrintExpose($1, on: $2) }
    let difference = Difference(result, try tap(caseName, "log_e_print").pixels, floor: 1)
    expectParity(difference.maxAbsolute, below: 2e-6, "log_e_print max abs", case: caseName)
}

@Test(arguments: printedCases)
func blackAndWhitePrintDevelopMatchesDev(caseName: String) throws {
    let result = try run(caseName, from: "log_e_print") { $0.encodePrintDevelop($1, on: $2) }
    let difference = Difference(result, try tap(caseName, "cmy_print").pixels, floor: 1)
    expectParity(difference.maxAbsolute, below: 2e-6, "cmy_print max abs", case: caseName)
}

/// The whole chain from the exposed input, `rgb_pre → rgb_out`, also as 8-bit values.
@Test(arguments: blackAndWhiteCases)
func blackAndWhiteChainMatchesDev(caseName: String) throws {
    let result = try run(caseName, from: "rgb_pre") { simulation, input, encoder in
        simulation.encodePrintAndScan(simulation.encodeDevelop(simulation.encodeExpose(input, on: encoder), on: encoder),
                                      on: encoder)
    }
    let reference = try tap(caseName, "rgb_out").pixels
    let difference = Difference(result, reference, floor: 1)
    func eightBit(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    let steps = zip(result, reference).map { abs(eightBit($0) - eightBit($1)) }
    let identical = Double(steps.filter { $0 == 0 }.count) / Double(steps.count)
    let photo = hasPhotoEffects(caseName)
    expectParity(difference.maxAbsolute, below: photo ? 2e-2 : 2e-5, "rgb_out max abs", case: caseName)
    expectParity(Double(steps.max()!), atMost: photo ? 3 : 2, "8-bit steps, max", case: caseName)
    // The chart: 3× the most measured, 0.00089 for Double-X on Portra Endura, where one patch's 256
    // values are 4e-6 of a level from rounding the other way (191.499996) and do. 0.00002 elsewhere.
    expectParity(1 - identical, atMost: photo ? 0.02 : 0.003, "8-bit values not identical", case: caseName)
}
