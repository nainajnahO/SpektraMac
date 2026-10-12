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
        var parameters = Parameters()
        parameters.io.inputColorSpace = "ITU-R BT.2020"  // RGBImage's working space, linear
        simulation = try Simulation(parameters: parameters, gpu: gpu, tables: Tables.load())
    }

    /// The simulation of `image`, as far as it is ported (PLAN.md): today the auto-exposed input.
    public func render(_ image: RGBImage) throws -> RGBImage {
        let output = try gpu.run { simulation.encodePreprocess(image, on: $0) }
        return RGBImage(width: image.width, height: image.height, pixels: gpu.download(output))
    }
}
