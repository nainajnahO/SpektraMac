import Accelerate
import CoreGraphics
import CoreImage
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

/// The tests that open a photo, run one at a time (`openingAPortraitFindsTheFace`, in
/// MeteringTests, is one too). Opening asks Vision for people, objects and faces in one call
/// (``MeteringRegions/init(finding:)``). Vision runs requests in a fixed number of slots shared by
/// the whole process, and person segmentation holds its slot while it waits for a second one for
/// the requests it builds on. With about a dozen photos opening at once, every slot is held by a
/// segmentation waiting for another, and Vision hangs for good, as these tests did in parallel.
/// The app can't get there: its one `Engine` opens one photo at a time.
@Suite(.serialized) struct PhotoOpeningTests {}

extension PhotoOpeningTests {
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
        _ = try await engine.open(RGBImage.decode(contentsOf: url))
        let rendered = try await engine.render(controls: Controls(), mode: .full)
        #expect(rendered.width == 2 && rendered.height == 1)

        let display = try await engine.display(controls: Controls(), mode: .full)
        #expect(display.width == 2 && display.height == 1)
    }
}

/// TIFFs, which reach Core Image through ImageIO, decode as Core Image reads them from the file,
/// upright: a 16-bit Adobe RGB one and an untagged 8-bit one, both turned by their EXIF
/// orientation (6: rotate 90° clockwise).
@Test(arguments: [(16, true), (8, false)])
func tiffDecodesAsCoreImageReadsIt(bits: Int, tagged: Bool) throws {
    let (width, height) = (3, 2)
    let values = (0..<(width * height * 3)).map { $0 * 3000 + 500 }
    let data = bits == 16 ? values.map { UInt16($0) }.withUnsafeBytes { Data($0) } : Data(values.map { UInt8($0 % 256) })
    let space = tagged ? CGColorSpace(name: CGColorSpace.adobeRGB1998)! : CGColorSpaceCreateDeviceRGB()
    let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: 3 * bits,
                        bytesPerRow: width * 3 * bits / 8, space: space,
                        bitmapInfo: bits == 16 ? .byteOrder16Little : [], provider: CGDataProvider(data: data as CFData)!,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = FileManager.default.temporaryDirectory.appending(component: "\(UUID()).tif")
    defer { try? FileManager.default.removeItem(at: url) }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try RGBImage(contentsOf: url)
    #expect(decoded.width == height && decoded.height == width)
    let reference = try #require(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
    var rgba = [Float](repeating: 0, count: width * height * 4)
    RGBImage.makeContext().render(reference, toBitmap: &rgba, rowBytes: height * 16, bounds: reference.extent,
                                  format: .RGBAf, colorSpace: RGBImage.workingColorSpace)
    let expected = (0..<(width * height)).flatMap { rgba[($0 * 4)..<($0 * 4 + 3)] }
    #expect(decoded.pixels.map(\.bitPattern) == expected.map(\.bitPattern))
}

