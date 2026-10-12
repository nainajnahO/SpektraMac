import CoreGraphics
import Dispatch
import Foundation

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
    /// Each change while editing: Spektrafilm's preview mode (no blurs or grain), on an image from
    /// ``Engine/preview(of:)``. Linear, in ``Engine/outputColorSpace``.
    case preview
    /// The whole photo with every effect. Linear, in ``Engine/outputColorSpace``.
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
    /// The last render's simulation, rebuilt when a render needs other parameters or profiles.
    private var simulation: Simulation?
    /// The live preview's long side. Larger than Spektrafilm's `preview_max_size` (640), which is
    /// soft on a Retina display: about 0.1 s per change on an M1 Pro, preview mode and display.
    private nonisolated let previewMaxSize = 1600

    /// The colour space of preview and full renders: linear sRGB, Spektrafilm's default output
    /// space, for the colour-managed display.
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    /// The colour space of export renders: sRGB with its transfer function.
    public static let exportColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

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

    /// `image` down-sized for previewing.
    public nonisolated func preview(of image: RGBImage) -> RGBImage {
        image.resized(maxPixels: previewMaxSize)
    }

    /// The simulation of `image` as `controls` set it: the scanned print, or the developed film
    /// itself. Throws `CancellationError` when the task is cancelled.
    public func render(_ image: RGBImage, controls: Controls, mode: RenderMode) throws -> RGBImage {
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
        let output = try gpu.run { simulation.encode(image, on: $0) }
        return RGBImage(width: image.width, height: image.height, pixels: gpu.download(output))
    }

    /// `controls` over Spektrafilm's defaults, in the app's colour spaces, digested as
    /// `digest_params` does it: neutral print filters, preview mode, then the film's specifics.
    static func parameters(for controls: Controls, film: Profile, print: Profile,
                           database: [String: [String: [String: SIMD3<Double>]]], mode: RenderMode) -> Parameters {
        var parameters = Parameters()
        parameters.io.inputColorSpace = "ITU-R BT.2020"  // RGBImage's working space, linear
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
