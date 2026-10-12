import CoreGraphics
import Dispatch

/// Runs the simulation for the app. A render waits on the GPU, so the actor runs on its own serial
/// queue rather than blocking a thread of the cooperative pool (Scanjet's scanner-actor pattern).
public actor Engine {
    private nonisolated let queue = DispatchSerialQueue(label: "SpektraEngine.Engine")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let gpu: GPU
    private let simulation: Simulation

    /// The colour space ``render(_:)`` returns pixels in (linear sRGB, Spektrafilm's default output).
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public init() throws {
        gpu = try GPU()
        let film = try Profile.load("kodak_portra_400")
        let print = try Profile.load("kodak_portra_endura")
        var parameters = Parameters()
        parameters.io.inputColorSpace = "ITU-R BT.2020"  // RGBImage's working space, linear
        parameters.io.outputCctfEncoding = false  // linear out: the display is colour-managed
        parameters.applyNeutralPrintFilters(film: film, print: print, database: try Tables.loadNeutralPrintFilters())
        parameters.applyFilmSpecifics(film)
        simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: Tables.load())
    }

    /// The simulation of `image`, as far as it is ported (PLAN.md): the scanned print as linear RGB
    /// in ``outputColorSpace`` (no grain or glare yet).
    public func render(_ image: RGBImage) throws -> RGBImage {
        let output = try gpu.run { simulation.encode(image, on: $0) }
        return RGBImage(width: image.width, height: image.height, pixels: gpu.download(output))
    }
}
