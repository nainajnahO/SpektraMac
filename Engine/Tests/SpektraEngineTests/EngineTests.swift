import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import simd
@testable import SpektraEngine

/// Writes an 8-bit sRGB PNG of `pixels` (RGB bytes) and returns its URL.
private func writePNG(_ pixels: [UInt8], width: Int, height: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(component: "\(UUID()).png")
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

@Test func photoDecodesRendersAndDisplays() async throws {
    // Mid grey and pure red, side by side.
    let url = try writePNG([128, 128, 128, 255, 0, 0], width: 2, height: 1)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try RGBImage(contentsOf: url)
    #expect(image.width == 2 && image.height == 1)
    // colour-science: sRGB decode, then sRGB → BT.2020 primaries.
    let expected: [Double] = [0.2158799901529247, 0.21585396096747733, 0.215848923573429,
                              0.6274413720579783, 0.0690276171470781, 0.016364235071680725]
    #expect(Difference(image.pixels, expected).maxAbsolute < 2e-4)

    let engine = try Engine()
    _ = await engine.open(image)
    let rendered = try await engine.render(controls: Controls(), mode: .full)
    #expect(rendered.width == 2 && rendered.height == 1)

    let display = try await engine.display(controls: Controls(), mode: .full)
    #expect(display.width == 2 && display.height == 1)
}

/// What the screen shows is the render, upright, in 8-bit sRGB (within a unit of rounding), and
/// scaled down to fit `maxPixels`.
@Test func displayShowsTheRender() async throws {
    let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
    let engine = try Engine()
    _ = await engine.open(image)
    let rendered = try await engine.render(controls: Controls(), mode: .full)
    let display = try await engine.display(controls: Controls(), mode: .full)
    #expect(display.width == image.width && display.height == image.height)
    let bytes = try #require(display.dataProvider?.data as Data?)
    func encoded(_ linear: Float) -> Int {
        let v = Double(min(max(linear, 0), 1))
        return Int(((v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255).rounded())
    }
    var worst = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            for channel in 0..<3 {
                let shown = Int(bytes[y * display.bytesPerRow + x * 4 + channel])
                worst = max(worst, abs(shown - encoded(rendered.pixels[(y * image.width + x) * 3 + channel])))
            }
        }
    }
    print("display vs render: max difference \(worst)/255")
    #expect(worst <= 1)

    let small = try await engine.display(controls: Controls(), mode: .full, maxPixels: 100)
    #expect(max(small.width, small.height) == 100)
}

/// The synthetic DNG `tools/golden.py` writes (camera RGB = linear sRGB): developed linearly, its
/// grey patches keep their raw values, which grey keeps in BT.2020 too. Then it renders.
@Test func rawDecodesLinearlyAndRenders() async throws {
    let image = try RGBImage(contentsOf: goldenDirectory.appending(components: "raw", "patches.dng"))
    #expect(image.width == 512 && image.height == 256)
    for (patch, raw) in [0.05, 0.1, 0.2, 0.4].enumerated() {
        let index = (128 * image.width + patch * 128 + 64) * 3
        let rgb = image.pixels[index..<(index + 3)].map(Double.init)
        print("raw \(raw): \(rgb)")
        #expect(rgb.allSatisfy { abs($0 / raw - 1) < 0.005 })
    }

    let engine = try Engine()
    _ = await engine.open(image)
    let rendered = try await engine.render(controls: Controls(), mode: .full)
    #expect(rendered.width == 512 && rendered.height == 256)
    let finite = rendered.pixels.allSatisfy { $0.isFinite }
    #expect(finite)
}

/// The preview's parameters are Python's `digest_params` with `preview_mode`, and its image is
/// down-sized to the app's preview size, 1600 px on the long side.
@Test func previewMatchesPython() async throws {
    var parameters = try GoldenCase("photo-kodak_portra_400-kodak_portra_endura").params
    parameters.applyPreviewMode()
    #expect(parameters == (try GoldenCase("preview-kodak_portra_400-kodak_portra_endura").params))

    let image = RGBImage(width: 3000, height: 2000, pixels: [Float](repeating: 0.18, count: 3000 * 2000 * 3))
    #expect(image.resized(maxPixels: 1600).pixels.allSatisfy { abs($0 - 0.18) < 1e-5 })
    let engine = try Engine()
    let preview = await engine.open(image)
    #expect(preview.width == 1600 && preview.height == 1067)
    var controls = Controls()
    controls.scanFilm = true
    let rendered = try await engine.render(controls: controls, mode: .preview)
    #expect(rendered.width == 1600 && rendered.height == 1067)
}

