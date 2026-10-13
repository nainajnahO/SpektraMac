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
    public var autoExposure = true
    public var exposureCompensationEV = 0.0
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
    private let displayContext = RGBImage.makeContext()
    /// The last render's simulation, rebuilt when a render needs other parameters or profiles.
    private var simulation: Simulation?
    /// The photo renders work on (``open(_:)``).
    private var photo: Photo?
    /// The live preview's long side. Larger than Spektrafilm's `preview_max_size` (640), which is
    /// soft on a Retina display: about 0.1 s per change on an M1 Pro, preview mode and display.
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

    /// One image of the photo with the auto-exposure Spektrafilm measures on it, and what the
    /// last render of it left to start from: the film's log exposure and the developed film.
    /// Renders only read these textures.
    private struct PhotoImage {
        let texture: any MTLTexture
        let autoExposureEV: Double
        var exposure: Step?
        var film: Step?
    }

    /// A step's result and what it was made from: the film and the parameters it reads.
    private struct Step {
        struct Key: Equatable {
            let film: String
            let parameters: Parameters
        }
        let key: Key
        let texture: any MTLTexture
    }

    /// Makes `image` the photo renders work on: uploads it and its preview (at most
    /// ``previewMaxSize`` on the long side) once, measures their auto-exposure once, and sets
    /// aside the GPU memory renders of its size need. Returns the preview's size.
    public func open(_ image: RGBImage) -> (width: Int, height: Int) {
        let preview = image.resized(maxPixels: previewMaxSize)
        // Auto-exposure is measured the same way in every mode (input space, no CCTF decoding).
        let space = tables.colourSpaces[Self.inputColorSpace]!
        func upload(_ image: RGBImage) -> PhotoImage {
            PhotoImage(texture: gpu.upload(rgb: image.pixels, width: image.width, height: image.height),
                       autoExposureEV: autoExposureEV(of: image, colourSpace: space, cctfDecoding: false))
        }
        photo = nil  // frees the previous photo before reserving memory for this one
        gpu.reserveMemory(width: image.width, height: image.height)
        photo = Photo(full: upload(image), preview: upload(preview))
        return (preview.width, preview.height)
    }

    /// The simulation of the open photo as `controls` set it: the scanned print, or the developed
    /// film itself. Throws `CancellationError` when the task is cancelled.
    public func render(controls: Controls, mode: RenderMode) throws -> RGBImage {
        let output = try renderTexture(controls: controls, mode: mode)
        return RGBImage(width: output.width, height: output.height, pixels: gpu.download(output))
    }

    /// ``render(controls:mode:)`` for the screen: 8-bit sRGB, no larger than `maxPixels` on its
    /// long side (Core Animation can't texture images over 16384 px). Core Image scales it down
    /// on the GPU, so only that comes back from it.
    public func display(controls: Controls, mode: RenderMode, maxPixels: Int = 4096) throws -> CGImage {
        let output = try renderTexture(controls: controls, mode: mode)
        // Core Image puts a texture's first row at the bottom.
        guard let image = CIImage(mtlTexture: output, options: [.colorSpace: Self.outputColorSpace]) else {
            throw DisplayError()
        }
        let scaled = RGBImage.scaledDown(image.oriented(.downMirrored), maxPixels: maxPixels)
        guard let display = displayContext.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw DisplayError()
        }
        return display
    }

    public struct DisplayError: Error, CustomStringConvertible {
        public var description: String { "Core Image couldn't draw the render" }
    }

    /// Renders from the first step `controls` change since the last render of the same image: a
    /// new paper, enlarger setting or Film | Negative choice prints and scans the developed film
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
        let image: WritableKeyPath<Photo, PhotoImage> = mode == .preview ? \.preview : \.full

        // What's still valid of the last render; the rest is released before this one.
        let exposureKey = Step.Key(film: controls.film, parameters: Self.exposureParameters(parameters))
        let filmKey = Step.Key(film: controls.film, parameters: Self.filmParameters(parameters))
        if photo![keyPath: image].exposure?.key != exposureKey {
            photo![keyPath: image].exposure = nil
        }
        if photo![keyPath: image].film?.key != filmKey {
            photo![keyPath: image].film = nil
        }
        let last = photo![keyPath: image]
        let (logExposure, cmyFilm, output) = try gpu.run { encoder in
            let logExposure = last.exposure?.texture ?? simulation.encodeExpose(
                simulation.encodePreprocess(last.texture, autoExposureEV: last.autoExposureEV, on: encoder), on: encoder)
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
        parameters.camera.autoExposure = controls.autoExposure
        parameters.camera.exposureCompensationEv = controls.exposureCompensationEV
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