extension PhotoOpeningTests {
    /// Opening renders the decoded photo straight onto the GPU: its renders, full, preview, reduced
    /// and thumbnail, are exactly the parity-tested chain on the photo decoded to an `RGBImage` and on
    /// that scaled down as the preview was made before (Core Image's Lanczos from the CPU copy), to the
    /// preview's size, a reduced render's and a thumbnail's. A Display P3 8-bit PNG and 16-bit TIFF
    /// larger than the preview, and the synthetic DNG.
    @Test(arguments: ["png", "tif", "dng"])
    func openRendersTheDecodedPhoto(format: String) async throws {
        let url: URL
        if format == "dng" {
            url = goldenDirectory.appending(components: "raw", "patches.dng")
        } else {
            // Gradients in red and green, a fine pattern in blue.
            let (width, height, bits) = (2400, 1600, format == "tif" ? 16 : 8)
            let values = (0..<(width * height)).flatMap { pixel in
                let (x, y) = (pixel % width, pixel / width)
                return [x * 65535 / width, y * 65535 / height, (x * 7 + y * 13) % 65536]
            }
            let data = bits == 16 ? values.map { UInt16($0) }.withUnsafeBytes { Data($0) } : Data(values.map { UInt8($0 >> 8) })
            let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: 3 * bits,
                                bytesPerRow: width * 3 * bits / 8, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: bits == 16 ? .byteOrder16Little : [],
                                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)!
            url = FileManager.default.temporaryDirectory.appending(component: "\(UUID()).\(format)")
            let type = format == "tif" ? UTType.tiff : .png
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        defer { if format != "dng" { try? FileManager.default.removeItem(at: url) } }

        let engine = try Engine()
        _ = try await engine.open(RGBImage.decode(contentsOf: url))
        let decoded = try RGBImage(contentsOf: url)
        func scaled(to maxPixels: Int) -> RGBImage {
            let scaled = RGBImage.scaledDown(decoded.ciImage, maxPixels: maxPixels)
            let (width, height) = (Int(scaled.extent.width), Int(scaled.extent.height))
            var rgba = [Float](repeating: 0, count: width * height * 4)
            RGBImage.makeContext().render(scaled, toBitmap: &rgba, rowBytes: width * 16, bounds: scaled.extent,
                                          format: .RGBAf, colorSpace: RGBImage.workingColorSpace)
            return RGBImage(width: width, height: height, pixels: (0..<(width * height)).flatMap { rgba[($0 * 4)..<($0 * 4 + 3)] })
        }

        let controls = Controls()
        let (film, paper) = (try Profile.load(controls.film), try Profile.load(controls.paper))
        let (gpu, tables, database) = (try GPU(), try Tables.load(), try Tables.loadNeutralPrintFilters())
        for (mode, image) in [(RenderMode.full, decoded), (.preview, scaled(to: 1600)), (.reduced(longSide: 1000), scaled(to: 1000)),
                              (.thumbnail, scaled(to: 256))] {
            let rendered = try await engine.render(controls: controls, mode: mode)
            let parameters = Engine.parameters(for: controls, film: film, print: paper, database: database, mode: mode)
            let simulation = try Simulation(parameters: parameters, film: film, print: paper, gpu: gpu, tables: tables)
            let chain = gpu.download(try gpu.run { simulation.encode(image, on: $0) })
            #expect(rendered.width == image.width && rendered.height == image.height, "\(mode)")
            #expect(rendered.pixels.map(\.bitPattern) == chain.map(\.bitPattern), "\(mode)")
        }
    }

