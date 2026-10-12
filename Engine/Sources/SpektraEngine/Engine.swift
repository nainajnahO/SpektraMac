import Dispatch

/// Runs the simulation for the app. A render waits on the GPU, so the actor runs on its own serial
/// queue rather than blocking a thread of the cooperative pool (Scanjet's scanner-actor pattern).
public actor Engine {
    private nonisolated let queue = DispatchSerialQueue(label: "SpektraEngine.Engine")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let gpu: GPU

    public init() throws {
        gpu = try GPU()
    }

    /// The simulation of `image`. For now a pass-through on the GPU; stages are added as they
    /// are ported (PLAN.md).
    public func render(_ image: RGBImage) -> RGBImage {
        let texture = gpu.upload(rgb: image.pixels, width: image.width, height: image.height)
        return RGBImage(width: image.width, height: image.height, pixels: gpu.download(texture))
    }
}
