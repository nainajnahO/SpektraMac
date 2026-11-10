import Foundation
import Testing
@testable import SpektraEngine

/// The settings' rules the app follows (the ``Controls`` extension): what each Reset button
/// resets, what Undo is called, what choosing a film sets, how a preset is made renderable, where
/// the Exposure slider lands, and the strips' frames.

/// `Controls`' stored properties, by name, in order: found by reflection, so a new control is in.
private let controlNames = Mirror(reflecting: Controls()).children.compactMap(\.label)

/// Each adjustment's group as the panel titles it, which is also its controls' Undo name.
private let adjustmentTitles: [Controls.Adjustment: String] = [
    .exposure: "Exposure", .cameraDiffusion: "Lens Diffusion", .halation: "Halation", .couplers: "Couplers",
    .grain: "Grain", .contrast: "Contrast", .enlarger: "Enlarger", .burn: "Burn",
    .enlargerDiffusion: "Enlarger Diffusion", .glare: "Glare",
]

/// The controls as their preset's JSON object.
private func json(_ controls: Controls) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: controls.preset()) as! [String: Any]
}

/// Controls with every stored property away from its default, whatever they are, through the
/// preset's JSON: each number moved by 1 (whole numbers kept whole, so the exposure mark becomes
/// the next one) and each Boolean flipped, nested ones too, the stock names changed, and the
/// development times, which a preset leaves out at their default, given.
private func variedControls() throws -> Controls {
    func vary(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]: object.mapValues(vary)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): !number.boolValue
        case let number as NSNumber where ["d", "f"].contains(String(cString: number.objCType)): number.doubleValue + 1
        case let number as NSNumber: number.intValue + 1
        default: value  // a diffusion filter's family: the filter differs by its other values
        }
    }
    var varied = try json(Controls()).mapValues(vary)
    varied["film"] = "kodak_gold_200"
    varied["paper"] = "kodak_2383"
    varied["filmDevelopmentTime"] = 9.0
    varied["paperDevelopmentTime"] = 7.0
    return try Controls(preset: JSONSerialization.data(withJSONObject: varied))
}

/// `Controls()` with only the control `name` as `varied` has it.
private func controls(changing name: String, as varied: Controls) throws -> Controls {
    var object = try json(Controls())
    object[name] = try json(varied)[name]
    return try Controls(preset: JSONSerialization.data(withJSONObject: object))
}

/// Each stored property's value, by name, as text to compare.
private func values(_ controls: Controls) -> [String: String] {
    Dictionary(uniqueKeysWithValues: Mirror(reflecting: controls).children.map { ($0.label!, "\($0.value)") })
}

/// A photo metered with As shot at 0 and Centre-weighted at `ev`: uniform, `ev` stops under mid-grey.
private func readings(centreWeighted ev: Double) -> MeteringReadings {
    MeteringReadings(luminance: [Double](repeating: 0.184 * exp2(-ev), count: 16), width: 4, height: 4, regions: nil)
}

/// Every stored property but the stocks, their development and Print | Film is reset by exactly
/// one adjustment, to the defaults it's given: a new control fails here until it's placed in one.
@Test func everyControlIsResetByOneAdjustment() throws {
    let (defaults, varied) = (Controls(), try variedControls())
    let (defaultValues, variedValues) = (values(defaults), values(varied))
    #expect(controlNames.allSatisfy { defaultValues[$0] != variedValues[$0] }, "the test varies every control")
    var resetBy: [String: [Controls.Adjustment]] = [:]
    for adjustment in Controls.Adjustment.allCases {
        let reset = values(varied.resetting(adjustment, to: defaults))
        for name in controlNames where reset[name] != variedValues[name] {
            #expect(reset[name] == defaultValues[name], "\(adjustment) sets \(name) to something else")
            resetBy[name, default: []].append(adjustment)
        }
    }
    for name in controlNames {
        let expected = ["film", "paper", "scanFilm", "filmDevelopmentTime", "paperDevelopmentTime"].contains(name) ? 0 : 1
        #expect(resetBy[name, default: []].count == expected, "\(name) is reset by \(resetBy[name] ?? [])")
    }
}

/// Each adjustment resets its own controls, those whose Undo name is its group's, and no others.
@Test func eachAdjustmentResetsItsOwnControls() throws {
    let (defaults, varied) = (Controls(), try variedControls())
    let variedValues = values(varied)
    for adjustment in Controls.Adjustment.allCases {
        let reset = values(varied.resetting(adjustment, to: defaults))
        for name in controlNames {
            let group = Controls.groupName(changedFrom: defaults, to: try controls(changing: name, as: varied))
            let isReset = reset[name] != variedValues[name]
            #expect(isReset == (group == adjustmentTitles[adjustment]), "\(adjustment) \(isReset ? "resets" : "keeps") \(name)")
        }
    }
}

/// Every stored property has an Undo name of its own group, not the catch-all "Settings".
@Test func everyControlHasAnUndoName() throws {
    let varied = try variedControls()
    for name in controlNames {
        let group = Controls.groupName(changedFrom: Controls(), to: try controls(changing: name, as: varied))
        #expect(group != "Settings", "\(name)")
    }
    #expect(Controls.groupName(changedFrom: Controls(), to: Controls()) == "Settings")
}