/// The app's export parameters for each golden photo case's film and paper, and its preview
/// parameters for the preview case, are Python's digested ones once the cases' own choices are
/// applied: sRGB input with its CCTF, encoded output (which export has already), and no grain or
/// glare (`deactivate_stochastic_effects`).
@Test(arguments: goldenCases.filter { !$0.hasPrefix("chart") })
func controlsDigestLikePython(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    var controls = Controls()
    controls.film = golden.film
    controls.paper = try golden.printProfile().info.stock
    controls.scanFilm = golden.params.io.scanFilm
    let preview = caseName.hasPrefix("preview")
    var parameters = Engine.parameters(for: controls, film: try Profile.load(golden.film), print: try golden.printProfile(),
                                       database: try Tables.loadNeutralPrintFilters(), mode: preview ? .preview : .export)
    parameters.io.inputColorSpace = "sRGB"
    parameters.io.inputCctfDecoding = true
    if preview {
        parameters.io.outputCctfEncoding = true
    }
    parameters.filmRender.grain.active = false
    parameters.printRender.glare.active = false
    #expect(parameters == golden.params)
}

/// The pickers' lists: Spektrafilm's `FilmStocks` and `PrintPapers`, and every film's target
/// print among the papers.
@Test func stockLists() throws {
    let engine = try Engine()
    #expect(engine.films.count == 20 && engine.papers.count == 8)
    let papers = Set(engine.papers.map(\.stock))
    #expect(engine.films.compactMap(\.targetPrint).allSatisfy(papers.contains))
}

/// A simulation reusing another's tables (``SimulationCache``) renders exactly what a fresh one does.
@Test func cachedSimulationMatchesFresh() throws {
    let golden = try GoldenCase("photo-kodak_portra_400-kodak_portra_endura")
    let (gpu, tables) = (try GPU(), try Tables.load())
    let (film, print) = (try Profile.load(golden.film), try golden.printProfile())
    let cache = SimulationCache()
    _ = try Simulation(parameters: golden.params, film: film, print: print, gpu: gpu, tables: tables, cache: cache)
    var parameters = golden.params
    parameters.camera.exposureCompensationEv = 1
    parameters.enlarger.yFilterShift = 10
    let cached = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables, cache: cache)
    let fresh = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables)
    let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
    let results = try [cached, fresh].map { simulation in gpu.download(try gpu.run { simulation.encode(image, on: $0) }) }
    #expect(results[0] == results[1])
}

/// A render from reserved memory, whose textures hold what the last render left there, is
/// exactly a render from fresh (zeroed) memory: every kernel writes its whole output. Grain and
/// glare on, so their kernels run too.
@Test(arguments: goldenCases)
func reservedMemoryRendersMatchFresh(caseName: String) throws {
    let golden = try GoldenCase(caseName)
    var parameters = golden.params
    parameters.filmRender.grain.active = true
    parameters.printRender.glare.active = true
    let (film, print, tables) = (try Profile.load(golden.film), try golden.printProfile(), try Tables.load())
    let image = try SpektraEngineTests.golden(caseName, "rgb_in").image
    func render(on gpu: GPU) throws -> [UInt32] {
        let simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables)
        return gpu.download(try gpu.run { simulation.encode(image, on: $0) }).map(\.bitPattern)
    }
    let fresh = try render(on: GPU())
    let gpu = try GPU()
    gpu.reserveMemory(width: image.width, height: image.height)
    _ = try render(on: gpu)
    #expect(try render(on: gpu) == fresh)
}

/// A render that starts from the last render's steps is exactly a render from scratch, through
/// a run of control changes in every mode. (Opening the photo again forgets the steps.)
@Test func cachedRendersMatchFresh() async throws {
    let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
    let (engine, fresh) = (try Engine(), try Engine())
    _ = await engine.open(image)
    var controls = Controls()
    let changes: [(String, (inout Controls) -> Void)] = [
        ("defaults", { _ in }), ("Y filter", { $0.yFilterShift = 12 }), ("print exposure", { $0.printExposure = 1.3 }),
        ("paper", { $0.paper = "fujifilm_crystal_archive_typeii" }), ("negative", { $0.scanFilm = true }),
        ("print", { $0.scanFilm = false }), ("exposure", { $0.exposureCompensationEV = 1.25 }),
        ("auto-exposure off", { $0.autoExposure = false }), ("grain off", { $0.grain = false }),
        ("halation off", { $0.halation = false }), ("film", { $0.film = "kodak_gold_200" }),
    ]
    for (name, change) in changes {
        change(&controls)
        for mode in [RenderMode.preview, .full, .export] {
            _ = await fresh.open(image)
            let expected = try await fresh.render(controls: controls, mode: mode).pixels.map(\.bitPattern)
            let cached = try await engine.render(controls: controls, mode: mode).pixels.map(\.bitPattern)
            #expect(cached == expected, "\(name), \(mode)")
        }
    }
}

/// The engine's render, in steps from the photo kept on the GPU, is exactly the parity-tested
/// chain from the image, grain and auto-exposure included.
@Test func engineRenderIsTheChain() async throws {
    let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
    var controls = Controls()
    controls.exposureCompensationEV = 0.75
    let engine = try Engine()
    _ = await engine.open(image)
    let rendered = try await engine.render(controls: controls, mode: .full)

    let (film, paper) = (try Profile.load(controls.film), try Profile.load(controls.paper))
    let parameters = Engine.parameters(for: controls, film: film, print: paper,
                                       database: try Tables.loadNeutralPrintFilters(), mode: .full)
    let gpu = try GPU()
    let simulation = try Simulation(parameters: parameters, film: film, print: paper, gpu: gpu, tables: try Tables.load())
    let chain = gpu.download(try gpu.run { simulation.encode(image, on: $0) })
    #expect(rendered.pixels.map(\.bitPattern) == chain.map(\.bitPattern))
}

