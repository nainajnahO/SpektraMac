import CoreImage
import Foundation
import Metal
import Testing
@testable import SpektraEngine

/// SpektraMac's side of `tools/port_report.py`: each case the script wrote to the folder
/// `SPEKTRA_PORT_REPORT` names, run on the same input as its Python step, timed (best of 5 after a
/// warm-up run), its output written as `<case>/mac.npy` and the times to `mac.json`. Without the
/// variable it does nothing, so a normal test run passes it.
@Test func portReport() throws {
    guard let path = ProcessInfo.processInfo.environment["SPEKTRA_PORT_REPORT"] else { return }
    let folder = URL(filePath: path)
    let cases = try JSONDecoder().decode([PortCase].self, from: Data(contentsOf: folder.appending(component: "cases.json")))
    let gpu = try GPU()
    var seconds: [String: Double] = [:]
    for portCase in cases {
        let step = try macStep(portCase, in: folder.appending(component: portCase.name), gpu: gpu)
        try step.run()
        var best = Duration.seconds(Int.max)
        for _ in 0..<5 {
            let start = ContinuousClock.now
            try step.run()
            best = min(best, ContinuousClock.now - start)
        }
        let (values, shape) = step.output()
        try writeNPY(values, shape: shape, to: folder.appending(components: portCase.name, "mac.npy"))
        seconds[portCase.name] = Double(best.components.seconds) + Double(best.components.attoseconds) * 1e-18
        print("\(portCase.name): \(best)")
    }
    try JSONEncoder().encode(seconds).write(to: folder.appending(component: "mac.json"))
}

private struct PortCase: Decodable {
    let name: String
    let params: [String: [Double]]
}

/// One case's SpektraMac step: `run` does the timed work, `output` reads back the last run's result.
private struct MacStep {
    let run: () throws -> Void
    let output: () -> (values: [Float], shape: [Int])
}

