import Foundation
import Metal
import simd

/// Spektrafilm's `SimulationPipeline`: the stages between the pipeline taps
/// (`rgb_in → rgb_pre → log_e_film → cmy_film → log_e_print → cmy_print → rgb_out`), encoded on
/// the GPU. Grows stage by stage as the port proceeds (PLAN.md).
/// Holds GPU resources (the film's LUT texture), so it is not Sendable: the Engine actor owns one.
public struct Simulation {
    public let parameters: Parameters
    public let film: Profile
    let gpu: GPU
    let tables: Tables
    let inputColourSpace: Tables.ColourSpace
    /// The film's tc LUT (192 × 192, texel (j, i) = entry (i, j)), built once per film and
    /// parameter set.
    let filmingLUT: any MTLTexture
    /// Input RGB (linear) → XYZ adapted to the film's reference white with CAT16.
    let inputToXYZ: simd_double3x3

    public struct UnknownColourSpace: Error, CustomStringConvertible {
        public let name: String
        public var description: String { "Unknown colour space \(name)" }
    }

    public init(parameters: Parameters, film: Profile, gpu: GPU, tables: Tables) throws {
        guard let inputColourSpace = tables.colourSpaces[parameters.io.inputColorSpace] else {
            throw UnknownColourSpace(name: parameters.io.inputColorSpace)
        }
        self.parameters = parameters
        self.film = film
        self.gpu = gpu
        self.tables = tables
        self.inputColourSpace = inputColourSpace

        let spectra = try Tables.loadSpectraLUT()
        let lut = filmingTCLUT(film: film, parameters: parameters, tables: tables, spectra: spectra)
        let size = spectra.shape[0]
        filmingLUT = gpu.upload(rgb: lut.flatMap { [Float($0.x), Float($0.y), Float($0.z)] }, width: size, height: size)

        let white = tables.chromaticity(of: tables.illuminants[film.info.referenceIlluminant]!)
        inputToXYZ = vonKries(from: inputColourSpace.whitepoint, to: white,
                              transform: tables.chromaticAdaptation["CAT16"]!)
            * simd_double3x3(rows: inputColourSpace.rgbToXYZ)
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

    /// `rgb_pre → log_e_film` (FilmingStage.expose): the film's raw exposure through the
    /// hanatos2025 tc LUT, × 2^exposure compensation, highlight boost, lens blur, scatter and
    /// halation, as log10.
    ///
    /// Not ported: the camera diffusion filter (off by default, backlog). The scanner's
    /// black/white correction factor is 1 unless those corrections are on (not ported yet; off by
    /// default).
    public func encodeExpose(_ rgb: any MTLTexture, on encoder: any MTLComputeCommandEncoder) -> any MTLTexture {
        let raw = gpu.makeTexture(width: rgb.width, height: rgb.height)
        let m = inputToXYZ
        var matrix = simd_float3x3(SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2))
        let transfers = ["linear": 0, "sRGB": 1, "gamma": 2, "BT.2020": 3, "ROMM RGB": 4]
        var transfer = UInt32(parameters.io.inputCctfDecoding ? transfers[inputColourSpace.cctf]! : 0)
        var gamma = Float(inputColourSpace.gamma ?? 1)
        var exposure = Float(pow(2, parameters.camera.exposureCompensationEv))
        gpu.encode("hanatos2025_raw", on: encoder, textures: [rgb, raw, filmingLUT], grid: raw.size) {
            $0.setBytes(&matrix, length: MemoryLayout<simd_float3x3>.size, index: 0)
            $0.setBytes(&transfer, length: 4, index: 1)
            $0.setBytes(&gamma, length: 4, index: 2)
            $0.setBytes(&exposure, length: 4, index: 3)
        }
        var light = raw
        let halation = parameters.filmRender.halation
        // ResizingService.pixel_size_um (no crop or upscale).
        let pixelSizeUm = parameters.camera.filmFormatMm * 1000 / Double(max(rgb.width, rgb.height))
        if halation.boostEv > 0 {
            light = gpu.encodeBoostHighlights(on: encoder, input: light, boostEv: halation.boostEv,
                                              boostRange: halation.boostRange, protectEv: halation.protectEv)
        }
        if parameters.camera.lensBlurUm > 0 {
            let blurred = gpu.makeTexture(width: rgb.width, height: rgb.height)
            gpu.encodeGaussianBlur(on: encoder, input: light, output: blurred,
                                   sigma: SIMD3(repeating: parameters.camera.lensBlurUm / pixelSizeUm))
            light = blurred
        }
        if halation.active {
            light = gpu.encodeHalation(on: encoder, input: light, halation: halation, pixelSizeUm: pixelSizeUm)
        }
        let logExposure = gpu.makeTexture(width: rgb.width, height: rgb.height)
        gpu.encodeLogExposure(on: encoder, input: light, output: logExposure)
        return logExposure
    }
}

/// colour-science's `matrix_chromatic_adaptation_VonKries` between two xy whites (Y = 1).
func vonKries(from source: SIMD2<Double>, to destination: SIMD2<Double>, transform rows: [SIMD3<Double>]) -> simd_double3x3 {
    func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> { SIMD3(xy.x / xy.y, 1, (1 - (xy.x + xy.y)) / xy.y) }
    let m = simd_double3x3(rows: rows)
    let gain = (m * xyz(destination)) / (m * xyz(source))
    return m.inverse * simd_double3x3(diagonal: gain) * m
}