    /// What the screen shows is the render, upright, in 8-bit sRGB (within a unit of rounding), and
    /// scaled down to fit `maxPixels`.
    @Test func displayShowsTheRender() async throws {
        let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
        let engine = try Engine()
        _ = try await engine.open(image.ciImage)
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
        _ = try await engine.open(RGBImage.decode(contentsOf: goldenDirectory.appending(components: "raw", "patches.dng")))
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
        let engine = try Engine()
        let opened = try await engine.open(image.ciImage)
        #expect(opened.width == 3000 && opened.height == 2000)
        #expect(opened.previewWidth == 1600 && opened.previewHeight == 1067)
        var controls = Controls()
        controls.scanFilm = true
        let rendered = try await engine.render(controls: controls, mode: .preview)
        #expect(rendered.width == 1600 && rendered.height == 1067)
    }
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
    let (camera, enlarger) = (golden.params.camera.diffusionFilter, golden.params.enlarger.diffusionFilter)
    (controls.cameraDiffusion, controls.cameraDiffusionFilter, controls.cameraDiffusionStrength,
     controls.cameraDiffusionSize, controls.cameraDiffusionWarmth) =
        (camera.active, camera.filterFamily, camera.strength, camera.spatialScale, camera.haloWarmth)
    (controls.enlargerDiffusion, controls.enlargerDiffusionFilter, controls.enlargerDiffusionStrength,
     controls.enlargerDiffusionSize, controls.enlargerDiffusionWarmth) =
        (enlarger.active, enlarger.filterFamily, enlarger.strength, enlarger.spatialScale, enlarger.haloWarmth)
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

/// The effect sliders set their Spektrafilm parameters (over the film's own halation preset and
/// coupler strengths, which stay), the burn and the film format their own, and nothing else; print
/// contrast turns the curve morph on.
@Test func effectControlsSetTheirParameters() throws {
    var controls = Controls()
    controls.filmFormatMm = 60
    controls.highlightBoost = 3
    controls.preflash = 0.02
    controls.printContrast = 0.8
    controls.printHighlightContrast = 0.7
    controls.printShadowContrast = 1.3
    controls.glare = false
    controls.glareAmount = 0.2
    controls.glareRoughness = 0.5
    controls.glareSoftness = 1.5
    controls.couplers = false
    controls.couplerSaturation = 1.4
    controls.couplerEdgeContrast = 0.6
    controls.halationAmount = 2
    controls.halationSize = 0.5
    controls.scatterAmount = 0.25
    controls.scatterSize = 1.5
    controls.grainSize = 0.4
    controls.grainSoftness = 0.9
    controls.burn = true
    controls.burnStops = 1.5
    controls.burnThreshold = 3
    let (film, paper, database) = (try Profile.load(controls.film), try Profile.load(controls.paper),
                                   try Tables.loadNeutralPrintFilters())
    var expected = Engine.parameters(for: Controls(), film: film, print: paper, database: database, mode: .full)
    expected.camera.filmFormatMm = 60
    expected.filmRender.halation.boostEv = 3
    expected.enlarger.preflashExposure = 0.02
    expected.printRender.densityCurvesMorph.active = true
    expected.printRender.densityCurvesMorph.gammaFactor = 0.8
    expected.printRender.densityCurvesMorph.gammaFactorFast = 0.7
    expected.printRender.densityCurvesMorph.gammaFactorSlow = 1.3
    expected.printRender.glare = Parameters.Glare(active: false, percent: 0.2, roughness: 0.5, blur: 1.5)
    expected.filmRender.dirCouplers.active = false
    expected.filmRender.dirCouplers.inhibitionInterlayer = 1.4
    expected.filmRender.dirCouplers.inhibitionSamelayer = 0.6
    expected.filmRender.halation.halationAmount = 2
    expected.filmRender.halation.halationSpatialScale = 0.5
    expected.filmRender.halation.scatterAmount = 0.25
    expected.filmRender.halation.scatterSpatialScale = 1.5
    expected.filmRender.grain.particleAreaUm2 = 0.4
    expected.filmRender.grain.blur = 0.9
    expected.enlarger.burn = Parameters.Burn(stops: 1.5, threshold: 3)
    #expect(Engine.parameters(for: controls, film: film, print: paper, database: database, mode: .full) == expected)

    // Any of the paper's contrasts away from 1 turns the morph on.
    for contrast in [\Controls.printContrast, \.printHighlightContrast, \.printShadowContrast] {
        var controls = Controls()
        controls[keyPath: contrast] = 1.1
        #expect(Engine.parameters(for: controls, film: film, print: paper, database: database, mode: .full)
            .printRender.densityCurvesMorph.active)
    }
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
    gpu.heap = gpu.reservedMemory(width: image.width, height: image.height)
    _ = try render(on: gpu)
    #expect(try render(on: gpu) == fresh)
}

