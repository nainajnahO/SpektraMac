import Foundation
import SpektraEngine

// Grows into `render` and stage-dump commands as the engine is ported (PLAN.md).
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "benchmark":
    // spektra-cli benchmark [width height]: times each ported stage on a synthetic image.
    let numbers = arguments.dropFirst().compactMap { Int($0) }
    let (width, height) = numbers.count == 2 ? (numbers[0], numbers[1]) : (6000, 4000)
    try benchmark(width: width, height: height)
default:
    print("spektra-cli — Spektrafilm \(SpektraEngine.referenceVersion) port")
    print("GPU: \(try GPU().device.name)")
    print("Usage: spektra-cli benchmark [width height]")
}

func benchmark(width: Int, height: Int) throws {
    let gpu = try GPU()
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
    let scanned = try gpu.run { simulation.encodeScan(cmyPrint, on: $0) }
    lap("cmy_print → scanned RGB (81 bands)")
    _ = try gpu.run { simulation.encodeOutputCompression(scanned, on: $0) }
    lap("output gamut compression (cam16ucs)")
    print("allocated on the GPU: \(gpu.device.currentAllocatedSize / 1_000_000) MB")
}
