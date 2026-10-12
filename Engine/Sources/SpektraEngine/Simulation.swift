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
    /// The film's density curves shifted so each channel starts at 0 (FilmingStage.develop).
    let filmCurves: [SIMD3<Double>]
    /// The curves before DIR couplers act, such that development with couplers reproduces
    /// `filmCurves` on a uniform grey (`compute_density_curves_before_dir_couplers`).
    let filmCurvesBeforeCouplers: [SIMD3<Double>]

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

        let minimum = film.data.densityCurves.reduce(SIMD3(repeating: Double.infinity)) { pointwiseMin($0, $1) }
        filmCurves = film.data.densityCurves.map { $0 - minimum }
        filmCurvesBeforeCouplers = curvesBeforeCouplers(
            filmCurves, logExposure: film.data.logExposure,
            couplers: parameters.filmRender.dirCouplers.matrix, positive: film.info.type == .positive)

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

    /// `log_e_film → cmy_film` (FilmingStage.develop): log exposure → CMY dye density through the
    /// film's characteristic curves (normalised to start at 0, exposure axis ÷ density_curve_gamma),
    /// with DIR couplers: the silver formed releases inhibitors (matrix: donor layer → receiving
    /// layer) that diffuse (Gaussian + exponential tail) and lower each layer's effective exposure,
    /// which is then developed again on the pre-coupler curves.
    ///
    /// Not yet ported: grain (Days 26–28; off without stochastic effects).
    public func encodeDevelop(_ logExposure: any MTLTexture, on encoder: any MTLComputeCommandEncoder) -> any MTLTexture {
        let (width, height) = (logExposure.width, logExposure.height)
        let gamma = parameters.filmRender.densityCurveGamma
        let axis = film.data.logExposure.map { SIMD3(repeating: $0 / gamma) }
        let density = gpu.makeTexture(width: width, height: height)
        gpu.encodeInterpolate(on: encoder, input: logExposure, output: density, axis: axis, values: filmCurves)
        let couplers = parameters.filmRender.dirCouplers
        guard couplers.active else { return density }

        // Exposure correction Σ_k silver_k · M[k, m]: silver is the density for negatives and
        // d_max − density for positives (inhibitors act at silver development).
        // Rows of Mᵀ are M's columns (simd subscripts are columns).
        let matrix = couplers.matrix
        let rows = [matrix[0], matrix[1], matrix[2]]
        let correction = gpu.makeTexture(width: width, height: height)
        if film.info.type == .positive {
            let densityMax = filmCurves.reduce(SIMD3(repeating: -Double.infinity)) { pointwiseMax($0, $1) }
            gpu.encodeMatrix(on: encoder, input: density, output: correction, rows: rows.map { -$0 },
                             offset: matrix.transpose * densityMax)
        } else {
            gpu.encodeMatrix(on: encoder, input: density, output: correction, rows: rows)
        }

        var diffused = correction
        if couplers.diffusionSizeUm > 0 {
            let pixelSizeUm = parameters.camera.filmFormatMm * 1000 / Double(max(width, height))
            let (core, tail) = (gpu.makeTexture(width: width, height: height), gpu.makeTexture(width: width, height: height))
            gpu.encodeGaussianBlur(on: encoder, input: correction, output: core,
                                   sigma: SIMD3(repeating: couplers.diffusionSizeUm / pixelSizeUm))
            gpu.encodeExponentialBlur(on: encoder, input: correction, output: tail,
                                      decay: SIMD3(repeating: couplers.diffusionTailUm / pixelSizeUm))
            gpu.encodeScale(on: encoder, input: core, output: core, by: 1 - couplers.diffusionTailWeight)
            gpu.encodeAddScaled(on: encoder, accumulator: core, input: tail, output: core,
                                weight: SIMD3(repeating: couplers.diffusionTailWeight))
            diffused = core
        }
        let corrected = gpu.makeTexture(width: width, height: height)
        gpu.encodeAddScaled(on: encoder, accumulator: logExposure, input: diffused, output: corrected,
                            weight: SIMD3(repeating: -1))
        let developed = gpu.makeTexture(width: width, height: height)
        gpu.encodeInterpolate(on: encoder, input: corrected, output: developed, axis: axis, values: filmCurvesBeforeCouplers)
        return developed
    }
}

/// `compute_density_curves_before_dir_couplers`, f64: shifts each curve's exposure axis by the
/// inhibition a uniform grey of that density would cause, and resamples on the original axis.
func curvesBeforeCouplers(_ curves: [SIMD3<Double>], logExposure: [Double], couplers: simd_double3x3,
                          positive: Bool) -> [SIMD3<Double>] {
    let densityMax = curves.reduce(SIMD3(repeating: -Double.infinity)) { pointwiseMax($0, $1) }
    // silver · M, row vector times matrix.
    let shifted = zip(curves, logExposure).map { density, exposure in
        SIMD3(repeating: exposure) - (positive ? densityMax - density : density) * couplers
    }
    var corrected = curves
    for channel in 0..<3 {
        let xp = shifted.map { $0[channel] }
        let fp = curves.map { positive ? -$0[channel] : $0[channel] }
        for (index, exposure) in logExposure.enumerated() {
            let value = interp(exposure, xp, fp)
            corrected[index][channel] = positive ? -value : value
        }
    }
    return corrected
}

/// colour-science's `matrix_chromatic_adaptation_VonKries` between two xy whites (Y = 1).
func vonKries(from source: SIMD2<Double>, to destination: SIMD2<Double>, transform rows: [SIMD3<Double>]) -> simd_double3x3 {
    func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> { SIMD3(xy.x / xy.y, 1, (1 - (xy.x + xy.y)) / xy.y) }
    let m = simd_double3x3(rows: rows)
    let gain = (m * xyz(destination)) / (m * xyz(source))
    return m.inverse * simd_double3x3(diagonal: gain) * m
}