/// Choosing each film sets its target paper if it has one (Double-X, whose profile names none,
/// the black-and-white print film), develops the film and a paper it set their standard way, and
/// views exactly the slides directly, leaving every other control as it was.
@Test func choosingAFilmSetsItsPaperAndViewsSlides() throws {
    let films = try Profile.stocks().map(Profile.load).map(\.info).filter { $0.stage == .filming }
    #expect(films.count == 22)
    var start = try variedControls()
    start.paper = "kodak_2393"  // no film's target print
    var slides: [String] = []
    for film in films {
        let chosen = start.choosing(film: film.stock, from: films)
        var expected = start
        expected.film = film.stock
        expected.filmDevelopmentTime = nil
        if let paper = film.stock == "kodak_doublex" ? "kodak_2302" : film.targetPrint {
            expected.paper = paper
            expected.paperDevelopmentTime = nil
        }
        expected.scanFilm = chosen.scanFilm
        #expect(chosen == expected, "\(film.stock)")
        if chosen.scanFilm {
            slides.append(film.stock)
        }
    }
    #expect(slides.sorted() == ["fujifilm_provia_100f", "fujifilm_velvia_100", "kodak_ektachrome_100", "kodak_kodachrome_64", "kodak_trix"])
    // A film that isn't there: only the film changes.
    #expect(start.choosing(film: "unknown", from: films).paper == start.paper)
}

/// A preset edited by hand comes back renderable: numbers clamped to their ranges, a slide set to
/// print viewed as film, and the names of what changed, in the controls' order.
@Test func presetsAreMadeRenderable() throws {
    let films = try Profile.stocks().map(Profile.load).map(\.info)
    var preset = Controls()
    preset.film = "kodak_kodachrome_64"
    preset.scanFilm = false
    preset.printContrast = 0
    preset.grainSize = 50
    preset.cameraDiffusion.strength = 9
    let (checked, changed) = preset.checked(films: films)
    var expected = preset
    expected.scanFilm = true
    expected.printContrast = 0.1
    expected.grainSize = 2
    expected.cameraDiffusion.strength = 2
    #expect(checked == expected)
    #expect(changed == ["scanFilm", "printContrast", "grainSize", "cameraDiffusion"])
    let unchanged = Controls().checked(films: films)
    #expect(unchanged.controls == Controls() && unchanged.changed.isEmpty)
}

/// The Exposure slider keeps the controls' mark wherever it's set, beside another mark too, and
/// moves the offset from it, which the next photo's reading of that mark takes. A mark the photo
/// has no reading for is kept too, the offset counting from the mark it starts from.
@Test func exposureKeepsItsMark() {
    let metered = readings(centreWeighted: 2)
    #expect(abs(metered.ev[MeteringMark.centreWeighted.rawValue]! - 2) < 1e-12)
    #expect(abs(metered.ev[MeteringMark.asShot.rawValue]!) < 1e-12)
    let besideAsShot = Controls().setting(.exposure, to: 0.1, readings: metered)
    #expect(besideAsShot.exposureMark == .centreWeighted && abs(besideAsShot.exposureOffsetEV - -1.9) < 1e-12)
    #expect(abs(besideAsShot.exposureEV(readings: readings(centreWeighted: -3)) - -4.9) < 1e-12)
    var faces = Controls()
    faces.exposureMark = .faces
    let over = faces.setting(.exposure, to: 2.5, readings: metered)
    #expect(over.exposureMark == .faces && abs(over.exposureOffsetEV - 0.5) < 1e-12)
}

/// The exposure's range is −4…+8 stops, widened to whole stops past a reading outside it.
@Test func exposureRangeWidensPastReadings() {
    #expect(Controls.exposureRange(readings: nil) == -4...8)
    #expect(Controls.exposureRange(readings: readings(centreWeighted: 2)) == -4...8)
    #expect(Controls.exposureRange(readings: readings(centreWeighted: 9.5)) == -4...11)
    #expect(Controls.exposureRange(readings: readings(centreWeighted: -5.2)) == -7...8)
}

/// A strip's frames set its control, the exposure's from the controls' mark; a strip whose control
/// changes nothing the controls show has none: the print's while the film shows, and the
/// saturation's with the couplers off, or on a black-and-white film, which has one layer.
@Test func stripsFrameTheirControl() throws {
    let films = try Profile.stocks().map(Profile.load).map(\.info).filter { $0.stage == .filming }
    var controls = Controls()
    #expect(Controls.Strip.allCases.allSatisfy { $0.applies(to: controls, films: films) })
    #expect(Controls.Strip.allCases.filter { $0.applies(to: controls.choosing(film: "kodak_doublex", from: films), films: films) }
            == [.exposure, .printExposure])
    controls.couplers = false
    controls.scanFilm = true
    #expect(Controls.Strip.allCases.filter { $0.applies(to: controls, films: films) } == [.exposure])
    let metered = readings(centreWeighted: 2)
    #expect(abs(Controls().setting(.exposure, to: 3, readings: metered).exposureEV(readings: metered) - 3) < 1e-12)
    #expect(Controls().setting(.couplerSaturation, to: 0.4, readings: metered).couplerSaturation == 0.4)
    #expect(Controls().setting(.printExposure, to: 1.3, readings: metered).printExposure == 1.3)
}