extension PhotoOpeningTests {
    /// A render that starts from the last render's steps is exactly a render from scratch, through
    /// a run of control changes in every mode. (Opening the photo again forgets the steps.)
    @Test func cachedRendersMatchFresh() async throws {
        let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
        let (engine, fresh) = (try Engine(), try Engine())
        _ = try await engine.open(image.ciImage)
        var controls = Controls()
        let changes: [(String, (inout Controls) -> Void)] = [
            ("defaults", { _ in }), ("Y filter", { $0.yFilterShift = 12 }), ("print exposure", { $0.printExposure = 1.3 }),
            ("paper", { $0.paper = "fujifilm_crystal_archive_typeii" }), ("negative", { $0.scanFilm = true }),
            ("print", { $0.scanFilm = false }), ("exposure", { $0.exposureOffsetEV = 1.25 }),
            ("as shot", { $0.exposureMark = .asShot }), ("faces", { $0.exposureMark = .faces }), ("grain off", { $0.grain = false }),
            ("halation off", { $0.halation = false }), ("burn", { $0.burn = true }),
            ("film", { $0.film = "kodak_gold_200" }),
        ]
        for (name, change) in changes {
            change(&controls)
            for mode in [RenderMode.preview, .reduced(longSide: 300), .full, .export] {
                _ = try await fresh.open(image.ciImage)
                let expected = try await fresh.render(controls: controls, mode: mode).pixels.map(\.bitPattern)
                let cached = try await engine.render(controls: controls, mode: mode).pixels.map(\.bitPattern)
                #expect(cached == expected, "\(name), \(mode)")
            }
        }
    }

    /// The engine's render, in steps from the photo kept on the GPU, is exactly the parity-tested
    /// chain from the image, grain and auto-exposure (the Centre-weighted mark) included.
    @Test func engineRenderIsTheChain() async throws {
        let image = try SpektraEngineTests.golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_in").image
        let controls = Controls()
        let engine = try Engine()
        _ = try await engine.open(image.ciImage)
        let rendered = try await engine.render(controls: controls, mode: .full)

        let (film, paper) = (try Profile.load(controls.film), try Profile.load(controls.paper))
        let parameters = Engine.parameters(for: controls, film: film, print: paper,
                                           database: try Tables.loadNeutralPrintFilters(), mode: .full)
        let gpu = try GPU()
        let simulation = try Simulation(parameters: parameters, film: film, print: paper, gpu: gpu, tables: try Tables.load())
        let chain = gpu.download(try gpu.run { simulation.encode(image, on: $0) })
        #expect(rendered.pixels.map(\.bitPattern) == chain.map(\.bitPattern))
    }
}

/// Exported files carry 16 bits (TIFF, PNG) or 8 (JPEG), the sRGB profile, the photo's metadata
/// and the edit's record, and read back colour-managed as the colours written: a grey and a red block, sRGB
/// 0.5 and (1, 0, 0), against colour-science's linear BT.2020 for the stored integers; and a NaN
/// pixel (outside the colour model) as black.
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
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["Holiday"]],
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
    pixels.replaceSubrange(0..<3, with: [.nan, .nan, .nan])
    let exported = directory.appending(component: "out").appendingPathExtension(for: type)
    var controls = Controls()
    controls.exposureOffsetEV = 0.3
    let record = EditRecord(software: "SpektraMac 1.2", summary: "Kodak Portra 400 printed on Kodak Portra Endura · +0.3 EV",
                            keywords: ["Kodak Portra 400", "SpektraMac"], controls: controls)
    let gpu = try GPU()
    try gpu.image(of: gpu.upload(rgb: pixels, width: width, height: height), bits: type == .jpeg ? 8 : 16,
                  colorSpace: Engine.exportColorSpace)
        .write(to: exported, as: type, metadata: metadata, record: record)

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
        #expect(tiff?[kCGImagePropertyTIFFCompression] as? Int == 1)
    }
    #expect(tiff?[kCGImagePropertyTIFFSoftware] as? String == record.software)
    #expect(tiff?[kCGImagePropertyTIFFImageDescription] as? String == record.summary)
    let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
    #expect(iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String == record.summary)
    #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["Holiday", "Kodak Portra 400", "SpektraMac"])
    let xmp = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    func setting(_ name: String) -> String? {
        CGImageMetadataCopyStringValueWithPath(xmp, nil, "\(EditRecord.prefix):\(name)" as CFString) as String?
    }
    #expect(setting("film") == "kodak_portra_400")
    #expect(setting("exposureOffsetEV") == "0.3")
    #expect(setting("grain") == "true")

    // The stored integers (rounded), decoded by colour-science's formulas into linear BT.2020.
    let tables = try Tables.load()
    let (sRGB, bt2020) = (tables.colourSpaces["sRGB"]!, tables.colourSpaces["ITU-R BT.2020"]!)
    let maximum = type == .jpeg ? 255.0 : 65535.0
    func expected(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
        let stored = (encoded * maximum).rounded(.toNearestOrAwayFromZero) / maximum
        let linear = SIMD3(sRGB.decode(stored.x), sRGB.decode(stored.y), sRGB.decode(stored.z))
        return simd_double3x3(rows: bt2020.xyzToRGB) * simd_double3x3(rows: sRGB.rgbToXYZ) * linear
    }
    let decoded = try RGBImage(contentsOf: exported)
    #expect(decoded.width == width && decoded.height == height)
    if type != .jpeg {
        #expect(decoded.pixels[0..<3] == [0, 0, 0])
    }
    for (x, encoded) in [(8, SIMD3<Double>(0.5, 0.5, 0.5)), (24, SIMD3<Double>(1, 0, 0))] {
        let index = (8 * width + x) * 3
        let read = SIMD3(Double(decoded.pixels[index]), Double(decoded.pixels[index + 1]), Double(decoded.pixels[index + 2]))
        let error = abs(read - expected(encoded)).max()
        print("\(type.preferredFilenameExtension!) \(encoded): read \(read), error \(error)")
        // JPEG: lossy, and its chroma is subsampled.
        #expect(error < (type == .jpeg ? 0.02 : 2e-4))
    }
}

