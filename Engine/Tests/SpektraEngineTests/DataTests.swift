import Foundation
import Testing
@testable import SpektraEngine

@Test func allProfilesLoad() throws {
    let stocks = try Profile.stocks()
    #expect(stocks.count == 28)
    for stock in stocks {
        let profile = try Profile.load(stock)
        let data = profile.data
        #expect(profile.info.stock == stock)
        #expect(data.wavelengths.count == 81)
        #expect(data.logSensitivity.count == 81 && data.channelDensity.count == 81)
        #expect(data.baseDensity.count == 81)
        #expect(data.logExposure.count == 256 && data.densityCurves.count == 256)
        #expect(data.densityCurvesLayers.count == 256 && data.densityCurvesLayers.allSatisfy { $0.count == 3 })
        #expect(data.densityCurvesModel.centers.count == 3)
        if profile.info.stage == .filming {
            #expect(data.hanatos2025AdaptationWindowParams.count == 4)
            #expect(data.hanatos2025AdaptationSurfaceParams.count == 3)
        }
    }
}

@Test func portra400MatchesPython() throws {
    let data = try Profile.load("kodak_portra_400").data
    #expect(data.logSensitivity[40] == SIMD3(-0.9824191972671685, -1.0024959892315966, -4.379553426017711))
    #expect(data.densityCurves[128] == SIMD3(0.9538226804904694, 0.9572861189865028, 1.174331579376008))
    #expect(data.baseDensity[60] == 0.21508437938098854)
    #expect(data.densityCurvesLayers[200][1] == SIMD3(0.6910055968536973, 0.6175314338154064, 0.7473892501569543))
    #expect(data.hanatos2025AdaptationSurfaceParams[2][14] == -4.1162382406373439)
    #expect(data.densityCurvesModel.sigmas[0] == [0.4451180833109703, 0.5320397440430884, 0.526493691170658])
    // Python counts 22 NaNs in channel_density and 20 in base_density.
    let channelDensityValues = data.channelDensity.flatMap { [$0.x, $0.y, $0.z] }
    #expect(channelDensityValues.filter(\.isNaN).count == 22)
    #expect(data.baseDensity.filter(\.isNaN).count == 20)
}

@Test func tablesMatchPython() throws {
    let tables = try Tables.load()
    #expect(tables.spektrafilmVersion == SpektraEngine.referenceVersion)
    #expect(tables.wavelengths.count == 81 && tables.wavelengths.first == 380 && tables.wavelengths.last == 780)
    #expect(tables.cmfs[35] == SIMD3(0.5120500999999994, 1.0000000000000004, 0.005749999000000004))
    #expect(tables.illuminants["TH-KG3"]?[40] == 1.4771790396751106)
    #expect(tables.illuminants["K75P"]?[10] == 1.217982861892341)
    #expect(tables.dichroicFilters[30] == SIMD3(1.0, 5.686362830603642e-08, 0.9505199229902971))
    #expect(tables.colourSpaces["ProPhoto RGB"]?.rgbToXYZ[0] == SIMD3(0.7977, 0.1352, 0.0313))
    #expect(tables.colourSpaces.count == 7 && tables.chromaticAdaptation.count == 3)

    let filters = try Tables.loadNeutralPrintFilters()
    #expect(filters["kodak_2383"]?["TH-KG3"]?["kodak_vision3_500t"] == SIMD3(0.0, 44.613539160437185, 56.764119641390934))
}

@Test func spectraLUTLoads() throws {
    let lut = try Tables.loadSpectraLUT()
    #expect(lut.shape == [192, 192, 81])
    #expect(lut.values[(100 * 192 + 50) * 81 + 40] == 0.15576171875)
    #expect(lut.values[(191 * 192 + 0) * 81 + 80] == 8.881092071533203e-06)
}

@Test func goldenFloat32Loads() throws {
    let array = try golden("chart-kodak_portra_400-kodak_portra_endura", "rgb_out")
    #expect(array.shape == [256, 384, 3])
    #expect(array.values[(200 * 384 + 300) * 3 + 2] == 0.4720475971698761)
}
