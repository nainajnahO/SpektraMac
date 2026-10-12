import Accelerate
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
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film), print: golden.printProfile(), gpu: gpu, tables: tables)
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
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film), print: golden.printProfile(), gpu: gpu,
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

@Test(arguments: goldenCases)
func developMatchesPythonWithoutCouplers(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    var parameters = golden.params
    parameters.filmRender.dirCouplers.active = false
    let simulation = try Simulation(parameters: parameters, film: Profile.load(golden.film), print: golden.printProfile(), gpu: gpu,
                                    tables: Tables.load())
    let logEFilm = try SpektraEngineTests.golden(caseName, "log_e_film")
    let input = gpu.upload(rgb: logEFilm.values, width: logEFilm.shape[1], height: logEFilm.shape[0])
    let output = try gpu.run { simulation.encodeDevelop(input, on: $0) }
    let reference = try SpektraEngineTests.golden(caseName, "cmy_film_no_couplers")
    let difference = Difference(gpu.download(output), reference.values, floor: 1)
    print("\(caseName) density without couplers: \(difference)")
    #expect(difference.maxAbsolute < 1e-5)
}

/// Chart: couplers without diffusion (lut_mode). Photo: with the inhibitor diffusion blur.
@Test(arguments: goldenCases)
func developMatchesCMYFilm(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film), print: golden.printProfile(), gpu: gpu,
                                    tables: Tables.load())
    let logEFilm = try SpektraEngineTests.golden(caseName, "log_e_film")
    let input = gpu.upload(rgb: logEFilm.values, width: logEFilm.shape[1], height: logEFilm.shape[0])
    let output = try gpu.run { simulation.encodeDevelop(input, on: $0) }
    let reference = try SpektraEngineTests.golden(caseName, "cmy_film")
    let difference = Difference(gpu.download(output), reference.values, floor: 1)
    print("\(caseName) cmy_film: \(difference)")
    #expect(difference.maxAbsolute < 1e-4)
}

@Test(arguments: goldenCases.filter { $0.hasPrefix("photo") })
func couplerSettingsMatchDigest(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    var parameters = Parameters()
    parameters.applyFilmSpecifics(try Profile.load(golden.film))
    let ours = parameters.filmRender.dirCouplers, theirs = golden.params.filmRender.dirCouplers
    #expect(ours.gammaSamelayerRgb == theirs.gammaSamelayerRgb)
    #expect(ours.gammaInterlayerRToGb == theirs.gammaInterlayerRToGb)
    #expect(ours.gammaInterlayerGToRb == theirs.gammaInterlayerGToRb)
    #expect(ours.gammaInterlayerBToRg == theirs.gammaInterlayerBToRg)
}

/// The filming chain end to end from the golden input: rgb_in → rgb_pre → log_e_film → cmy_film.
@Test(arguments: goldenCases)
func filmingChainMatchesCMYFilm(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: golden.params, film: Profile.load(golden.film), print: golden.printProfile(), gpu: gpu,
                                    tables: Tables.load())
    let rgbIn = try SpektraEngineTests.golden(caseName, "rgb_in").image
    let output = try gpu.run { encoder in
        simulation.encodeDevelop(simulation.encodeExpose(simulation.encodePreprocess(rgbIn, on: encoder), on: encoder),
                                 on: encoder)
    }
    let difference = Difference(gpu.download(output), try SpektraEngineTests.golden(caseName, "cmy_film").values, floor: 1)
    print("\(caseName) chain to cmy_film: \(difference)")
    #expect(difference.maxAbsolute < 1e-4)
}

