import CoreGraphics
import CoreImage
import Dispatch
import Foundation
import Metal
import UniformTypeIdentifiers

/// What the app's controls set (PLAN.md, Day 31). Everything else stays at Spektrafilm's defaults
/// for the film and paper. A preset is these values as JSON.
public struct Controls: Codable, Sendable, Hashable {
    /// Stock names (`profiles/<stock>.json`).
    public var film = "kodak_portra_400"
    public var paper = "kodak_portra_endura"
    /// Scan the developed film itself instead of a print of it (`io.scan_film`).
    public var scanFilm = false
    /// The exposure: `exposureMark`'s reading for the photo (``MeteringReadings``) plus
    /// `exposureOffsetEV` stops. A new photo opens at the same mark's own reading.
    public var exposureMark = MeteringMark.centreWeighted
    public var exposureOffsetEV = 0.0
    /// Stops the brightest highlights are raised by before they reach the film, rebuilding light
    /// the camera clipped (0 is off).
    public var highlightBoost = 0.0
    /// The enlarger's exposure time, relative to the one that prints a mid-grey neutral.
    public var printExposure = 1.0
    /// Enlarger filters, in Kodak CC units away from the film and paper's neutral ones.
    public var yFilterShift = 0.0
    public var mFilterShift = 0.0
    /// A flash of the bare enlarger light on the paper before the print, as a fraction of the
    /// clear film base's exposure: it darkens light tones more than white or the shadows.
    public var preflash = 0.0
    /// Burning in a sky, as a darkroom printer does: extra enlarger exposure at the print's top
    /// edge, in stops, fading linearly to none `burnReach` percent of the height down.
    public var burn = false
    public var burnStops = 1.0
    public var burnReach = 40.0
    /// The paper's contrast, as a multiplier of its curves' gamma around mid-grey; and of its
    /// light tones' alone (its fastest sub-layer's) and its dark tones' (the others').
    public var printContrast = 1.0
    public var printHighlightContrast = 1.0
    public var printShadowContrast = 1.0
    /// Stray light over the print when it's viewed: its mean in percent of the light, its spread
    /// relative to that, and its blur in pixels.
    public var glare = true
    public var glareAmount = 0.03
    public var glareRoughness = 0.7
    public var glareSoftness = 0.5
    public var halation = true
    /// Multipliers over the film's halation preset (Spektrafilm's high-level halation scalars):
    /// the glow from light bouncing off the film base, and light spreading inside the emulsion
    /// (the scatter amount blends towards the scattered light, so 1 is all of it).
    public var halationAmount = 1.0
    public var halationSize = 1.0
    public var scatterAmount = 1.0
    public var scatterSize = 1.0
    /// The DIR couplers' inhibition between layers (saturation) and within each (edge
    /// contrast), as multipliers of the film's own.
    public var couplers = true
    public var couplerSaturation = 1.0
    public var couplerEdgeContrast = 1.0
    public var grain = true
    /// Area of one silver halide particle in µm², and the grain's final blur in pixels.
    public var grainSize = 0.2
    public var grainSoftness = 0.65
    /// A diffusion filter on the camera's lens (Pro-Mist and the like): its family, its strength in
    /// the stops filters are sold in, its glow's size as a multiplier of the family's, and warmth
    /// added to the family's halo warmth.
    public var cameraDiffusion = false
    public var cameraDiffusionFilter = Parameters.DiffusionFilter.Family.blackProMist
    public var cameraDiffusionStrength = 0.5
    public var cameraDiffusionSize = 1.0
    public var cameraDiffusionWarmth = 0.0
    /// The same on the enlarger's lens, over the print.
    public var enlargerDiffusion = false
    public var enlargerDiffusionFilter = Parameters.DiffusionFilter.Family.blackProMist
    public var enlargerDiffusionStrength = 0.5
    public var enlargerDiffusionSize = 1.0
    public var enlargerDiffusionWarmth = 0.0

    public init() {}

    /// Reads a preset.
    public init(preset: Data) throws {
        self = try JSONDecoder().decode(Controls.self, from: preset)
    }

