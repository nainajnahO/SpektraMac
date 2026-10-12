import Metal

public enum SpektraEngine {
    /// The Spektrafilm release this port is verified against (golden data comes from it).
    public static let referenceVersion = "0.3.4"

    /// The GPU every stage runs on; `nil` only on Macs without Metal.
    public static var device: (any MTLDevice)? { MTLCreateSystemDefaultDevice() }
}
