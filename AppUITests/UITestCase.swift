import XCTest

/// The base of every UI test. Whenever a keyboard is on screen, the one control for it is the keyboard-down button above it (`keyboard-hide`). There is no "Done" for the
/// keyboard anywhere, and no bar of the system's own (previous / next / done) over a web page's boxes. Typing through `typeTextChecked`, and the end of every test,
/// check it, so it holds in every journey, not only in the one test written for it. docs/UX.md, "The keyboard".
class UITestCase: XCTestCase {
    override func tearDown() {
        // The keyboard may be up when a test ends: the app is still the one in front.
        let app = XCUIApplication()
        if app.state == .runningForeground { app.assertTheKeyboardShowsOnlyTheHideButton() }
        super.tearDown()
    }
}

extension XCUIApplication {
    /// With a keyboard up: the keyboard-down button is above it, no bar of the system's is attached to it, and no button above it says Done (or Next, or Previous).
    func assertTheKeyboardShowsOnlyTheHideButton(file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = keyboards.firstMatch
        guard keyboard.exists else { return }
        let top = keyboard.frame.minY
        XCTAssertTrue(buttons["keyboard-hide"].waitForExistence(timeout: 3), "a keyboard-down button sits above the keyboard", file: file, line: line)
        XCTAssertFalse(buttons["keyboard-done"].exists, "no Done button for the keyboard", file: file, line: line)
        // No bar of the system's own attached to the keyboard (a web page's previous / next / done bar).
        let bars = toolbars.allElementsBoundByIndex.filter { $0.exists && abs($0.frame.maxY - top) < 60 && !$0.frame.isEmpty }
        XCTAssertTrue(bars.isEmpty, "no toolbar of its own above the keyboard: \(bars.map { $0.identifier })", file: file, line: line)
        let words = buttons.matching(NSPredicate(format: "label IN {'Done', 'Next', 'Previous'} AND identifier != 'keyboard-hide'")).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY >= top - 100 && $0.frame.minY < top && !$0.frame.isEmpty }          // the band just above the keyboard
        XCTAssertTrue(words.isEmpty, "no Done / Next / Previous button at the keyboard: \(words.map { $0.label })", file: file, line: line)
    }
}

extension XCUIElement {
    /// Types, then checks what is above the keyboard (see `UITestCase`).
    func typeTextChecked(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        typeText(text)
        XCUIApplication().assertTheKeyboardShowsOnlyTheHideButton(file: file, line: line)
    }
}
