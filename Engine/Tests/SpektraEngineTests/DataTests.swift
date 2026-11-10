import Foundation
import Testing
@testable import SpektraEngine

@Test func allProfilesLoad() throws {
    let stocks = try Profile.stocks()
    #expect(stocks.count == 31)
    var blackAndWhite: [String] = []
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
        switch profile.info.channelModel {
        case .colour:
            #expect(data.developments.isEmpty)
            if profile.info.stage == .filming {
                #expect(data.hanatos2025AdaptationWindowParams.count == 4)
                #expect(data.hanatos2025AdaptationSurfaceParams.count == 3)
            }
        case .blackAndWhite:
            blackAndWhite.append(stock)
            #expect(data.hanatos2025AdaptationWindowParams.isEmpty && data.hanatos2025AdaptationSurfaceParams.isEmpty)
            #expect(data.developments.map(\.minutes) == data.developments.map(\.minutes).sorted())
            // What the rest of the engine relies on (``Profile``): one layer in three identical
            // channels, its silver in the first alone.
            #expect(data.channelDensity.allSatisfy { $0.y == 0 && $0.z == 0 })
            #expect(data.densityCurves.allSatisfy { $0.x == $0.y && $0.y == $0.z })
            #expect(data.densityCurvesLayers.joined().allSatisfy { $0.x == $0.y && $0.y == $0.z })
            #expect(data.densityCurvesModel.centers.allSatisfy { $0 == data.densityCurvesModel.centers[0] })
        }
    }
    #expect(blackAndWhite == ["kodak_2302", "kodak_doublex", "kodak_trix"])
}