    /// The controls as a preset: JSON, readable and with sorted keys so presets diff cleanly.
    public func preset() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// A 3D colour lookup table: `size`³ RGB outputs for inputs evenly spaced over [0, 1], red
/// changing fastest, then green, then blue.
public struct LUT: Sendable {
    public let size: Int
    public let values: [Float]

    /// The table as a `.cube` file (Adobe's Cube LUT specification 1.0), titled `title`: the name
    /// apps such as LightCraft show for it. `comments` go first, as `#` lines.
    public func cube(title: String, comments: [String] = []) -> Data {
        var text = comments.map { "# \($0)\n" }.joined()
        text += "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\n"
        text += "LUT_3D_SIZE \(size)\n"
        for index in stride(from: 0, to: values.count, by: 3) {
            text += String(format: "%.6f %.6f %.6f\n", values[index], values[index + 1], values[index + 2])
        }
        return Data(text.utf8)
    }
}

/// What a render is for.
public enum RenderMode: Sendable, Equatable {
    /// Each change while editing: Spektrafilm's preview mode (no blurs or grain), on the open
    /// photo's preview. Linear, in ``Engine/outputColorSpace``.
    case preview
    /// The open photo with every effect, scaled to `longSide` pixels on its long side: the
    /// finished look at the size the screen shows it (the whole photo, as `full`, if that's no
    /// smaller). Linear, in ``Engine/outputColorSpace``.
    case reduced(longSide: Int)
    /// The whole open photo with every effect. Linear, in ``Engine/outputColorSpace``.
    case full
    /// As `preview`, on an image of the open photo at most 256 px on its long side: the frames of
    /// the app's thumbnail strips.
    case thumbnail
    /// As `full`, encoded for a file in ``Engine/exportColorSpace`` (Spektrafilm's default output).
    case export
}

/// Runs the simulation for the app. A render waits on the GPU, so the actor runs on its own serial
/// queue rather than blocking a thread of the cooperative pool (Scanjet's scanner-actor pattern).
public actor Engine {
    private nonisolated let queue = DispatchSerialQueue(label: "SpektraEngine.Engine")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The films (`stage` filming) and papers (`stage` printing) to choose from, by name.
    public nonisolated let films: [ProfileInfo]
    public nonisolated let papers: [ProfileInfo]

    private let gpu: GPU
    private let tables: Tables
    private let profiles: [String: Profile]
    private let neutralPrintFilters: [String: [String: [String: SIMD3<Double>]]]
    private let cache = SimulationCache()
    /// Core Image on the GPU's queue: it renders opened photos into their textures and renders
    /// to the screen.
    private let context: CIContext
    /// The last render's simulation, rebuilt when a render needs other parameters or profiles.
    private var simulation: Simulation?
    /// The photo renders work on (``open(_:)``).
    private var photo: Photo?
    /// GPU memory set aside for renders' intermediates (``GPU/reservedMemory(width:height:keeping:)``),
    /// which each render makes them from. For renders the size of the preview, the thumbnail or the
    /// screen: kept for every photo, the largest so far (0.5 GB at 1600 px), as new memory for each
    /// photo cost the first render after opening 150 ms more.
    private var screenMemory: (any MTLHeap)?
    /// For renders of the whole photo, where that's larger than its preview: set aside by the first
    /// (its pages become resident as that starts: 2 GB at 12 MP) and kept for the next zoom or save,
    /// until another photo opens or memory runs low (``releaseFullSizeMemory()``).
    private var fullSizeMemory: (any MTLHeap)?
    /// Says when memory runs low.
    private let memoryPressure: any DispatchSourceMemoryPressure
    /// The live preview's long side. Larger than Spektrafilm's `preview_max_size` (640), which is
    /// soft on a Retina display: about 20 ms per change on an M1 Pro, preview mode and display.
    private nonisolated let previewMaxSize = 1600
    /// The long side of the image thumbnails render from.
    private nonisolated let thumbnailMaxSize = 256

    /// The colour space of preview and full renders: linear sRGB, Spektrafilm's default output
    /// space, for the colour-managed display.
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    /// The colour space of export renders: sRGB with its transfer function.
    public static let exportColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The input colour space: RGBImage's working space, linear.
    static let inputColorSpace = "ITU-R BT.2020"

    public init() throws {
        gpu = try GPU()
        context = RGBImage.makeContext(commandQueue: gpu.queue)
        tables = try Tables.load()
        neutralPrintFilters = try Tables.loadNeutralPrintFilters()
        let profiles = try Profile.stocks().map(Profile.load)
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.info.stock, $0) })
        let infos = profiles.map(\.info).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        films = infos.filter { $0.stage == .filming }
        papers = infos.filter { $0.stage == .printing }
        let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        self.memoryPressure = memoryPressure
        memoryPressure.setEventHandler { [weak self] in
            Task { await self?.releaseFullSizeMemory() }
        }
        memoryPressure.activate()
    }

    /// Lets the memory set aside for renders of the whole photo go, with the steps kept from the
    /// last one, whose textures hold it. The next such render sets it aside again.
    private func releaseFullSizeMemory() {
        if gpu.heap === fullSizeMemory {
            gpu.heap = nil
        }
        fullSizeMemory = nil
        photo?.full.exposure = nil
        photo?.full.film = nil
    }

    /// The open photo on the GPU, at full size, as its preview and as its thumbnail.
    private struct Photo {
        var full: PhotoImage
        var preview: PhotoImage
        /// Made for the first thumbnail render rather than as the photo opens: the strips render
        /// once the photo is on screen.
        var thumbnail: PhotoImage?
        /// The last `reduced` render's image of the photo.
        var reduced: PhotoImage
        /// What Vision found in the photo, for metering the images made later.
        let regions: MeteringRegions
    }

    /// One image of the photo with the exposure each metering mark gives it (Spektrafilm meters
    /// each image on its own preview), and what the last render of it left to start from: the
    /// film's log exposure and the developed film. Renders only read these textures.
    private struct PhotoImage {
        let texture: any MTLTexture
        let metering: MeteringReadings
        var exposure: Step?
        var film: Step?
    }

    /// A step's result and what it was made from: the film, the parameters it reads and the
    /// exposure (a mark's reading for the photo plus an offset, so not a parameter).
    private struct Step {
        struct Key: Equatable {
            let film: String
            let parameters: Parameters
            let exposureEV: Double
        }
        let key: Key
        let texture: any MTLTexture
    }

    /// What ``open(_:)`` found out about a photo.
    public struct OpenedPhoto: Sendable {
        public let width: Int
        public let height: Int
        public let previewWidth: Int
        public let previewHeight: Int
        /// The preview's metering readings, as the controls show them.
        public let metering: MeteringReadings
        /// Each mark's region, for the canvas to tint (``MeteringRegions/overlays(for:width:height:maxSize:)``).
        public let meteringOverlays: [MeteringMark: CGImage]
    }

    /// Makes `image` (``RGBImage/decode(contentsOf:)``) the photo renders work on: Core Image
    /// renders it once into a texture, and its preview (at most ``previewMaxSize`` on the long side)
    /// from that on the GPU. Vision looks for the metering marks' regions in the preview, and each
    /// image is metered once at every mark, in place.
    public func open(_ image: CIImage) throws -> OpenedPhoto {
        let extent = image.extent.integral
        let (width, height) = (Int(extent.width), Int(extent.height))
        // The previous photo goes, and the memory set aside for renders of all of it.
        photo = nil
        releaseFullSizeMemory()
        let full = gpu.makeReadableTexture(width: width, height: height)
        try render(image, from: extent, into: full)
        let preview = try scaled(full, toLongSide: previewMaxSize)
        // Auto-exposure is metered the same way in every mode (input space, no CCTF decoding).
        let space = tables.colourSpaces[Self.inputColorSpace]!
        let previewLuminance = meteredLuminance(of: Pixels(preview), colourSpace: space, cctfDecoding: false)
        let centreWeighted = MeteringReadings(luminance: previewLuminance.y, width: previewLuminance.width,
                                              height: previewLuminance.height, regions: nil).reading(resolving: .centreWeighted)
        // The full image's luminance (about 40 ms at 12 MP, on the CPU) while Vision looks at the
        // preview: it needs no regions.
        nonisolated(unsafe) let fullPixels = Pixels(full)
        nonisolated(unsafe) var fullLuminance: (y: [Double], width: Int, height: Int)?
        let metering = DispatchGroup()
        if full !== preview {
            DispatchQueue.global(qos: .userInitiated).async(group: metering) {
                fullLuminance = meteredLuminance(of: fullPixels, colourSpace: space, cctfDecoding: false)
            }
        }
        let found = Result { try MeteringRegions(finding: visionView(of: preview, exposure: centreWeighted.ev)) }
        metering.wait()  // even if Vision failed: the metering reads `full`
        let regions = try found.get()
        let previewImage = PhotoImage(texture: preview, metering: MeteringReadings(
            luminance: previewLuminance.y, width: previewLuminance.width, height: previewLuminance.height, regions: regions))
        let fullImage = fullLuminance.map { luminance in
            PhotoImage(texture: full, metering: MeteringReadings(luminance: luminance.y, width: luminance.width,
                                                                 height: luminance.height, regions: regions))
        } ?? previewImage
        photo = Photo(full: fullImage, preview: previewImage, reduced: previewImage, regions: regions)
        return OpenedPhoto(width: width, height: height, previewWidth: preview.width, previewHeight: preview.height,
                           metering: previewImage.metering,
                           meteringOverlays: regions.overlays(for: previewImage.metering, width: width, height: height))
    }

    /// Loads the models Vision looks for the metering marks' regions with (about 0.2 s on an M1
    /// Pro), which the first ``open(_:)`` would otherwise wait for: call it at launch.
    public func loadVision() throws {
        try MeteringRegions.loadModels()
    }

    /// `full` scaled down to `longSide` pixels on its long side as Spektrafilm's preview is made
    /// (Lanczos), or `full` itself if it's no larger.
    private func scaled(_ full: any MTLTexture, toLongSide longSide: Int) throws -> any MTLTexture {
        guard max(full.width, full.height) > longSide else { return full }
        // Core Image puts a texture's first row at the bottom.
        let source = CIImage(mtlTexture: full, options: [.colorSpace: RGBImage.workingColorSpace])!
        let scaled = RGBImage.scaledDown(source.oriented(.downMirrored), maxPixels: longSide)
        let texture = gpu.makeReadableTexture(width: Int(scaled.extent.width), height: Int(scaled.extent.height))
        try render(scaled, from: scaled.extent, into: texture)
        return texture
    }

    /// `texture` as an image of the open photo, metered at every mark (in the input space, no
    /// CCTF decoding, as in every mode).
    private func metered(_ texture: any MTLTexture, regions: MeteringRegions) -> PhotoImage {
        let luminance = meteredLuminance(of: Pixels(texture), colourSpace: tables.colourSpaces[Self.inputColorSpace]!,
                                         cctfDecoding: false)
        return PhotoImage(texture: texture, metering: MeteringReadings(
            luminance: luminance.y, width: luminance.width, height: luminance.height, regions: regions))
    }

    /// What Vision looks at: `preview` exposed by Spektrafilm's meter, so a dim scene is readable, as 8-bit
    /// sRGB at most 1024 px on the long side.
    private func visionView(of preview: any MTLTexture, exposure: Double) throws -> CGImage {
        let scale = min(1, 1024 / Double(max(preview.width, preview.height)))
        // Core Image puts a texture's first row at the bottom.
        let view = CIImage(mtlTexture: preview, options: [.colorSpace: RGBImage.workingColorSpace])!
            .oriented(.downMirrored)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(view, from: view.extent.integral, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw DisplayError()
        }
        return image
    }

    /// Renders `region` of `image` into `texture`, top row first, in the working colour space.
    private func render(_ image: CIImage, from region: CGRect, into texture: any MTLTexture) throws {
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = RGBImage.workingColorSpace
        destination.isFlipped = true
        try context.startTask(toRender: image, from: region, to: destination, at: .zero).waitUntilCompleted()
    }

    /// The simulation of the open photo as `controls` set it: the scanned print, or the developed
    /// film itself. Throws `CancellationError` when the task is cancelled.
    public func render(controls: Controls, mode: RenderMode) throws -> RGBImage {
        let output = try renderTexture(controls: controls, mode: mode)
        return RGBImage(width: output.width, height: output.height, pixels: gpu.download(output))
    }

    /// The photo rendered for a file of `type` (``RenderMode/export``) as the file stores it: 16
    /// bits per channel for TIFF and PNG, 8 for JPEG, in ``exportColorSpace``
    /// (``GPU/image(of:bits:colorSpace:)``). Throws `CancellationError` when the task is cancelled.
    public func export(controls: Controls, as type: UTType) throws -> CGImage {
        try gpu.image(of: renderTexture(controls: controls, mode: .export), bits: type.conforms(to: .jpeg) ? 8 : 16,
                      colorSpace: Self.exportColorSpace)
    }

    /// ``render(controls:mode:)`` for the screen: 8-bit sRGB, no larger than `maxPixels` on its
    /// long side. By default that's the most Core Animation can texture, 16384 px, so the canvas
    /// zooms into the render's own pixels. Core Image scales larger ones down on the GPU, so only
    /// that comes back from it.
    public func display(controls: Controls, mode: RenderMode, maxPixels: Int = 16384) throws -> CGImage {
        let output = try renderTexture(controls: controls, mode: mode)
        // Core Image puts a texture's first row at the bottom.
        guard let image = CIImage(mtlTexture: output, options: [.colorSpace: Self.outputColorSpace]) else {
            throw DisplayError()
        }
        let scaled = RGBImage.scaledDown(image.oriented(.downMirrored), maxPixels: maxPixels)
        guard let display = context.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw DisplayError()
        }
        return display
    }

    public struct DisplayError: Error, CustomStringConvertible {
        public var description: String { "Core Image couldn't draw the render" }
    }

    /// Renders from the first step `controls` change since the last render of the same image: a
    /// new paper, enlarger setting or Print | Film choice prints and scans the developed film
    /// again; switching grain develops the film's exposure again; the rest starts over. The same
    /// kernels run as for a render from scratch, so the result is the same.
    private func renderTexture(controls: Controls, mode: RenderMode) throws -> any MTLTexture {
        guard photo != nil else { preconditionFailure("Rendering before a photo is open") }
        let film = profiles[controls.film]!, print = profiles[controls.paper]!
        let parameters = Self.parameters(for: controls, film: film, print: print, database: neutralPrintFilters,
                                         mode: mode)
        let simulation: Simulation
        if let current = self.simulation, current.parameters == parameters,
           current.film.info.stock == film.info.stock, current.print.info.stock == print.info.stock {
            simulation = current
        } else {
            simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables,
                                        cache: cache)
            self.simulation = simulation
        }
        let image: WritableKeyPath<Photo, PhotoImage>
        switch mode {
        case .preview:
            image = \.preview
        case .thumbnail:
            if photo!.thumbnail == nil {
                let full = photo!.full
                let thumbnail = try scaled(full.texture, toLongSide: thumbnailMaxSize)
                photo!.thumbnail = thumbnail === full.texture ? full : metered(thumbnail, regions: photo!.regions)
            }
            image = \.thumbnail!
        case .reduced(let longSide):
            let full = photo!.full.texture
            if longSide >= max(full.width, full.height) {
                image = \.full
            } else {
                let last = photo!.reduced.texture
                if max(last.width, last.height) != longSide {
                    photo!.reduced = metered(try scaled(full, toLongSide: longSide), regions: photo!.regions)
                }
                image = \.reduced
            }
        case .full, .export:
            image = \.full
        }

        // Intermediates from the memory set aside for renders of this size.
        let source = photo![keyPath: image].texture
        if image == \Photo.full && source !== photo!.preview.texture {
            fullSizeMemory = gpu.reservedMemory(width: source.width, height: source.height, keeping: fullSizeMemory)
            gpu.heap = fullSizeMemory
        } else {
            // A render's textures and room for the steps kept of the preview, the screen-size image
            // and the thumbnail: with fewer, some of a slider step's textures are allocated fresh
            // (30 ms a step instead of 24 at 12 MP with ten, 26 with 14).
            screenMemory = gpu.reservedMemory(width: source.width, height: source.height,
                                              textures: GPU.reservedTextures + 6, keeping: screenMemory)
            gpu.heap = screenMemory
        }

        let exposureEV = photo![keyPath: image].metering.reading(resolving: controls.exposureMark).ev
            + controls.exposureOffsetEV

        // What's still valid of the last render; the rest is released before this one.
        let exposureKey = Step.Key(film: controls.film, parameters: Self.exposureParameters(parameters),
                                   exposureEV: exposureEV)
        let filmKey = Step.Key(film: controls.film, parameters: Self.filmParameters(parameters), exposureEV: exposureEV)
        if photo![keyPath: image].exposure?.key != exposureKey {
            photo![keyPath: image].exposure = nil
        }
        if photo![keyPath: image].film?.key != filmKey {
            photo![keyPath: image].film = nil
        }
        let last = photo![keyPath: image]
        let (logExposure, cmyFilm, output) = try gpu.run { encoder in
            let logExposure = last.exposure?.texture ?? simulation.encodeExpose(
                simulation.encodePreprocess(last.texture, autoExposureEV: exposureEV, on: encoder), on: encoder)
            let cmyFilm = last.film?.texture ?? simulation.encodeDevelop(logExposure, on: encoder)
            return (logExposure, cmyFilm, simulation.encodePrintAndScan(cmyFilm, on: encoder))
        }
        photo![keyPath: image].exposure = Step(key: exposureKey, texture: logExposure)
        photo![keyPath: image].film = Step(key: filmKey, texture: cmyFilm)
        return output
    }

    /// A `size`³ 3D LUT of `controls`' look, for an app that applies one to display-encoded sRGB
    /// (LightCraft does, after its own edits): each sRGB colour of the lattice opened as a photo is
    /// (Core Image decodes it into the working space), exposed `exposureEV` stops over itself and
    /// rendered as an export. What depends on other pixels is left out
    /// (``Parameters/applyPerPixelMode()``). Doesn't touch the open photo. At most 128: the lattice
    /// renders as an image size² wide, and a texture is at most 16384.
    public func lut(controls: Controls, exposureEV: Double, size: Int) throws -> LUT {
        precondition((2...128).contains(size))
        let film = profiles[controls.film]!, print = profiles[controls.paper]!
        var parameters = Self.parameters(for: controls, film: film, print: print, database: neutralPrintFilters,
                                         mode: .export)
        parameters.applyPerPixelMode()
        let simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables,
                                        cache: cache)
        // The lattice in LUT order, a row per blue level: red changes fastest, then green.
        let axis = (0..<size).map { Float($0) / Float(size - 1) }
        var rgba = [Float]()
        rgba.reserveCapacity(size * size * size * 4)
        for blue in axis {
            for green in axis {
                for red in axis {
                    rgba += [red, green, blue, 1]
                }
            }
        }
        let lattice = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: size * size * 16,
                              size: CGSize(width: size * size, height: size), format: .RGBAf,
                              colorSpace: Self.exportColorSpace)
        let input = gpu.makeReadableTexture(width: size * size, height: size)
        try render(lattice, from: lattice.extent, into: input)
        let output = try gpu.run { encoder in
            let exposed = simulation.encodePreprocess(input, autoExposureEV: exposureEV, on: encoder)
            return simulation.encodePrintAndScan(simulation.encodeDevelop(simulation.encodeExpose(exposed, on: encoder),
                                                                          on: encoder), on: encoder)
        }
        // A colour outside the colour model (NaN) is black, as in a saved photo.
        return LUT(size: size, values: gpu.download(output).map { $0.isNaN ? 0 : min(max($0, 0), 1) })
    }

    /// What the developed film depends on: every parameter but the printing and scanning ones.
    /// (Leaving out what's known not to matter, rather than picking what does, keeps a parameter
    /// ported later from being missed.)
    private static func filmParameters(_ parameters: Parameters) -> Parameters {
        var key = parameters
        let defaults = Parameters()
        key.enlarger = defaults.enlarger
        key.printRender = defaults.printRender
        key.scanner = defaults.scanner
        key.io.outputColorSpace = defaults.io.outputColorSpace
        key.io.outputCctfEncoding = defaults.io.outputCctfEncoding
        key.io.outputGamutCompress = defaults.io.outputGamutCompress
        key.io.scanFilm = defaults.io.scanFilm
        return key
    }

    /// What the film's log exposure depends on: the developed film's parameters but those of its
    /// development.
    private static func exposureParameters(_ parameters: Parameters) -> Parameters {
        var key = filmParameters(parameters)
        let defaults = Parameters()
        key.filmRender.densityCurveGamma = defaults.filmRender.densityCurveGamma
        key.filmRender.dirCouplers = defaults.filmRender.dirCouplers
        key.filmRender.grain = defaults.filmRender.grain
        return key
    }

    /// `controls` over Spektrafilm's defaults, in the app's colour spaces, digested as
    /// `digest_params` does it: neutral print filters, preview mode, then the film's specifics.
    static func parameters(for controls: Controls, film: Profile, print: Profile,
                           database: [String: [String: [String: SIMD3<Double>]]], mode: RenderMode) -> Parameters {
        var parameters = Parameters()
        parameters.io.inputColorSpace = inputColorSpace
        parameters.io.outputCctfEncoding = mode == .export  // the display is colour-managed: linear
        parameters.io.scanFilm = controls.scanFilm
        parameters.enlarger.printExposure = controls.printExposure
        parameters.enlarger.yFilterShift = controls.yFilterShift
        parameters.enlarger.mFilterShift = controls.mFilterShift
        parameters.enlarger.preflashExposure = controls.preflash
        parameters.enlarger.burn = controls.burn
            ? Parameters.Burn(stops: controls.burnStops, reach: controls.burnReach / 100) : nil
        // Off at 1: Python's default, which the morph at 1 renders identically.
        parameters.printRender.densityCurvesMorph.active = controls.printContrast != 1
            || controls.printHighlightContrast != 1 || controls.printShadowContrast != 1
        parameters.printRender.densityCurvesMorph.gammaFactor = controls.printContrast
        parameters.printRender.densityCurvesMorph.gammaFactorFast = controls.printHighlightContrast
        parameters.printRender.densityCurvesMorph.gammaFactorSlow = controls.printShadowContrast
        parameters.printRender.glare.active = controls.glare
        parameters.printRender.glare.percent = controls.glareAmount
        parameters.printRender.glare.roughness = controls.glareRoughness
        parameters.printRender.glare.blur = controls.glareSoftness
        parameters.filmRender.halation.boostEv = controls.highlightBoost
        parameters.filmRender.halation.active = controls.halation
        parameters.filmRender.halation.halationAmount = controls.halationAmount
        parameters.filmRender.halation.halationSpatialScale = controls.halationSize
        parameters.filmRender.halation.scatterAmount = controls.scatterAmount
        parameters.filmRender.halation.scatterSpatialScale = controls.scatterSize
        parameters.filmRender.dirCouplers.active = controls.couplers
        parameters.filmRender.dirCouplers.inhibitionInterlayer = controls.couplerSaturation
        parameters.filmRender.dirCouplers.inhibitionSamelayer = controls.couplerEdgeContrast
        parameters.filmRender.grain.active = controls.grain
        parameters.filmRender.grain.particleAreaUm2 = controls.grainSize
        parameters.filmRender.grain.blur = controls.grainSoftness
        parameters.camera.diffusionFilter = Parameters.DiffusionFilter(
            active: controls.cameraDiffusion, filterFamily: controls.cameraDiffusionFilter,
            strength: controls.cameraDiffusionStrength, spatialScale: controls.cameraDiffusionSize,
            haloWarmth: controls.cameraDiffusionWarmth)
        parameters.enlarger.diffusionFilter = Parameters.DiffusionFilter(
            active: controls.enlargerDiffusion, filterFamily: controls.enlargerDiffusionFilter,
            strength: controls.enlargerDiffusionStrength, spatialScale: controls.enlargerDiffusionSize,
            haloWarmth: controls.enlargerDiffusionWarmth)
        parameters.applyNeutralPrintFilters(film: film, print: print, database: database)
        if mode == .preview || mode == .thumbnail {
            parameters.applyPreviewMode()
        }
        parameters.applyFilmSpecifics(film)
        return parameters
    }
}