/// Grain's particle model against Python's on uniform density patches (both random, so per patch
/// and channel the mean and standard deviation compare): 8 levels from 2 % to 98 % of each
/// channel's maximum density, at 5 µm pixels, without the blurs and micro-structure.
@Test(arguments: ["kodak_portra_400", "fujifilm_velvia_100"])
func grainParticlesMatchPythonStatistics(film: String) throws {
    var parameters = Parameters()
    parameters.filmRender.grain.blur = 0
    parameters.filmRender.grain.blurDyeCloudsUm = 0
    parameters.filmRender.grain.microStructure = [0, 0]
    let gpu = try GPU()
    let simulation = try Simulation(parameters: parameters, film: Profile.load(film),
                                    print: Profile.load("kodak_portra_endura"), gpu: gpu, tables: Tables.load())
    let x = try golden("primitives", "grain_x_\(film)")
    let input = gpu.upload(rgb: x.values, width: x.shape[1], height: x.shape[0])
    let ours = gpu.download(try gpu.run { simulation.encodeGrain(input, pixelSizeUm: 5, on: $0) })
    let python = try golden("primitives", "grain_out_\(film)").values
    func statistics(_ values: [Float], level: Int, channel: Int) -> (mean: Double, deviation: Double) {
        let patch = (0..<128).flatMap { row in
            (0..<128).map { column in Double(values[(row * 1024 + level * 128 + column) * 3 + channel]) }
        }
        let mean = patch.reduce(0, +) / Double(patch.count)
        return (mean, (patch.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(patch.count - 1)).squareRoot())
    }
    var worst = (mean: 0.0, deviation: 0.0)
    for level in 0..<8 {
        for channel in 0..<3 {
            let (a, b) = (statistics(ours, level: level, channel: channel), statistics(python, level: level, channel: channel))
            worst.mean = max(worst.mean, abs(a.mean / b.mean - 1))
            worst.deviation = max(worst.deviation, abs(a.deviation / b.deviation - 1))
            if level == 0 || level == 4 || level == 7 {
                print(String(format: "%@ level %d channel %d: mean %.5f vs %.5f, std %.5f vs %.5f",
                             film, level, channel, a.mean, b.mean, a.deviation, b.deviation))
            }
        }
    }
    print("\(film) grain particles, worst over 24 patches: mean \(worst.mean * 100) %, std \(worst.deviation * 100) %")
    #expect(worst.mean < 0.05 && worst.deviation < 0.05)
}

/// Grain complete (default parameters) on a golden field `grain_<name>_x_<film>`: ours and Python's.
private func grainField(_ name: String, film: String, pixelSizeUm: Double) throws
-> (ours: [Float], python: [Float], width: Int, height: Int) {
    let gpu = try GPU()
    let simulation = try Simulation(parameters: Parameters(), film: Profile.load(film),
                                    print: Profile.load("kodak_portra_endura"), gpu: gpu, tables: Tables.load())
    let x = try golden("primitives", "grain_\(name)_x_\(film)")
    let input = gpu.upload(rgb: x.values, width: x.shape[1], height: x.shape[0])
    let ours = gpu.download(try gpu.run { simulation.encodeGrain(input, pixelSizeUm: pixelSizeUm, on: $0) })
    return (ours, try golden("primitives", "grain_\(name)_out_\(film)").values, x.shape[1], x.shape[0])
}

/// Mean and standard deviation of one channel over columns `columns` of an RGB field.
private func statistics(_ values: [Float], width: Int, columns: Range<Int>, channel: Int) -> (mean: Double, deviation: Double) {
    let height = values.count / 3 / width
    let patch = (0..<height).flatMap { row in columns.map { Double(values[(row * width + $0) * 3 + channel]) } }
    let mean = patch.reduce(0, +) / Double(patch.count)
    return (mean, (patch.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(patch.count - 1)).squareRoot())
}