@Test func unknownCurveModelFailsToLoad() throws {
    // Spektrafilm's `dev` has a skewed model too, which no profile uses yet.
    let url = resources.appending(components: "profiles", "kodak_doublex.json")
    let json = try String(contentsOf: url, encoding: .utf8)
        .replacing(#""model_type": "norm_cdfs""#, with: #""model_type": "sept_norm_cdfs""#)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Profile.self, from: Data(json.utf8)) }
}

/// A profile whose columns aren't what its channel model says fails to load: it used to stop the
/// app, or be read with development times as dye layers.
@Test func misdeclaredChannelModelFailsToLoad() throws {
    for (stock, declared, misdeclared) in [("kodak_doublex", "bw", "color"), ("kodak_portra_400", "color", "bw")] {
        let url = resources.appending(components: "profiles", "\(stock).json")
        let json = try String(contentsOf: url, encoding: .utf8)
            .replacing(#""channel_model": "\#(declared)""#, with: #""channel_model": "\#(misdeclared)""#)
        #expect(throws: DecodingError.self, "\(stock)") { try JSONDecoder().decode(Profile.self, from: Data(json.utf8)) }
    }
}

@Test func doubleXMatchesPython() throws {
    let data = try Profile.load("kodak_doublex").data
    #expect(data.developments.map(\.minutes) == [4, 5, 6.5, 9, 12])
    // The standard development, 6.5 minutes: the third column.
    #expect(data.logSensitivity[40] == SIMD3(repeating: -0.8844777543816901))
    #expect(data.channelDensity[40] == SIMD3(1, 0, 0))
    #expect(data.densityCurves[128] == SIMD3(repeating: 1.0957009053913696))
    #expect(data.baseDensity[34] == 0.20916635637401282)
    #expect(data.densityCurvesLayers[200][1] == SIMD3(repeating: 0.5564849115012441))
    #expect(data.densityCurvesModel.sigmas == [[Double]](repeating: [0.4358464913906826, 0.627575009130178, 0.6302112268747068], count: 3))
    #expect(data.logSensitivity.filter(\.x.isNaN).count == 33)
    // Tri-X Reversal has one development, and its base density as a flat list.
    let triX = try Profile.load("kodak_trix").data
    #expect(triX.developments.map(\.minutes) == [1])
    #expect(triX.baseDensity[34] == 0.21563851598139488 && triX.densityCurves[128].x == 0.07852433984913283)
}

/// A black-and-white stock developed for a time is the measured one nearest, the shorter of two
/// as near, and without a time the middle one; a colour stock, whatever the time, as it is.
@Test func developmentTimeSelectsTheNearestMeasured() throws {
    let doubleX = try Profile.load("kodak_doublex")
    // The curve at one exposure, for each measured time (the profile's columns).
    let curve = [4: 0.7662824461682298, 5: 0.9201443595503129, 6.5: 1.0957009053913696, 9: 1.382116116572412,
                 12: 1.7733230229264347]
    for (asked, developed) in [(nil, 6.5), (6.5, 6.5), (8, 9), (4.5, 4), (5.75, 5), (0, 4), (100, 12)] as [(Double?, Double)] {
        #expect(doubleX.developed(minutes: asked).data.densityCurves[128] == SIMD3(repeating: curve[developed]!), "\(asked ?? .nan)")
    }
    let nine = doubleX.developed(minutes: 9).data
    #expect(nine.baseDensity[34] == 0.2414581745698535)
    #expect(nine.densityCurvesLayers[200][1] == SIMD3(repeating: 0.6766898220973119))
    #expect(nine.densityCurvesModel.sigmas != doubleX.data.densityCurvesModel.sigmas)
    #expect(nine.logSensitivity.map(\.x.bitPattern) == doubleX.data.logSensitivity.map(\.x.bitPattern))

    let portra = try Profile.load("kodak_portra_400")
    #expect(portra.developed(minutes: 9).data.densityCurves == portra.data.densityCurves)
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
    #expect(tables.spektrafilmCommit == SpektraEngine.referenceCommit)
    #expect(tables.wavelengths.count == 81 && tables.wavelengths.first == 380 && tables.wavelengths.last == 780)
    #expect(tables.cmfs[35] == SIMD3(0.5120500999999994, 1.0000000000000004, 0.005749999000000004))
    #expect(tables.illuminants["TH-KG3"]?[40] == 1.4771790396751106)
    #expect(tables.illuminants["K75P"]?[10] == 1.217982861892341)
    #expect(tables.dichroicFilters[30] == SIMD3(1.0, 5.686362830603642e-08, 0.9505199229902971))
    #expect(tables.colourSpaces["ProPhoto RGB"]?.rgbToXYZ[0] == SIMD3(0.7977, 0.1352, 0.0313))
    #expect(tables.colourSpaces.count == 7 && tables.chromaticAdaptation.count == 3)

    let filters = try Tables.loadNeutralPrintFilters()
    #expect(filters["kodak_2383"]?["TH-KG3"]?["kodak_vision3_500t"] == SIMD3(0.0, 44.613539160437185, 56.764119641390934))
    // The black-and-white stocks' entries, which tools/export_tables.py alone doesn't write
    // (tools/black_and_white.py after it does).
    #expect(filters["kodak_2302"]?["TH-KG3"]?["kodak_doublex"] == SIMD3(0.0, 1.3603519458822788, 1.4648221433543327))
    let profiles = try Profile.stocks().map(Profile.load).map(\.info)
    for paper in profiles where paper.stage == .printing {
        for film in profiles where film.stage == .filming {
            #expect(filters[paper.stock]?["TH-KG3"]?[film.stock] != nil, "\(film.stock) on \(paper.stock)")
        }
    }
}

/// The black-and-white stocks' reference data (tools/black_and_white.py) is from the commit the
/// engine names for them.
@Test func blackAndWhiteReferenceDataIsFromItsCommit() throws {
    struct Manifest: Decodable { let spektrafilmCommit: String }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: goldenFile("manifest-bw.json")))
    #expect(manifest.spektrafilmCommit == SpektraEngine.blackAndWhiteCommit)
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
