import Foundation
import SpektraEngine

// Grows into `render` and stage-dump commands as the engine is ported (PLAN.md).
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "benchmark":
    if let path = arguments.dropFirst().first, Int(path) == nil {
        // spektra-cli benchmark <photo>: times the app's renders of a photo (the README's figures).
        try await benchmarkRenders(of: URL(filePath: path))
    } else {
        // spektra-cli benchmark [width height]: times each ported stage on a synthetic image.
        let numbers = arguments.dropFirst().compactMap { Int($0) }
        let (width, height) = numbers.count == 2 ? (numbers[0], numbers[1]) : (6000, 4000)
        try benchmark(width: width, height: height)
    }
default:
    print("spektra-cli — Spektrafilm \(SpektraEngine.referenceVersion) port")
    print("GPU: \(try GPU().device.name)")
    print("Usage: spektra-cli benchmark [width height | photo]")
}

/// The app's renders of `url` with the default settings (Portra 400 printed on Portra Endura): the
/// full render with every effect, as a save makes it, and the live preview that follows each change.
/// The best of several runs, each through every stage.
func benchmarkRenders(of url: URL) async throws {
    let engine = try Engine()
    let image = try RGBImage.decode(contentsOf: url)
    _ = try await engine.open(image)
    print("\(url.lastPathComponent), \(Int(image.extent.width)) × \(Int(image.extent.height)), on \(try GPU().device.name)")
    for (label, mode, runs) in [("full render", RenderMode.full, 3), ("preview", .preview, 10)] {
        var best = Duration.seconds(Int.max)
        for run in 0...runs {
            // A different exposure each time: the engine keeps the film's steps for renders that
            // only change the print, and this times every stage.
            var controls = Controls()
            controls.exposureOffsetEV = Double(run) * 0.01
            let start = ContinuousClock.now
            _ = try await engine.render(controls: controls, mode: mode)
            best = min(best, ContinuousClock.now - start)
        }
        print("\(label): \(best.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 0))))")
    }
}

func benchmark(width: Int, height: Int) throws {
    let gpu = try GPU()
    gpu.heap = gpu.reservedMemory(width: width, height: height)  // as the app does for a full render
    let film = try Profile.load("kodak_portra_400")
    let paper = try Profile.load("kodak_portra_endura")
    var parameters = Parameters()
    parameters.applyNeutralPrintFilters(film: film, print: paper, database: try Tables.loadNeutralPrintFilters())
    parameters.applyFilmSpecifics(film)
    var clock = ContinuousClock.now
    func lap(_ label: String) {
        let now = ContinuousClock.now
        print("\(label.padding(toLength: 40, withPad: " ", startingAt: 0)) \((now - clock).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        clock = now
    }

    let simulation = try Simulation(parameters: parameters, film: film, print: paper, gpu: gpu, tables: Tables.load())
    lap("setup (tc LUT, print constants, C_max)")
    // A smooth gradient with texture: values span the exposure range like a photo.
    var pixels = [Float](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 3
            pixels[index] = Float(x) / Float(width)
            pixels[index + 1] = Float(y) / Float(height)
            pixels[index + 2] = Float((x ^ y) & 255) / 255
        }
    }
    let image = RGBImage(width: width, height: height, pixels: pixels)
    print("\(width) × \(height) on \(gpu.device.name)")
    clock = .now

    // Stage by stage; the scope frees the stage outputs before the whole chain runs.
    do {
        let rgbPre = try gpu.run { simulation.encodePreprocess(image, on: $0) }
        lap("rgb_in → rgb_pre (AE on CPU, upload)")
        let logEFilm = try gpu.run { simulation.encodeExpose(rgbPre, on: $0) }
        lap("rgb_pre → log_e_film (halation)")
        let cmyFilm = try gpu.run { simulation.encodeDevelop(logEFilm, on: $0) }
        lap("log_e_film → cmy_film (couplers)")
        let logEPrint = try gpu.run { simulation.encodePrintExpose(cmyFilm, on: $0) }
        lap("cmy_film → log_e_print (81 bands)")
        let cmyPrint = try gpu.run { simulation.encodePrintDevelop(logEPrint, on: $0) }
        lap("log_e_print → cmy_print")
        let scanned = try gpu.run { simulation.encodeDensityToRGB(cmyPrint, on: $0) }
        lap("cmy_print → scanned RGB (81 bands)")
        _ = try gpu.run { simulation.encodeOutputCompression(scanned, on: $0) }
        lap("output gamut compression (cam16ucs)")
        print("allocated on the GPU (incl. reserved): \(gpu.device.currentAllocatedSize / 1_000_000) MB")
    }

    // The app's path: the whole chain in one run.
    var peak = 0
    _ = try gpu.run { encoder in
        defer { peak = encoder.peakAllocatedSize }
        return simulation.encode(image, on: encoder)
    }
    lap("whole chain (rgb_in → rgb_out)")
    print("peak in use on the GPU: \(peak / 1_000_000) MB")
}
