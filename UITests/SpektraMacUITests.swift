import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest

/// SpektraMac driven as a person drives it, through its accessibility tree: what's greyed out, what
/// a menu item says, how a control looks, and the accessibility audit. They need Automation Mode
/// (CONTRIBUTING.md) and take over the screen while they run.
///
/// Each test opens a photo of its own as Finder's Open With does, and undoes its changes before the
/// app quits, so the settings the app keeps for its next launch are the ones it started with.
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
        undo = undoItem()
        XCTAssertFalse(undo.title.contains("Undo Halation"), "Edit › Undo shows “\(undo.title)” once undone")
        XCTAssertFalse(undo.isEnabled, "Undo with nothing to undo")
    }

    // MARK: Accessibility

    /// The accessibility audit (missing labels, contrast, hit areas, clipped text…) of the main window
    /// with each settings tab showing, and of the Log window. Any finding fails the test.
    @MainActor func testAccessibilityAudit() throws {
        try launch()
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
                findings.append("\(place): \(Self.describe(issue))")
                return true
            }
        }
        for tab in Tab.allCases {
            showTab(tab)
            try audit("\(tab) tab")
        }
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssert(app.windows["Log"].waitForExistence(timeout: 5))
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

    /// Launches the app and opens a photo in it.
    @MainActor private func launch() throws {
        continueAfterFailure = true
        folder = URL.temporaryDirectory.appending(path: "SpektraMacUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app = XCUIApplication()
        // Without the windows it had open: each test ends the app (`terminate()`), and macOS would
        // open them again, such as the Log window the audit leaves open (#324).
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
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

    /// Undoes every change the test made, so the app keeps the settings it started with, then quits.
    @MainActor private func quit() {
        while undoItem().isEnabled {
            app.typeKey("z", modifierFlags: .command)
        }
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

    @MainActor private func choose(film: String) {
        app.popUpButtons["Film"].click()
        app.menuItems[film].click()
    }

    /// The settings panel.
    @MainActor private var panel: XCUIElement {
        app.windows["main"].scrollViews.firstMatch
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
        if inOptions {
            // A value slider, as the options' sliders all are, which follows a drag's distance:
            // adjust(toNormalizedSliderPosition:) drags it from its value to there (#317).
            slider.adjust(toNormalizedSliderPosition: 0.85)
        } else {
            // A thumbnail strip, which a click along it sets there.
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).click()
        }
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
