import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest

/// SpektraMac driven as a person drives it, through its accessibility tree: what's greyed out, what
/// a menu item says, how a control looks, and the accessibility audit. They need Automation Mode
/// (CONTRIBUTING.md) and take over the screen while they run.
///
/// Each test starts the app from the film's defaults, in settings of its own (`-UITesting`), and
/// opens a photo of its own as Finder's Open With does: the installed app's settings and Open Recent
/// stay as they were (#337).
final class SpektraMacUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The test's photo, removed after.
    private var folder: URL!

    // MARK: Reset arrows

    /// Each settings group's Reset arrow is greyed out at the film's defaults and works after a
    /// change, and looks different in the two (#285: it was disabled, but drawn as when enabled).
    @MainActor func testResetArrowsAreDisabledAtTheFilmsDefaults() throws {
        try launch()
        defer { quit() }
        // A negative film, printed, so the Print tab shows its groups.
        showTab(.film)
        choose(film: "Kodak Portra 400")
        showSwitch.radioButtons["Print"].click()
        for tab in Tab.allCases {
            showTab(tab)
            // From the film's defaults.
            for reset in resetArrows() where reset.isEnabled {
                reset.click()
            }
            for reset in resetArrows() {
                let group = String(reset.label.dropFirst("Reset ".count))
                XCTAssertFalse(reset.isEnabled, "\(reset.label) at the film's defaults")
                let atDefaults = reset.screenshot().pngRepresentation
                change(group, below: reset)
                XCTAssertTrue(reset.isEnabled, "\(reset.label) after a change")
                XCTAssertNotEqual(reset.screenshot().pngRepresentation, atDefaults,
                                  "\(reset.label) looks the same enabled as disabled")
                reset.click()
                XCTAssertFalse(reset.isEnabled, "\(reset.label) after resetting")
            }
        }
    }

    // MARK: The Print | Film switch

    /// A slide has no print: the switch is greyed out on Velvia 100, and works on a negative.
    @MainActor func testPrintFilmSwitchIsDisabledOnASlide() throws {
        try launch()
        defer { quit() }
        showTab(.film)
        choose(film: "Fujifilm Velvia 100")
        XCTAssertFalse(showSwitch.isEnabled, "the Print | Film switch on a slide")
        choose(film: "Kodak Portra 400")
        XCTAssertTrue(showSwitch.isEnabled, "the Print | Film switch on a negative")
    }

    // MARK: Black-and-white film

    /// A black-and-white film has a Development control, as the print film it's printed on has,
    /// and no Saturation, which is between a colour film's layers; a colour film, the reverse
    /// (#350). The control is the default, the time on a row that shows a segmented picker
    /// (#365).
    @MainActor func testBlackAndWhiteFilmHasDevelopmentAndNoSaturation() throws {
        try launch()
        defer { quit() }
        showTab(.film)
        choose(film: "Kodak Double-X Negative Film 5222")
        XCTAssert(panel.buttons["Development"].waitForExistence(timeout: 5), "Development on Double-X")
        XCTAssertFalse(panel.sliders["Saturation"].exists, "Saturation on Double-X")
        showTab(.print)
        XCTAssertEqual(app.popUpButtons["Paper"].value as? String, "Kodak Print Film 2302")
        XCTAssert(panel.buttons["Development"].waitForExistence(timeout: 5), "Development on 2302")
        showTab(.film)
        choose(film: "Kodak Portra 400")
        XCTAssert(panel.sliders["Saturation"].waitForExistence(timeout: 5), "Saturation on Portra 400")
        XCTAssertFalse(panel.buttons["Development"].exists, "Development on Portra 400")
    }

    /// The Development row's default: a click on the time shows a segmented picker, with a film's
    /// standard time chosen to begin with; a click on a segment chooses its time, Undo puts back
    /// the one before, and another click on the time hides the picker (#365).
    @MainActor func testDevelopmentSegmentChoosesItsTime() throws {
        try launch()
        defer { quit() }
        showTab(.film)
        choose(film: "Kodak Double-X Negative Film 5222")
        let row = panel.buttons["Development"], times = panel.radioGroups["Development"]
        XCTAssert(row.waitForExistence(timeout: 5), "Development on Double-X")
        XCTAssertFalse(times.exists, "the picker before a click on the time")
        row.click()
        XCTAssert(times.waitForExistence(timeout: 5), "the picker after a click on the time")
        let standard = times.radioButtons[6.5.formatted()], nine = times.radioButtons["9"]
        XCTAssertNotNil(value(of: standard) { $0 == 1 }, "the standard time chosen to begin with")
        nine.click()
        XCTAssertNotNil(value(of: nine) { $0 == 1 }, "9 chosen")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertNotNil(value(of: standard) { $0 == 1 }, "the standard time after Undo")
        row.click()
        XCTAssert(times.waitForNonExistence(timeout: 5), "the picker after another click on the time")
    }

    /// The Development dial is a clock's face of 12 minutes, on a film's standard time to begin
    /// with. Out of the window's edge, a click sets the measured time nearest it, as a drag does on
    /// its way, and Undo puts back the one before (#352).
    @MainActor func testDevelopmentDialSetsTheMeasuredTimeNearestThePointer() throws {
        try launch()
        defer { quit() }
        showTab(.film)
        choose(film: "Kodak Double-X Negative Film 5222")
        use("Stopwatch")
        let dial = panel.sliders["Development"]
        XCTAssert(dial.waitForExistence(timeout: 5), "Development on Double-X")
        bringOut(dial)
        /// A point on the dial, `across` and `down` from its centre as parts of its radius.
        func onDial(_ across: Double, _ down: Double) -> XCUICoordinate {
            dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + across / 2, dy: 0.5 + down / 2))
        }
        XCTAssertNotNil(value(of: dial) { $0 == 6.5 }, "the standard time, at \(dial.value ?? "none")")
        // At 9 o'clock, a measured time; then at 8, between two of them and nearer 9 than 6.5.
        onDial(-0.75, 0).click()
        XCTAssertNotNil(value(of: dial) { $0 == 9 }, "a click at 9, at \(dial.value ?? "none")")
        onDial(0, -0.75).click()
        XCTAssertNotNil(value(of: dial) { $0 == 12 }, "a click at 12, at \(dial.value ?? "none")")
        onDial(-0.65, 0.375).click()
        XCTAssertNotNil(value(of: dial) { $0 == 9 }, "a click at 8, at \(dial.value ?? "none")")
        // From 12 round to between 4 and 5, past 4: a drag is one step to undo.
        onDial(0, -0.75).click(forDuration: 0.3, thenDragTo: onDial(0.4, 0.65), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertNotNil(value(of: dial) { $0 == 5 }, "a drag from 12 to 5, at \(dial.value ?? "none")")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertNotNil(value(of: dial) { $0 == 9 }, "Undo after the drag, at \(dial.value ?? "none")")
    }

    /// The button on top of the Development dial goes to the next measured time, and after the
    /// longest back to the shortest (#352).
    @MainActor func testDevelopmentButtonGoesToTheNextTime() throws {
        try launch()
        defer { quit() }
        showTab(.film)
        choose(film: "Kodak Double-X Negative Film 5222")
        use("Stopwatch")
        let dial = panel.sliders["Development"], next = panel.buttons["Next time"]
        XCTAssert(dial.waitForExistence(timeout: 5), "Development on Double-X")
        bringOut(dial)
        XCTAssertNotNil(value(of: dial) { $0 == 6.5 }, "the standard time, at \(dial.value ?? "none")")
        next.click()
        XCTAssertNotNil(value(of: dial) { $0 == 9 }, "once from 6.5, at \(dial.value ?? "none")")
        next.click()
        XCTAssertNotNil(value(of: dial) { $0 == 12 }, "twice, at \(dial.value ?? "none")")
        next.click()
        XCTAssertNotNil(value(of: dial) { $0 == 4 }, "three times, round to the shortest, at \(dial.value ?? "none")")
    }

    // MARK: Metering marks

    /// A photo opens at its exposure as shot (#360). The pointer on a mark's dot opens a bubble
    /// under it saying what the mark meters, each mark's on a dot marks share, and a click there
    /// puts the exposure on the dot, at the mean of its marks' readings (#359), in one step to undo.
    /// The bubble closes as the pointer leaves the dots (#353).
    @MainActor func testClickingADotPutsTheExposureOnIt() throws {
        try launch()
        defer { quit() }
        showTab(.camera)
        // The test's photo is a gradient: As shot reads it at 0 and Centre-weighted 0.016 stops
        // over, a third of a point to its right on the strip, so they share a dot, at 0.008. Its
        // range is −4…+8 stops. The strip's value is the exposure, in stops.
        let strip = panel.sliders["Exposure"]
        XCTAssert(strip.waitForExistence(timeout: 5), "the Exposure strip")
        XCTAssertNotNil(value(of: strip) { $0 == 0 }, "the photo opened as shot, at \(strip.value ?? "none")")
        let marks = strip.normalizedSliderPosition
        strip.adjust(toNormalizedSliderPosition: 0.9)
        let overTheMarks = try XCTUnwrap(value(of: strip) { $0 > 1 }, "the exposure well over the marks, at \(strip.value ?? "none")")
        // On the dots' row, 2 points above the strip's foot, and 6 points left of the dot: within
        // its reach, where a click on the frames would land 0.3 stops under.
        let besideTheDot = strip.coordinate(withNormalizedOffset: CGVector(dx: marks, dy: 1))
            .withOffset(CGVector(dx: -6, dy: -2))
        besideTheDot.hover()
        let bubble = app.popovers.firstMatch
        XCTAssert(bubble.waitForExistence(timeout: 5), "a bubble with the pointer on the dot")
        for name in ["As shot", "Centre-weighted"] {
            XCTAssert(bubble.staticTexts.matching(NSPredicate(format: "value == %@", name)).firstMatch.exists, "\(name) in the bubble")
        }
        XCTAssertGreaterThanOrEqual(bubble.frame.minY, strip.frame.maxY, "the bubble under the strip")
        besideTheDot.click()
        XCTAssertNotNil(value(of: strip) { abs($0 - 0.008) < 0.001 }, "the exposure on the dot, at \(strip.value ?? "none")")
        let undo = undoItem()
        XCTAssert(undo.title.contains("Undo Exposure"), "Edit › Undo shows “\(undo.title)”")
        // The exposure back as it was, in one step.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertNotNil(value(of: strip) { abs($0 - overTheMarks) < 0.01 }, "the exposure back after Undo, at \(strip.value ?? "none")")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssert(bubble.waitForNonExistence(timeout: 5), "the bubble with the pointer on the frames")
    }

    // MARK: Undo

    /// Edit › Undo names the change, and is greyed out once there's nothing left to undo.
    @MainActor func testUndoNamesTheChange() throws {
        try launch()
        defer { quit() }
        showTab(.film)
        try XCTUnwrap(toggle("Halation")).click()
        var undo = undoItem()
        XCTAssert(undo.title.contains("Undo Halation"), "Edit › Undo shows “\(undo.title)”")
        XCTAssertTrue(undo.isEnabled, "Undo after a change")
        app.typeKey("z", modifierFlags: .command)
        // Once in a while, a second after ⌘Z, macOS hasn't updated the menu yet: Undo no longer
        // names the change, but still shows enabled (#334). Opened again until it's greyed out, for
        // up to five seconds.
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            undo = undoItem()
        } while undo.isEnabled && Date.now < deadline
        XCTAssertFalse(undo.title.contains("Undo Halation"), "Edit › Undo shows “\(undo.title)” once undone")
        XCTAssertFalse(undo.isEnabled, "Undo with nothing to undo")
    }

    // MARK: Accessibility

    /// The accessibility audit (missing labels, contrast, hit areas, clipped text…) of the main window
    /// with each settings tab showing, and of the Log window, in light mode. Any finding fails the
    /// test.
    @MainActor func testAccessibilityAuditInLightMode() throws {
        try auditApp(in: "light")
    }

    /// The same in dark mode: contrast differs between the two, and the Mac may be in either.
    @MainActor func testAccessibilityAuditInDarkMode() throws {
        try auditApp(in: "dark")
    }

    /// The audit of the Film and Print tabs again under a black-and-white film and the print film it
    /// brings with it, in light and in dark mode, for their Development controls: the time on a row,
    /// with its segmented picker hidden and shown, and the stopwatch tucked into the window's edge
    /// and out. The tabs' audit is of the
    /// films' default, a colour film, which has none (#352, #365).
    @MainActor func testAccessibilityAuditOfTheDevelopmentDials() throws {
        var findings: [String] = []
        for appearance in ["light", "dark"] {
            try launch(appearance: appearance)
            defer { quit() }
            showTab(.film)
            choose(film: "Kodak Double-X Negative Film 5222")
            for control in ["Segmented Picker", "Stopwatch"] {
                use(control)
                // The pointer off the settings, where the menus leave it: a help tag it brings up
                // there is an element with no description to the audit.
                app.windows["main"].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).hover()
                for tab in [Tab.film, .print] {
                    showTab(tab)
                    let development = control == "Stopwatch" ? panel.sliders["Development"] : panel.buttons["Development"]
                    XCTAssert(development.waitForExistence(timeout: 5), "Development on the \(tab) tab")
                    // Once the film's renders have landed, as for the tabs' audit.
                    Thread.sleep(forTimeInterval: 3)
                    for state in control == "Stopwatch" ? ["stopwatch tucked", "stopwatch out"] : ["picker hidden", "picker shown"] {
                        if state == "stopwatch out" {
                            bringOut(development)
                        } else if state == "picker shown" {
                            development.click()
                            XCTAssert(panel.radioGroups["Development"].waitForExistence(timeout: 5), "the picker on the \(tab) tab")
                            // The pointer off the settings again, from the time.
                            app.windows["main"].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).hover()
                        }
                        try app.performAccessibilityAudit { issue in
                            findings.append("\(appearance), \(tab) tab, \(state): \(Self.describe(issue))")
                            return true
                        }
                    }
                }
            }
        }
        XCTAssert(findings.isEmpty, "\(findings.count) findings:\n" + findings.joined(separator: "\n"))
    }

    /// The audit with the app in `appearance` (`-UITestAppearance`).
    @MainActor private func auditApp(in appearance: String) throws {
        try launch(appearance: appearance)
        defer { quit() }
        // Once the photo has rendered, as the subtitle says, and its strips have followed: while
        // its first renders land, SwiftUI replaces views under the audit, which then reports
        // elements that are gone, such as a parent/child mismatch or a missing action naming no
        // element (#313, #325).
        let rendered = NSPredicate(format: "title CONTAINS 'Screen size' OR title CONTAINS 'Full resolution'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: rendered, evaluatedWith: app.windows["main"])], timeout: 30),
                       .completed, "the photo's render")
        Thread.sleep(forTimeInterval: 2)
        var findings: [String] = []
        /// The audit covers the whole app, so with a `window` given, it leaves out what's outside it.
        func audit(_ place: String, within window: XCUIElement? = nil) throws {
            try app.performAccessibilityAudit { issue in
                if let window, let element = issue.element, !window.frame.contains(element.frame) {
                    return true
                }
                findings.append("\(appearance), \(place): \(Self.describe(issue))")
                return true
            }
        }
        for tab in Tab.allCases {
            showTab(tab)
            try audit("\(tab) tab")
        }
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssert(app.windows["Log"].waitForExistence(timeout: 5))
        // Once it has settled: audited as it opened, a few of its times failed the contrast check
        // in light mode, different lines each time, in 4 runs out of 10; 2 seconds later, in none
        // of 10 (#337).
        Thread.sleep(forTimeInterval: 2)
        // The Log window's own elements: the main window was audited while it was in front, and
        // behind the Log, macOS dims its title and subtitle below the contrast the audit wants, as
        // for any window that isn't key (#315). `performAccessibilityAudit` is the app's alone.
        try audit("Log window", within: app.windows["Log"])
        XCTAssert(findings.isEmpty, "\(findings.count) findings:\n" + findings.joined(separator: "\n"))
    }

    @MainActor private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let element = issue.element.map {
            "\($0.elementType.rawValue) “\($0.label)” “\($0.value.map(String.init(describing:)) ?? "")” \($0.identifier) \($0.frame)"
        } ?? "no element"
        return "\(issue.compactDescription) — \(element) — \(issue.detailedDescription)"
    }

    // MARK: Helpers

    /// The settings tabs, in order: ⌥⌘1, ⌥⌘2 and ⌥⌘3 show them.
    private enum Tab: Int, CaseIterable { case camera = 1, film, print }

    /// Launches the app, in `appearance` if given, and opens a photo in it.
    @MainActor private func launch(appearance: String? = nil) throws {
        continueAfterFailure = true
        folder = URL.temporaryDirectory.appending(path: "SpektraMacUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app = XCUIApplication()
        // Without the windows it had open: each test ends the app (`terminate()`), and macOS would
        // open them again, such as the Log window the audit leaves open (#324).
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-UITesting", "YES"]
            + (appearance.map { ["-UITestAppearance", $0] } ?? [])
        app.launch()
        let photo = try writePhoto(named: "UI Test Photo.jpg")
        let built = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "SpektraMac.app")
        let opened = expectation(description: "Opened the photo")
        NSWorkspace.shared.open([photo], withApplicationAt: built, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)
        app.activate()
        // The window's title is the photo's name once it's open.
        let window = app.windows.matching(NSPredicate(format: "identifier == 'main' AND title BEGINSWITH %@",
                                                      photo.lastPathComponent)).firstMatch
        XCTAssert(window.waitForExistence(timeout: 30), "the photo's window")
        // Opened for the first time after launch, the Edit menu shows every item enabled and Undo
        // unnamed, before macOS has updated it for the window: once, so the tests read it as updated.
        _ = undoItem()
    }

    /// Quits the app, which keeps its settings apart from the installed app's (`-UITesting`).
    @MainActor private func quit() {
        app.terminate()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Edit › Undo, as the menu shows it.
    @MainActor private func undoItem() -> (title: String, isEnabled: Bool) {
        app.menuBarItems["Edit"].click()
        let item = app.menuBarItems["Edit"].menuItems["undo:"]
        XCTAssert(item.waitForExistence(timeout: 5), "Edit › Undo")
        // Once macOS has updated the menu for the window.
        Thread.sleep(forTimeInterval: 1)
        // Its title as the menu shows it: its accessibility title stays “Undo” whatever it shows.
        // Vision reads the shortcut's ⌘Z too, as it can (“96 Z”, say), and not always after the
        // title, so the title is somewhere in the text, not at its start.
        let undo = (Self.text(in: item.screenshot()), item.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        return undo
    }

    /// The text in `screenshot`, as Vision reads it.
    @MainActor private static func text(in screenshot: XCUIScreenshot) -> String {
        let request = VNRecognizeTextRequest()
        request.usesLanguageCorrection = false
        guard let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    @MainActor private func showTab(_ tab: Tab) {
        app.typeKey("\(tab.rawValue)", modifierFlags: [.command, .option])
    }

    /// The toolbar's Print | Film switch: its two segments (the settings tabs have three).
    @MainActor private var showSwitch: XCUIElement {
        app.windows["main"].toolbars.radioGroups.allElementsBoundByIndex.first { $0.radioButtons.count == 2 }
            ?? app.radioGroups["Show"]
    }

    /// Chooses the Development row's control in View › Development Control (#365).
    @MainActor private func use(_ control: String) {
        app.menuBarItems["View"].click()
        app.menuBarItems["View"].menuItems["Development Control"].click()
        app.menuItems[control].click()
    }

    @MainActor private func choose(film: String) {
        app.popUpButtons["Film"].click()
        app.menuItems[film].click()
    }

    /// The settings panel.
    @MainActor private var panel: XCUIElement {
        app.windows["main"].scrollViews.firstMatch
    }

    /// Brings the Development dial out of the window's edge, where it's tucked till the pointer
    /// comes to it, leaving the pointer in the margin right of it, off the face (#352).
    @MainActor private func bringOut(_ dial: XCUIElement) {
        // The face's centre is at one height, tucked or out: the slider's middle.
        panel.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: -10, dy: dial.frame.midY - panel.frame.minY))
            .hover()
        // Till it has slid out.
        Thread.sleep(forTimeInterval: 1)
    }

    /// A control's value (a strip's exposure in stops, the dial's time in minutes, a segment's 1 when
    /// chosen and 0 when not) once `condition` holds for it, within 5 seconds; nil if it doesn't.
    @MainActor private func value(of control: XCUIElement, where condition: (Double) -> Bool) -> Double? {
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            if let value = control.value as? Double, condition(value) {
                return value
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date.now < deadline
        return nil
    }

    /// The Reset arrows of the settings tab showing, top to bottom: buttons, not part of their
    /// group's disclosure triangle (#316).
    @MainActor private func resetArrows() -> [XCUIElement] {
        let arrows = panel.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reset '")).allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertFalse(arrows.isEmpty, "the Reset arrows, as buttons")
        return arrows
    }

    /// A settings group's on/off switch, in its header: a switch, not part of the group's disclosure
    /// triangle (#316). XCUITest finds it among the checkboxes.
    @MainActor private func toggle(_ group: String) -> XCUIElement? {
        XCTAssert(panel.buttons["Reset \(group)"].waitForExistence(timeout: 5), "Reset \(group)")
        let toggle = panel.checkBoxes[group]
        return toggle.exists ? toggle : nil
    }

    /// Changes something in `group`: its switch if it has one, else the first slider under its header.
    @MainActor private func change(_ group: String, below reset: XCUIElement) {
        if let toggle = toggle(group) {
            toggle.click()
            return
        }
        // The group's own sliders: under its header, above the next group's.
        func sliders() -> [XCUIElement] {
            let next = resetArrows().map(\.frame).filter { $0.minY > reset.frame.maxY }.map(\.minY).min() ?? .infinity
            return panel.sliders.allElementsBoundByIndex
                .filter { $0.isEnabled && $0.frame.minY > reset.frame.maxY && $0.frame.maxY < next }
        }
        let inOptions = sliders().isEmpty
        if inOptions {
            // A disclosure triangle, as the label of a disclosure group.
            panel.disclosureTriangles["\(group) options"].click()
            // Until the options have opened, their sliders aren't where they'll be.
            Thread.sleep(forTimeInterval: 1)
        }
        let slider = sliders().min { $0.frame.minY < $1.frame.minY }
        guard let slider else { return XCTFail("Nothing to change in \(group)") }
        // A value slider under Options, or a thumbnail strip: adjust(toNormalizedSliderPosition:)
        // drags either from its value to there (#317, #339).
        slider.adjust(toNormalizedSliderPosition: 0.85)
    }

    /// A 1200 × 800 JPEG in the test's folder: a gradient from dark blue to light orange.
    @MainActor private func writePhoto(named name: String) throws -> URL {
        let (width, height) = (1200, 800)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colours = [CGColor(srgbRed: 0.05, green: 0.1, blue: 0.4, alpha: 1), CGColor(srgbRed: 0.95, green: 0.7, blue: 0.2, alpha: 1)]
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: nil, colors: colours as CFArray, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let url = folder.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssert(CGImageDestinationFinalize(destination))
        return url
    }
}