/// Saved files store what they stored when saving converted the floats on the CPU, with vImage:
/// the GPU's integers are vImage's conversions, 16- and 8-bit, on values either side of every
/// rounding boundary, across [0, 1], and outside it (NaN, infinities, negatives, over 1).
@Test func savedIntegersAreVImagesConversion() throws {
    var values: [Float] = [.nan, -.nan, .infinity, -.infinity, -1, -0.0, 0, 1, 1.5, 1e30]
    for (levels, maximum) in [(65536, Float(65535)), (256, 255)] {
        for level in 0..<levels {
            let boundary = (Float(level) + 0.5) / maximum
            values += [boundary.nextDown.nextDown, boundary.nextDown, boundary, boundary.nextUp, boundary.nextUp.nextUp]
        }
    }
    values += (0...100_000).map { Float($0) / 100_000 }
    // A texture is at most 16384 wide: rows of 1024 pixels.
    let width = 1024
    let height = (values.count / 3 + width - 1) / width
    values += [Float](repeating: 0, count: width * height * 3 - values.count)
    let gpu = try GPU()
    let texture = gpu.upload(rgb: values, width: width, height: height)
    for bits in [16, 8] {
        let image = try gpu.image(of: texture, bits: bits, colorSpace: Engine.exportColorSpace)
        let stored = try #require(image.dataProvider?.data) as Data
        // As saving converted them: planar, so a row of interleaved RGB is width × 3 values.
        var converted = Data(count: values.count * bits / 8)
        values.withUnsafeBytes { source in
            converted.withUnsafeMutableBytes { destination in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                                           height: vImagePixelCount(height), width: vImagePixelCount(width * 3),
                                           rowBytes: width * 12)
                var destination = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width * 3), rowBytes: width * 3 * bits / 8)
                let flags = vImage_Flags(kvImageNoFlags)
                let error = bits == 16 ? vImageConvert_FTo16U(&source, &destination, 0, 1 / 65535, flags)
                                       : vImageConvert_PlanarFtoPlanar8(&source, &destination, 1, 0, flags)
                #expect(error == kvImageNoError)
            }
        }
        #expect(stored == converted, "\(bits)-bit")
    }
}

