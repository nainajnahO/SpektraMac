import CoreGraphics
import Dispatch

/// Runs the simulation for the app. A render waits on the GPU, so the actor runs on its own serial
/// queue rather than blocking a thread of the cooperative pool (Scanjet's scanner-actor pattern).
public actor Engine {
    private nonisolated let queue = DispatchSerialQueue(label: "SpektraEngine.Engine")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let gpu: GPU
    private let tables: Tables
    private let film: Profile
    private let print: Profile
    /// Spektrafilm's defaults digested for the film and paper, in the app's colour spaces.
    private let defaults: Parameters
    /// Rebuilt when a render needs other parameters (its tables depend on them).
    private var simulation: Simulation

    /// The colour space ``render(_:scanFilm:preview:)`` returns pixels in (linear sRGB,
    /// Spektrafilm's default output).
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public init() throws {
        gpu = try GPU()
        tables = try Tables.load()
        film = try Profile.load("kodak_portra_400")
        print = try Profile.load("kodak_portra_endura")
        var parameters = Parameters()
        parameters.io.inputColorSpace = "ITU-R BT.2020"  // RGBImage's working space, linear
        parameters.io.outputCctfEncoding = false  // linear out: the display is colour-managed
        parameters.applyNeutralPrintFilters(film: film, print: print, database: try Tables.loadNeutralPrintFilters())
        parameters.applyFilmSpecifics(film)
        defaults = parameters
        simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables)
    }

    /// `image` down-sized for previewing (Spektrafilm's `preview_max_size`).
    public nonisolated func preview(of image: RGBImage) -> RGBImage {
        image.resized(maxPixels: defaults.settings.previewMaxSize)
    }

    /// The simulation of `image`: the scanned print, or with `scanFilm` the developed film itself,
    /// as linear RGB in ``outputColorSpace``. `preview` runs Spektrafilm's preview mode (no blurs
    /// or grain), meant for an image from ``preview(of:)``.
    public func render(_ image: RGBImage, scanFilm: Bool, preview: Bool) throws -> RGBImage {
        var parameters = defaults
        parameters.io.scanFilm = scanFilm
        if preview {
            parameters.applyPreviewMode()
        }
        if parameters != simulation.parameters {
            simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: tables)
        }
        let output = try gpu.run { simulation.encode(image, on: $0) }
        return RGBImage(width: image.width, height: image.height, pixels: gpu.download(output))
    }
}