/// Grain complete with the default parameters (dye clouds, final blur) against Python's: mean and
/// RMS granularity (the density's standard deviation) per patch and channel, on 4 uniform
/// patches (10 % to 90 % of each channel's maximum) at 5 µm pixels.
@Test(arguments: ["kodak_portra_400", "fujifilm_velvia_100"])
func grainMatchesPythonStatistics(film: String) throws {
    let (ours, python, width, _) = try grainField("full", film: film, pixelSizeUm: 5)
    var worst = (mean: 0.0, deviation: 0.0)
    for patch in 0..<4 {
        for channel in 0..<3 {
            let columns = (patch * 256)..<((patch + 1) * 256)
            let a = statistics(ours, width: width, columns: columns, channel: channel)
            let b = statistics(python, width: width, columns: columns, channel: channel)
            worst.mean = max(worst.mean, abs(a.mean / b.mean - 1))
            worst.deviation = max(worst.deviation, abs(a.deviation / b.deviation - 1))
            print(String(format: "%@ patch %d channel %d: mean %.5f vs %.5f, RMS granularity %.5f vs %.5f",
                         film, patch, channel, a.mean, b.mean, a.deviation, b.deviation))
        }
    }
    print("\(film) grain, worst over 12 patches: mean \(worst.mean * 100) %, RMS granularity \(worst.deviation * 100) %")
    #expect(worst.mean < 0.05 && worst.deviation < 0.05)
}

/// Grain's power spectrum against Python's on a 512 × 512 uniform field (Portra, 50 %, 5 µm): the
/// periodograms of every row and column (the grain is isotropic) summed in 8 bands of 32
/// frequencies up to Nyquist.
@Test func grainPowerSpectrumMatchesPython() throws {
    let (ours, python, width, _) = try grainField("field", film: "kodak_portra_400", pixelSizeUm: 5)
    let dft = try vDSP.DiscreteFourierTransform(count: width, direction: .forward, transformType: .complexComplex,
                                                ofType: Double.self)
    func bands(_ values: [Float], channel: Int) -> [Double] {
        var power = [Double](repeating: 0, count: width / 2 + 1)
        var (real, imaginary) = ([Double](repeating: 0, count: width), [Double](repeating: 0, count: width))
        let rows = (0..<width).map { row in (0..<width).map { Double(values[(row * width + $0) * 3 + channel]) } }
        let columns = (0..<width).map { column in rows.map { $0[column] } }
        for line in rows + columns {
            let mean = line.reduce(0, +) / Double(width)
            dft.transform(inputReal: line.map { $0 - mean }, inputImaginary: [Double](repeating: 0, count: width),
                          outputReal: &real, outputImaginary: &imaginary)
            for k in 0...(width / 2) {
                power[k] += real[k] * real[k] + imaginary[k] * imaginary[k]
            }
        }
        return (0..<8).map { band in power[(band * 32 + 1)...(band * 32 + 32)].reduce(0, +) }
    }
    var worst = 0.0
    for channel in 0..<3 {
        let ratios = zip(bands(ours, channel: channel), bands(python, channel: channel)).map { $0 / $1 }
        worst = max(worst, ratios.map { abs($0 - 1) }.max()!)
        print("grain power spectrum channel \(channel), ours / Python per band: \(ratios.map { String(format: "%.3f", $0) })")
    }
    print("grain power spectrum, worst band: \(worst * 100) %")
    #expect(worst < 0.05)
}

/// Grain with the micro-structure on (0.4 µm pixels: clumping σ 0.075, blurred 0.5 px) against
/// Python's: mean and RMS granularity per channel over a 256 × 256 uniform field.
@Test func grainMicroStructureMatchesPython() throws {
    let (ours, python, width, _) = try grainField("micro", film: "kodak_portra_400", pixelSizeUm: 0.4)
    for channel in 0..<3 {
        let a = statistics(ours, width: width, columns: 0..<width, channel: channel)
        let b = statistics(python, width: width, columns: 0..<width, channel: channel)
        print(String(format: "micro-structure channel %d: mean %.5f vs %.5f, RMS granularity %.5f vs %.5f",
                     channel, a.mean, b.mean, a.deviation, b.deviation))
        #expect(abs(a.mean / b.mean - 1) < 0.05 && abs(a.deviation / b.deviation - 1) < 0.05)
    }
}