/// Exported files carry 16 bits (TIFF, PNG) or 8 (JPEG), the sRGB profile and the photo's
/// metadata, and read back colour-managed as the colours written: a grey and a red block, sRGB
/// 0.5 and (1, 0, 0), against colour-science's linear BT.2020 for the stored integers.
@Test(arguments: [UTType.tiff, .png, .jpeg])
func exportWritesProfileAndMetadata(type: UTType) throws {
    let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // A photo with metadata, sideways.
    let photo = directory.appending(component: "photo.jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    let pixel = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    CGImageDestinationAddImage(destination, pixel, [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:05:15 12:00:00",
                                         kCGImagePropertyExifFNumber: 2.8],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test", kCGImagePropertyTIFFModel: "Camera"],
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let metadata = try #require(PhotoMetadata(contentsOf: photo))

    let (width, height) = (32, 16)
    var pixels = [Float](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let rgb: [Float] = x < 16 ? [0.5, 0.5, 0.5] : [1, 0, 0]
            pixels.replaceSubrange((y * width + x) * 3..<((y * width + x) * 3 + 3), with: rgb)
        }
    }
    let exported = directory.appending(component: "out").appendingPathExtension(for: type)
    try RGBImage(width: width, height: height, pixels: pixels)
        .write(to: exported, as: type, colorSpace: Engine.exportColorSpace, metadata: metadata)

    let source = try #require(CGImageSourceCreateWithURL(exported as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyDepth] as? Int == (type == .jpeg ? 8 : 16))
    #expect(properties[kCGImagePropertyProfileName] as? String == "sRGB IEC61966-2.1")
    #expect(properties[kCGImagePropertyOrientation] as? Int == 1)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:05:15 12:00:00")
    #expect(exif?[kCGImagePropertyExifFNumber] as? Double == 2.8)
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "Camera")
    if type == .tiff {
        #expect(tiff?[kCGImagePropertyTIFFCompression] as? Int == 8)
    }

    // The stored integers (truncated), decoded by colour-science's formulas into linear BT.2020.
    let tables = try Tables.load()
    let (sRGB, bt2020) = (tables.colourSpaces["sRGB"]!, tables.colourSpaces["ITU-R BT.2020"]!)
    let maximum = type == .jpeg ? 255.0 : 65535.0
    func expected(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
        let stored = (encoded * maximum).rounded(.down) / maximum
        let linear = SIMD3(sRGB.decode(stored.x), sRGB.decode(stored.y), sRGB.decode(stored.z))
        return simd_double3x3(rows: bt2020.xyzToRGB) * simd_double3x3(rows: sRGB.rgbToXYZ) * linear
    }
    let decoded = try RGBImage(contentsOf: exported)
    #expect(decoded.width == width && decoded.height == height)
    for (x, encoded) in [(8, SIMD3<Double>(0.5, 0.5, 0.5)), (24, SIMD3<Double>(1, 0, 0))] {
        let index = (8 * width + x) * 3
        let read = SIMD3(Double(decoded.pixels[index]), Double(decoded.pixels[index + 1]), Double(decoded.pixels[index + 2]))
        let error = abs(read - expected(encoded)).max()
        print("\(type.preferredFilenameExtension!) \(encoded): read \(read), error \(error)")
        // JPEG: lossy, and its chroma is subsampled.
        #expect(error < (type == .jpeg ? 0.02 : 2e-4))
    }
}

/// A cancelled render stops encoding kernels and throws.
@Test func renderStopsWhenCancelled() async throws {
    let engine = try Engine()
    _ = await engine.open(RGBImage(width: 2000, height: 2000, pixels: [Float](repeating: 0.18, count: 2000 * 2000 * 3)))
    let render = Task { try await engine.render(controls: Controls(), mode: .full) }
    render.cancel()
    await #expect(throws: CancellationError.self) { try await render.value }
}

/// A preset written and read back is the same controls; its JSON names them plainly.
@Test func presetRoundTrip() throws {
    var controls = Controls()
    controls.film = "kodak_vision3_500t"
    controls.paper = "kodak_2383"
    controls.scanFilm = true
    controls.autoExposure = false
    controls.exposureCompensationEV = -0.75
    controls.printExposure = 1.24
    controls.yFilterShift = -7
    controls.mFilterShift = 12
    controls.grain = false
    controls.halation = false
    let preset = try controls.preset()
    #expect(try Controls(preset: preset) == controls)
    let text = try #require(String(data: preset, encoding: .utf8))
    #expect(text.contains("\"film\" : \"kodak_vision3_500t\""))
    #expect(throws: DecodingError.self) { try Controls(preset: Data("{\"film\": 1}".utf8)) }
}
