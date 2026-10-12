import Foundation
import Metal

/// Spektrafilm's `SimulationPipeline`: the stages between the pipeline taps
/// (`rgb_in → rgb_pre → log_e_film → cmy_film → log_e_print → cmy_print → rgb_out`), encoded on
/// the GPU. Grows stage by stage as the port proceeds (PLAN.md).
public struct Simulation: Sendable {
    public let parameters: Parameters
    let gpu: GPU
    let tables: Tables
    let inputColourSpace: Tables.ColourSpace

    public struct UnknownColourSpace: Error, CustomStringConvertible {
        public let name: String
        public var description: String { "Unknown colour space \(name)" }
    }

    public init(parameters: Parameters, gpu: GPU, tables: Tables) throws {
        guard let inputColourSpace = tables.colourSpaces[parameters.io.inputColorSpace] else {
            throw UnknownColourSpace(name: parameters.io.inputColorSpace)
        }
        self.parameters = parameters
        self.gpu = gpu
        self.tables = tables
        self.inputColourSpace = inputColourSpace
    }

    /// `rgb_in → rgb_pre`: uploads the image and applies auto-exposure. (Python's preprocess
    /// also crops and upscales; both are off by default and not ported.)
    public func encodePreprocess(_ image: RGBImage, on encoder: any MTLComputeCommandEncoder) -> any MTLTexture {
        let input = gpu.upload(rgb: image.pixels, width: image.width, height: image.height)
        guard parameters.camera.autoExposure else { return input }
        let ev = autoExposureEV(of: image, colourSpace: inputColourSpace, cctfDecoding: parameters.io.inputCctfDecoding)
        let output = gpu.makeTexture(width: image.width, height: image.height)
        gpu.encodeScale(on: encoder, input: input, output: output, by: pow(2, ev))
        return output
    }
}