extension PhotoOpeningTests {
    /// A cancelled render stops encoding kernels and throws.
    @Test func renderStopsWhenCancelled() async throws {
        let engine = try Engine()
        _ = try await engine.open(RGBImage(width: 2000, height: 2000, pixels: [Float](repeating: 0.18, count: 2000 * 2000 * 3)).ciImage)
        let render = Task { try await engine.render(controls: Controls(), mode: .full) }
        render.cancel()
        await #expect(throws: CancellationError.self) { try await render.value }
    }
}

/// A preset written and read back is the same controls; its JSON names them plainly.
@Test func presetRoundTrip() throws {
    var controls = Controls()
    controls.film = "kodak_vision3_500t"
    controls.paper = "kodak_2383"
    controls.scanFilm = true
    controls.exposureMark = .people
    controls.exposureOffsetEV = -0.75
    controls.printExposure = 1.24
    controls.yFilterShift = -7
    controls.mFilterShift = 12
    controls.highlightBoost = 2
    controls.preflash = 0.01
    controls.printContrast = 1.2
    controls.printHighlightContrast = 0.8
    controls.printShadowContrast = 1.1
    controls.glare = false
    controls.glareAmount = 0.1
    controls.glareRoughness = 0.4
    controls.glareSoftness = 1
    controls.couplers = false
    controls.couplerSaturation = 1.3
    controls.couplerEdgeContrast = 0.7
    controls.halation = false
    controls.halationAmount = 1.5
    controls.halationSize = 0.8
    controls.scatterAmount = 0.5
    controls.scatterSize = 1.2
    controls.grain = false
    controls.grainSize = 0.4
    controls.grainSoftness = 0.8
    controls.burn = true
    controls.burnStops = 1.5
    controls.burnThreshold = 2
    let preset = try controls.preset()
    #expect(try Controls(preset: preset) == controls)
    let text = try #require(String(data: preset, encoding: .utf8))
    #expect(text.contains("\"film\" : \"kodak_vision3_500t\""))
    #expect(throws: DecodingError.self) { try Controls(preset: Data("{\"film\": 1}".utf8)) }
}

extension PhotoOpeningTests {
    /// A LUT entry is what a render of a photo of that one sRGB colour gives, exposed the same (the
    /// As shot mark plus the offset), when nothing that depends on other pixels is on: patches of
    /// lattice colours, black, white, grey and some in between, through the app's own path. Within a
    /// quarter of an 8-bit level (measured: 3.7e-4): the photo's render still runs its blurs, through
    /// half-float intermediates. Its `.cube` is the comments, the title, the size and the entries,
    /// red fastest.
    @Test func lutEntriesAreUniformRenders() async throws {
        let size = 5
        var controls = Controls()
        controls.exposureMark = .asShot
        controls.exposureOffsetEV = 0.7
        controls.grain = false
        controls.glare = false
        let engine = try Engine()
        let lut = try await engine.lut(controls: controls, exposureEV: controls.exposureOffsetEV, size: size)
        #expect(lut.values.count == size * size * size * 3)

        let colours: [SIMD3<Int>] = [[0, 0, 0], [4, 4, 4], [2, 2, 2], [4, 0, 0], [0, 4, 0], [0, 0, 4], [1, 3, 2], [3, 1, 4]]
        let patch = 32
        let width = patch * colours.count
        var rgba = [Float](repeating: 1, count: width * patch * 4)
        for y in 0..<patch {
            for x in 0..<width {
                let colour = SIMD3<Float>(colours[x / patch]) / Float(size - 1)
                (rgba[(y * width + x) * 4], rgba[(y * width + x) * 4 + 1], rgba[(y * width + x) * 4 + 2]) = (colour.x, colour.y, colour.z)
            }
        }
        let photo = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: patch), format: .RGBAf, colorSpace: Engine.exportColorSpace)
        _ = try await engine.open(photo)
        let rendered = try await engine.render(controls: controls, mode: .export)
        for (index, colour) in colours.enumerated() {
            let pixel = (patch / 2 * width + index * patch + patch / 2) * 3
            let entry = ((colour.z * size + colour.y) * size + colour.x) * 3
            let expected = (0..<3).map { min(max(rendered.pixels[pixel + $0], 0), 1) }
            #expect(Difference(Array(lut.values[entry..<(entry + 3)]), expected.map(Double.init)).maxAbsolute < 1e-3, "\(colour): \(lut.values[entry..<(entry + 3)]) vs \(expected)")
        }

        let lines = String(decoding: lut.cube(title: "Test \"LUT\"", comments: ["Film: Portra 400"]), as: UTF8.self)
            .split(separator: "\n")
        #expect(Array(lines.prefix(3)) == ["# Film: Portra 400", "TITLE \"Test 'LUT'\"", "LUT_3D_SIZE 5"])
        #expect(lines.count == 3 + size * size * size)
        #expect(lines[3] == Substring(String(format: "%.6f %.6f %.6f", lut.values[0], lut.values[1], lut.values[2])))
    }
}