private func macStep(_ portCase: PortCase, in folder: URL, gpu: GPU) throws -> MacStep {
    let photo = try GoldenCase("photo")
    let tables = try Tables.load()
    func input() throws -> any MTLTexture {
        let array = try NPYArray(contentsOf: folder.appending(component: "x.npy"))
        return gpu.upload(rgb: array.values, width: array.shape[1], height: array.shape[0])
    }
    func tap(_ name: String) throws -> any MTLTexture {
        let array = try golden("photo", name)
        return gpu.upload(rgb: array.values, width: array.shape[1], height: array.shape[0])
    }
    func parameter(_ name: String) -> Double { portCase.params[name]![0] }
    func triple(_ name: String) -> SIMD3<Double> {
        let values = portCase.params[name]!
        return SIMD3(values[0], values[1], values[2])
    }
    func rows(_ name: String) -> [SIMD3<Double>] {
        let values = portCase.params[name]!
        return stride(from: 0, to: values.count, by: 3).map { SIMD3(values[$0], values[$0 + 1], values[$0 + 2]) }
    }
    func simulation(_ format: MTLPixelFormat = .rgba32Float) throws -> Simulation {
        try Simulation(parameters: photo.params, film: Profile.load(photo.film), print: photo.printProfile(), gpu: gpu,
                       tables: tables, intermediateFormat: format)
    }
    func onGPU(_ encode: @escaping (Encoder) -> any MTLTexture) -> MacStep {
        var result: (any MTLTexture)?
        return MacStep(run: { result = try gpu.run(encode) },
                       output: { (gpu.download(result!), [result!.height, result!.width, 3]) })
    }
    /// For a step that works in place: each run on a copy of `texture`.
    func onGPU(copying texture: any MTLTexture, _ encode: @escaping (Encoder, any MTLTexture) -> any MTLTexture) -> MacStep {
        onGPU { encoder in
            let copy = gpu.makeTexture(like: texture)
            gpu.encodeScale(on: encoder, input: texture, output: copy, by: 1)
            return encode(encoder, copy)
        }
    }
    func onCPU(shape: [Int], _ compute: @escaping () throws -> [Double]) -> MacStep {
        var result: [Double] = []
        return MacStep(run: { result = try compute() }, output: { (result.map(Float.init), shape) })
    }
    func scalars(_ vectors: [SIMD3<Double>]) -> [Double] { vectors.flatMap { [$0.x, $0.y, $0.z] } }

    switch portCase.name {
    case "preprocess":
        let (simulation, image) = (try simulation(), try golden("photo", "rgb_in").image)
        return onGPU { simulation.encodePreprocess(image, on: $0) }
    case "filming.expose":
        let (simulation, input) = (try simulation(), try tap("rgb_pre"))
        return onGPU { simulation.encodeExpose(input, on: $0) }
    case "filming.develop":
        let (simulation, input) = (try simulation(), try tap("log_e_film"))
        return onGPU { simulation.encodeDevelop(input, on: $0) }
    case "printing.expose":
        let (simulation, input) = (try simulation(), try tap("cmy_film"))
        return onGPU { simulation.encodePrintExpose(input, on: $0) }
    case "printing.develop":
        let (simulation, input) = (try simulation(), try tap("log_e_print"))
        return onGPU { simulation.encodePrintDevelop(input, on: $0) }
    case "scanning.scan_print":
        let (simulation, input) = (try simulation(), try tap("cmy_print"))
        return onGPU { simulation.encodeScan(input, on: $0) }
    case "chain", "chain_app":
        let simulation = try simulation(portCase.name == "chain" ? .rgba32Float : .rgba16Float)
        let image = try golden("photo", "rgb_in").image
        return onGPU { simulation.encode(image, on: $0) }
    case "auto_exposure":
        let image = try golden("photo", "rgb_in").image
        return onCPU(shape: [1]) { [autoExposureEV(of: image, colourSpace: tables.colourSpaces["sRGB"]!, cctfDecoding: true)] }
    case "tc_lut":
        let (film, spectra) = (try Profile.load(photo.film), try Tables.loadSpectraLUT())
        return onCPU(shape: [192, 192, 3]) {
            scalars(filmingTCLUT(film: film, parameters: photo.params, tables: tables, spectra: spectra))
        }
    case "boost":
        let input = try input()
        return onGPU { gpu.encodeBoostHighlights(on: $0, input: input, boostEv: 2, boostRange: 0.3, protectEv: 1) }
    case "halation":
        let input = try input()
        return onGPU { gpu.encodeHalation(on: $0, input: input, halation: photo.params.filmRender.halation,
                                          pixelSizeUm: parameter("pixelSizeUm")) }
    case "diffusion", "glow_half":
        let input = try input()
        let filter = portCase.name == "diffusion"
            ? Parameters.DiffusionFilter(active: true, filterFamily: .blackProMist, strength: 0.5)
            : Parameters.DiffusionFilter(active: true, filterFamily: .cinebloom, strength: 2)
        let maxSamples = portCase.params["maxSamples"].map { Int($0[0]) } ?? GPU.maxFFTSamples
        return onGPU(copying: input) {
            gpu.encodeDiffusionFilter(on: $0, input: $1, filter: filter, pixelSizeUm: parameter("pixelSizeUm"),
                                      maxSamples: maxSamples)
        }
    case "interp":
        let input = try input()
        let (axis, values) = (rows("axis"), rows("values"))
        let output = gpu.makeTexture(like: input)
        return onGPU {
            gpu.encodeInterpolate(on: $0, input: input, output: output, axis: axis, values: values)
            return output
        }
    case "blur_mixed", "blur_equal":
        let input = try input()
        let output = gpu.makeTexture(like: input)
        return onGPU {
            gpu.encodeGaussianBlur(on: $0, input: input, output: output, sigma: triple("sigma"))
            return output
        }
    case "blur_exponential":
        let input = try input()
        let output = gpu.makeTexture(like: input)
        return onGPU {
            gpu.encodeExponentialBlur(on: $0, input: input, output: output, decay: triple("decay"))
            return output
        }
    case "grain":
        let input = try input()
        let simulation = try Simulation(parameters: Parameters(), film: Profile.load(photo.film),
                                        print: photo.printProfile(), gpu: gpu, tables: tables)
        return onGPU { simulation.encodeGrain(input, pixelSizeUm: parameter("pixelSizeUm"), on: $0) }
    case "enlarger":
        let enlarger = photo.params.enlarger
        return onCPU(shape: [81]) {
            enlargerLight(tables.illuminants[enlarger.illuminant]!, filters: enlarger.printFilters,
                          dichroics: tables.dichroicFilters)
        }
    case "print_curves":
        let paper = try photo.printProfile()
        let morph = Parameters.PrintCurvesMorph(active: true, gammaFactor: 1.2, gammaFactorFast: 0.9, gammaFactorSlow: 1.1,
                                                gammaFactorRed: 1.05, gammaFactorGreen: 0.97, gammaFactorBlue: 1.02,
                                                developerExhaustion: 0.4)
        return onCPU(shape: [256, 3]) {
            scalars(printCurves(paper.data.densityCurvesModel, logExposure: paper.data.logExposure, morph: morph,
                                positive: paper.info.type == .positive))
        }
    case "density_to_rgb":
        let (simulation, input) = (try simulation(), try tap("cmy_print"))
        return onGPU { simulation.encodeDensityToRGB(input, on: $0) }
    case "c_max":
        let io = photo.params.io
        return onCPU(shape: [64, 720]) {
            OutputGamutCompression(spec: io.outputGamutCompress, space: tables.colourSpaces[io.outputColorSpace]!,
                                   cat16: tables.chromaticAdaptation["CAT16"]!).maxChroma
        }
    case "output_compression":
        let (simulation, input) = (try simulation(), try input())
        return onGPU(copying: input) { simulation.encodeOutputCompression($1, on: $0) }
    case "scanner_optics":
        let (simulation, input) = (try simulation(), try input())
        return onGPU(copying: input) { simulation.encodeScannerOptics($1, on: $0) }
    case "output_encoding":
        let (simulation, input) = (try simulation(), try input())
        return onGPU(copying: input) { simulation.encodeOutputEncoding($1, on: $0) }
    case "glare":
        return onGPU { gpu.encodeGlareAmount(on: $0, width: 2400, height: 1600, glare: Parameters.Glare(), seed: Simulation.seed) }
    case "preview":
        let array = try NPYArray(contentsOf: folder.appending(component: "x.npy"))
        let image = RGBImage(width: array.shape[1], height: array.shape[0], pixels: array.values).ciImage
        let context = RGBImage.makeContext()
        var result: [Float] = []
        return MacStep(run: {
            let scaled = RGBImage.scaledDown(image, maxPixels: 600)
            var rgba = [Float](repeating: 0, count: Int(scaled.extent.width * scaled.extent.height) * 4)
            context.render(scaled, toBitmap: &rgba, rowBytes: Int(scaled.extent.width) * 16, bounds: scaled.extent,
                           format: .RGBAf, colorSpace: RGBImage.workingColorSpace)
            result = rgba
        }, output: {
            (stride(from: 0, to: result.count, by: 4).flatMap { result[$0..<($0 + 3)] }, [400, 600, 3])
        })
    default:
        throw UnknownCase(name: portCase.name)
    }
}

private struct UnknownCase: Error {
    let name: String
}

/// `values` as a float32 `.npy` of `shape`. Custom for the same reason as ``NPYArray``.
private func writeNPY(_ values: [Float], shape: [Int], to url: URL) throws {
    let dimensions = shape.count == 1 ? "\(shape[0])," : shape.map(String.init).joined(separator: ", ")
    var header = "{'descr': '<f4', 'fortran_order': False, 'shape': (\(dimensions)), }"
    // Padded so the data starts on a 64-byte boundary, as NumPy writes it.
    header += String(repeating: " ", count: 63 - (10 + header.utf8.count) % 64) + "\n"
    var data = Data([0x93] + Array("NUMPY".utf8) + [1, 0])
    data.append(contentsOf: [UInt8(header.utf8.count & 0xff), UInt8(header.utf8.count >> 8)])
    data.append(contentsOf: Array(header.utf8))
    values.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
}
