import XCTest

/// Launches Tide in its UI-test mode and drives it the way a person with a
/// hardware keyboard would. Every launch starts from a fresh copy of the
/// sample workspace with the Welcome page and README.md open.
class TideUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the app. `settings` is merged over the defaults the tests
    /// share: auto save is off, so an edit stays unsaved until a test saves it.
    @MainActor
    @discardableResult
    func launchTide(settings: [String: Any] = [:]) throws -> XCUIApplication {
        let app = XCUIApplication()
        let defaults: [String: Any] = ["files.autoSave": "off"]
        let merged = defaults.merging(settings) { _, new in new }
        let json = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment["TIDE_UI_TEST_SETTINGS"] = String(decoding: json, as: UTF8.self)
        app.launch()
        require(app, "the workbench to open README.md", timeout: 90) { app.editor.exists }
        return app
    }

    /// Waits for `condition`, failing with diagnostics on timeout.
    @MainActor
    func require(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        if !waitUntil(timeout, condition) {
            fail(app, "Timed out after \(Int(timeout))s waiting for \(what).", file: file, line: line)
        }
    }

    /// Presses a shortcut until `opened` holds. Just after launch SwiftUI can
    /// still have the menu bar's items disabled, so a press can go unanswered;
    /// it is repeated every 3 seconds, at most four times.
    @MainActor
    func press(_ app: XCUIApplication, _ key: String, _ modifiers: XCUIElement.KeyModifierFlags = [], opening what: String, file: StaticString = #filePath, line: UInt = #line, until opened: () -> Bool) {
        for _ in 0..<4 {
            app.typeKey(key, modifierFlags: modifiers)
            if waitUntil(3, opened) { return }
        }
        fail(app, "Four presses of the shortcut did not open \(what).", file: file, line: line)
    }

    /// Waits for `element` to have keyboard focus, tapping it if focus does
    /// not arrive on its own.
    @MainActor
    @discardableResult
    func focus(_ app: XCUIApplication, _ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        require(app, "\(name) to appear", file: file, line: line) { element.exists }
        if !waitUntil(2, { element.hasKeyboardFocus }) { element.tap() }
        require(app, "\(name) to have keyboard focus", file: file, line: line) { element.hasKeyboardFocus }
        return element
    }

    /// Keeps a screenshot in the result bundle; CI uploads them as an artifact.
    @MainActor
    func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    /// Fails with the accessibility tree in the message and attached, plus a
    /// screenshot, so a red run on CI explains itself.
    @MainActor
    private func fail(_ app: XCUIApplication, _ message: String, file: StaticString, line: UInt) {
        let tree = app.debugDescription
        let attachment = XCTAttachment(string: tree)
        attachment.name = "accessibility tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        screenshot(app, "failure")
        XCTFail("\(message)\n\(tree)", file: file, line: line)
    }
}

extension XCUIApplication {
    /// Any element by accessibility identifier, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    /// The active editor; with a split there is one per group.
    var editor: XCUIElement { textViews["code-editor"].firstMatch }
    var editors: XCUIElementQuery { textViews.matching(identifier: "code-editor") }
    var paletteField: XCUIElement { textFields["quick-input-field"] }
    var paletteRows: XCUIElementQuery { descendants(matching: .any).matching(identifier: "quick-input-item") }
    var statusPosition: XCUIElement { buttons["status-position"] }
}

extension XCUIElement {
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
    var stringValue: String { (value as? String) ?? "" }
}
