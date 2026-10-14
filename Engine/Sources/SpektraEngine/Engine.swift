import CoreGraphics
import CoreImage
import Dispatch
import Foundation
import Metal

/// What the app's controls set (PLAN.md, Day 31). Everything else stays at Spektrafilm's defaults
/// for the film and paper. A preset is these values as JSON.
public struct Controls: Codable, Sendable, Equatable {
    /// Stock names (`profiles/<stock>.json`).
    public var film = "kodak_portra_400"
    public var paper = "kodak_portra_endura"
    /// Scan the developed film itself instead of a print of it (`io.scan_film`).
    public var scanFilm = false
    /// The exposure: `exposureMark`'s reading for the photo (``MeteringReadings``) plus
    /// `exposureOffsetEV` stops. A new photo opens at the same mark's own reading.
    public var exposureMark = MeteringMark.centreWeighted
    public var exposureOffsetEV = 0.0
    /// The enlarger's exposure time, relative to the one that prints a mid-grey neutral.
    public var printExposure = 1.0
    /// Enlarger filters, in Kodak CC units away from the film and paper's neutral ones.
    public var yFilterShift = 0.0
    public var mFilterShift = 0.0
    public var grain = true
    public var halation = true

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

/// What a render is for.
public enum RenderMode: Sendable {
    /// Each change while editing: Spektrafilm's preview mode (no blurs or grain), on the open
    /// photo's preview. Linear, in ``Engine/outputColorSpace``.
    case preview
    /// The open photo's preview with every effect: the finished look, at the preview's size.
    /// Linear, in ``Engine/outputColorSpace``.
    case reduced
    /// The whole open photo with every effect. Linear, in ``Engine/outputColorSpace``.
    case full
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
    /// The preview's long side, for the live preview and reduced renders. Larger than
    /// Spektrafilm's `preview_max_size` (640), which is soft on a Retina display: about 0.1 s per
    /// change on an M1 Pro, preview mode and display.
    private nonisolated let previewMaxSize = 1600

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
    }

    /// The open photo on the GPU, at full size and as its preview.
    private struct Photo {
        var full: PhotoImage
        var preview: PhotoImage
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
    /// image is metered once at every mark, in place. Sets aside the GPU memory renders of its
    /// size need.
    public func open(_ image: CIImage) throws -> OpenedPhoto {
        let extent = image.extent.integral
        let (width, height) = (Int(extent.width), Int(extent.height))
        photo = nil  // frees the previous photo before reserving memory for this one
        gpu.reserveMemory(width: width, height: height)
        let full = gpu.makeReadableTexture(width: width, height: height)
        try render(image, from: extent, into: full)
        var preview = full
        if max(width, height) > previewMaxSize {
            // Core Image puts a texture's first row at the bottom.
            let source = CIImage(mtlTexture: full, options: [.colorSpace: RGBImage.workingColorSpace])!
            let scaled = RGBImage.scaledDown(source.oriented(.downMirrored), maxPixels: previewMaxSize)
            preview = gpu.makeReadableTexture(width: Int(scaled.extent.width), height: Int(scaled.extent.height))
            try render(scaled, from: scaled.extent, into: preview)
        }
        // Auto-exposure is metered the same way in every mode (input space, no CCTF decoding).
        let space = tables.colourSpaces[Self.inputColorSpace]!
        let previewLuminance = meteredLuminance(of: Pixels(preview), colourSpace: space, cctfDecoding: false)
        let centreWeighted = MeteringReadings(luminance: previewLuminance.y, width: previewLuminance.width,
                                              height: previewLuminance.height, regions: nil).reading(resolving: .centreWeighted)
        let regions = try MeteringRegions(finding: visionView(of: preview, exposure: centreWeighted.ev))
        let previewImage = PhotoImage(texture: preview, metering: MeteringReadings(
            luminance: previewLuminance.y, width: previewLuminance.width, height: previewLuminance.height, regions: regions))
        var fullImage = previewImage
        if full !== preview {
            let luminance = meteredLuminance(of: Pixels(full), colourSpace: space, cctfDecoding: false)
            fullImage = PhotoImage(texture: full, metering: MeteringReadings(
                luminance: luminance.y, width: luminance.width, height: luminance.height, regions: regions))
        }
        photo = Photo(full: fullImage, preview: previewImage)
        return OpenedPhoto(width: width, height: height, previewWidth: preview.width, previewHeight: preview.height,
                           metering: previewImage.metering,
                           meteringOverlays: regions.overlays(for: previewImage.metering, width: width, height: height))
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
        let image: WritableKeyPath<Photo, PhotoImage> = mode == .preview || mode == .reduced ? \.preview : \.full

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
        parameters.filmRender.grain.active = controls.grain
        parameters.filmRender.halation.active = controls.halation
        parameters.applyNeutralPrintFilters(film: film, print: print, database: database)
        if mode == .preview {
            parameters.applyPreviewMode()
        }
        parameters.applyFilmSpecifics(film)
        return parameters
    }
}
