import Dispatch

/// Runs the simulation for the app. A render waits on the GPU, so the actor runs on its own serial
/// queue rather than blocking a thread of the cooperative pool (Scanjet's scanner-actor pattern).
public actor Engine {
    private nonisolated let queue = DispatchSerialQueue(label: "SpektraEngine.Engine")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let gpu: GPU
    private let simulation: Simulation

    public init() throws {
        gpu = try GPU()
        let film = try Profile.load("kodak_portra_400")
        let print = try Profile.load("kodak_portra_endura")
        var parameters = Parameters()
        parameters.io.inputColorSpace = "ITU-R BT.2020"  // RGBImage's working space, linear
        parameters.applyNeutralPrintFilters(film: film, print: print, database: try Tables.loadNeutralPrintFilters())
        parameters.applyFilmSpecifics(film)
        simulation = try Simulation(parameters: parameters, film: film, print: print, gpu: gpu, tables: Tables.load())
    }

    /// The simulation of `image`, as far as it is ported (PLAN.md): today the developed negative,
    /// shown as each dye layer's transmittance 10^−density in the working space. A rough view —
    /// the spectral scan of the negative comes with the scanning stage.
    public func render(_ image: RGBImage) throws -> RGBImage {
        let output = try gpu.run { encoder in
            let density = simulation.encodeDevelop(
                simulation.encodeExpose(simulation.encodePreprocess(image, on: encoder), on: encoder), on: encoder)
            gpu.encodeScale(on: encoder, input: density, output: density, by: -1)
            gpu.encodeExp10(on: encoder, input: density, output: density)
            return density
        }
        return RGBImage(width: image.width, height: image.height, pixels: gpu.download(output))
    }
}