extension PhotoOpeningTests {
    /// The tone graph of a photo of one grey, exposed `e` stops over mid-grey: its curve at `e` is
    /// the colour a render of the photo gives when nothing that depends on other pixels is on, and
    /// each layer's histogram is all in the bin of the curve's film exposure there. The print
    /// exposure adds its log₁₀ to the paper's exposure and the contrasts leave that alone, as the
    /// graph's handles take it.
    @Test func toneGraphIsTheRenderOfAGrey() async throws {
        let e: Float = 1
        var controls = Controls()
        controls.exposureOffsetEV = Double(e)
        controls.halation = false
        controls.grain = false
        controls.glare = false
        let (width, height) = (16, 16)
        let rgba = (0..<(width * height)).flatMap { _ in [Float](arrayLiteral: 0.5, 0.5, 0.5, 1) }
        let photo = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: Engine.exportColorSpace)
        let engine = try Engine()
        _ = try await engine.open(photo)
        let rendered = try await engine.render(controls: controls, mode: .export)
        let graph = try await engine.toneGraph(controls: controls)
        #expect(graph.curve.count == 256 && graph.histogram.count == 256)

        // `e` between two greys of the ramp.
        let position = (e - ToneGraph.stops.lowerBound) / (ToneGraph.stops.upperBound - ToneGraph.stops.lowerBound)
            * Float(graph.curve.count - 1)
        let (below, fraction) = (Int(position), position - position.rounded(.down))
        func atE(_ value: KeyPath<ToneGraph.Point, SIMD3<Float>>) -> SIMD3<Float> {
            graph.curve[below][keyPath: value] * (1 - fraction) + graph.curve[below + 1][keyPath: value] * fraction
        }
        let print = atE(\.print)
        let expected = (0..<3).map { min(max(Double(rendered.pixels[$0]), 0), 1) }
        #expect(Difference((0..<3).map { Double(print[$0]) }, expected).maxAbsolute < 2e-3, "\(print) vs \(expected)")

        let film = atE(\.film)
        #expect(abs(film.y - e) < 0.1)
        for channel in 0..<3 {
            let bin = Int((film[channel] - ToneGraph.stops.lowerBound) / 16 * 256)
            let full = graph.histogram.firstIndex { $0[channel] > 0 }
            #expect(graph.histogram.map { $0[channel] }.reduce(0, +) == 1)
            #expect(full.map { abs($0 - bin) <= 1 } == true, "channel \(channel): bin \(String(describing: full)), expected \(bin)")
        }

        controls.printExposure = 2
        let brighter = try await engine.toneGraph(controls: controls)
        controls.printContrast = 1.5
        let steeper = try await engine.toneGraph(controls: controls)
        for index in graph.curve.indices {
            let shift = brighter.curve[index].paper - graph.curve[index].paper
            #expect(abs(shift - log10(2)).max() < 1e-4)
            #expect(steeper.curve[index].paper == brighter.curve[index].paper)
        }
        #expect(steeper.curve[160].print.y > brighter.curve[160].print.y)  // 2 stops up: lighter
    }
}
