import XCTest

/// End-to-end flows through the real app on an iPad simulator, driven with
/// hardware-keyboard shortcuts as on an iPad with a keyboard attached.
final class TideUITests: TideUITestCase {
    @MainActor
    func testLaunchOpensTheSampleWorkspace() throws {
        let app = try launchTide()
        XCTAssertTrue(app.element("tab-Welcome").exists)
        XCTAssertTrue(app.element("tab-README.md").exists)
        XCTAssertTrue(app.editor.stringValue.hasPrefix("# Welcome to Tide"))
        require(app, "the cursor position in the status bar") { app.statusPosition.label == "Ln 1, Col 1" }
        XCTAssertTrue(app.buttons["status-language"].label.contains("Markdown"))
        screenshot(app, "workbench")
    }

    @MainActor
    func testCommandPaletteRunsACommand() throws {
        let app = try launchTide()
        app.press("p", [.command, .shift])
        let field = focus(app, app.paletteField, "the Command Palette")
        XCTAssertEqual(field.stringValue, ">")
        field.typeText("toggle terminal")
        require(app, "View: Toggle Terminal as the top match") { app.paletteRows.firstMatch.label.contains("View: Toggle Terminal") }
        screenshot(app, "command-palette")
        field.typeText("\n")
        require(app, "the palette to close") { !app.paletteField.exists }
        require(app, "the terminal to open") { app.element("terminal").exists }

        app.press("p", [.command, .shift])
        focus(app, app.paletteField, "the Command Palette").typeText("zzqx")
        require(app, "the empty-result message") { app.staticTexts["quick-input-message"].label == "No matching commands" }
        app.pressEscape()
        require(app, "Escape to close the palette") { !app.paletteField.exists }
    }

    @MainActor
    func testQuickOpenOpensAFileAndGoesToALine() throws {
        let app = try launchTide()
        app.press("p", .command)
        let field = focus(app, app.paletteField, "Quick Open")
        field.typeText("Note.swift")
        require(app, "Note.swift as the top match") { app.paletteRows.firstMatch.label.contains("Note.swift") }
        field.typeText("\n")
        require(app, "a tab for Note.swift") { app.element("tab-Note.swift").exists }
        require(app, "the editor to show Note.swift") { app.editor.stringValue.contains("TODO: support tags and pinning") }

        app.press("g", .control)
        focus(app, app.paletteField, "Go to Line").typeText("10\n")
        require(app, "the cursor on line 10") { app.statusPosition.label.hasPrefix("Ln 10,") }
        screenshot(app, "quick-open-go-to-line")
    }

    @MainActor
    func testTerminalRunsBuiltInCommands() throws {
        let app = try launchTide()
        app.press("`", .control)
        let terminal = app.element("terminal")
        focus(app, terminal, "the terminal").typeText("code notes/todo.md\n")
        require(app, "`code` to open notes/todo.md") { app.element("tab-todo.md").exists }

        focus(app, terminal, "the terminal").typeText("echo tidemarker42 > probe.txt\n")
        app.press("f", [.command, .shift])
        focus(app, app.textFields["search-search"], "the Search field").typeText("tidemarker42")
        require(app, "Search to find the file the shell wrote") { app.staticTexts["search-summary"].label == "1 result in 1 file" }
        XCTAssertTrue(app.buttons["search-match-probe.txt-0"].exists)
        screenshot(app, "terminal")

        focus(app, terminal, "the terminal").typeText("exit\n")
        require(app, "exit to close the last terminal") { app.staticTexts["No terminal"].exists }
    }

    @MainActor
    func testSearchFindsTextAcrossTheWorkspace() throws {
        let app = try launchTide()
        app.press("f", [.command, .shift])
        focus(app, app.textFields["search-search"], "the Search field").typeText("TODO")
        let summary = app.staticTexts["search-summary"]
        require(app, "three matches") { summary.label == "3 results in 3 files" }

        let matchCase = app.buttons["Match Case"]
        XCTAssertFalse(matchCase.isSelected)
        matchCase.tap()
        require(app, "Match Case to turn on") { matchCase.isSelected }
        require(app, "the lowercase match to drop out") { summary.label == "2 results in 2 files" }
        screenshot(app, "search")

        app.buttons["search-match-Sources/Models/Note.swift-9"].tap()
        require(app, "the match to open Note.swift") { app.element("tab-Note.swift").exists }
        require(app, "the cursor on the matching line") { app.statusPosition.label.hasPrefix("Ln 10,") }
    }

    @MainActor
    func testFindAndReplaceInTheEditor() throws {
        let app = try launchTide()
        app.press("f", .command)
        focus(app, app.textFields["find-find"], "the Find field").typeText("Tide")
        let summary = app.staticTexts["find-summary"]
        require(app, "three matches in README.md") { summary.label.hasSuffix("of 3") }

        app.press("f", [.command, .option])
        focus(app, app.textFields["find-replace"], "the Replace field").typeText("Tidal")
        app.buttons["Replace All"].tap()
        require(app, "every match to be replaced") { summary.label == "No results" }
        XCTAssertTrue(app.editor.stringValue.hasPrefix("# Welcome to Tidal"))
        XCTAssertEqual(app.buttons["Close README.md"].stringValue, "Unsaved changes")
        screenshot(app, "find-replace")
    }

    /// ⌘G is one of the editor's own key commands (no menu item carries it),
    /// so it works only if the text view forwards it to the editor.
    @MainActor
    func testFindNextFromTheEditorKeyboard() throws {
        let app = try launchTide()
        app.press("f", .command)
        focus(app, app.textFields["find-find"], "the Find field").typeText("Tide")
        let summary = app.staticTexts["find-summary"]
        require(app, "three matches in README.md") { summary.label.hasSuffix("of 3") }

        focus(app, app.editor, "the editor")
        let before = summary.label
        app.press("g", .command)
        require(app, "⌘G to move to another match") { summary.label != before && summary.label.hasSuffix("of 3") }
    }

    @MainActor
    func testSavingClearsTheUnsavedChangesMarker() throws {
        let app = try launchTide()
        app.press("n", .command)
        require(app, "a new untitled file") { app.element("tab-Untitled-1.txt").exists }
        focus(app, app.editor, "the editor").typeText("hello from tide")
        let close = app.buttons["Close Untitled-1.txt"]
        require(app, "the tab to show unsaved changes") { close.stringValue == "Unsaved changes" }
        screenshot(app, "unsaved")

        app.press("s", .command)
        require(app, "saving to clear the marker") { close.stringValue.isEmpty }
        app.press("f", [.command, .shift])
        focus(app, app.textFields["search-search"], "the Search field").typeText("hello from tide")
        require(app, "Search to find the saved text on disk") { app.staticTexts["search-summary"].label == "1 result in 1 file" }
    }

    @MainActor
    func testSettingsEditorChangesAndResetsASetting() throws {
        let app = try launchTide()
        app.press(",", .command)
        require(app, "the Settings tab") { app.element("tab-Settings").exists }
        focus(app, app.textFields["settings-search"], "the settings search").typeText("minimap")
        require(app, "the search to narrow the list") { app.staticTexts["1 Settings"].exists }

        let minimap = app.switches["Minimap"]
        require(app, "the Minimap switch") { minimap.exists }
        let before = minimap.stringValue
        minimap.tap()
        require(app, "the switch to flip") { minimap.stringValue != before }
        let reset = app.buttons["Reset"]
        require(app, "a Reset button for the changed setting") { reset.exists }
        screenshot(app, "settings")
        reset.tap()
        require(app, "Reset to restore the default") { minimap.stringValue == before && !reset.exists }
    }

    @MainActor
    func testColorThemePickerAppliesATheme() throws {
        let app = try launchTide()
        app.press("p", [.command, .shift])
        let palette = focus(app, app.paletteField, "the Command Palette")
        palette.typeText("color theme")
        require(app, "Preferences: Color Theme as the top match") { app.paletteRows.firstMatch.label.contains("Preferences: Color Theme") }
        palette.typeText("\n")
        require(app, "the theme picker") { app.staticTexts["Select Color Theme"].exists }
        focus(app, app.paletteField, "the theme picker").typeText("monokai")
        require(app, "Monokai as the top match") { app.paletteRows.firstMatch.label.contains("Monokai") }
        app.paletteField.typeText("\n")
        require(app, "the picker to close") { !app.paletteField.exists }
        screenshot(app, "monokai")

        // Reopened, the picker marks Monokai as the current theme.
        app.press("p", [.command, .shift])
        focus(app, app.paletteField, "the Command Palette").typeText("color theme\n")
        let current = app.paletteRows.matching(NSPredicate(format: "selected == true")).firstMatch
        require(app, "the current theme in the picker") { current.exists }
        XCTAssertTrue(current.label.contains("Monokai"))
        app.pressEscape()
    }

    @MainActor
    func testSplitEditorShowsTheSameFileTwice() throws {
        let app = try launchTide()
        app.press("\\", .command)
        require(app, "a second editor group") { app.editors.count == 2 }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "tab-README.md").count, 2)

        let right = app.editors.element(boundBy: 1)
        focus(app, right, "the right editor").typeText("split ")
        let left = app.editors.element(boundBy: 0)
        require(app, "the edit to show in both editors") { left.stringValue.contains("split ") && left.stringValue == right.stringValue }
        screenshot(app, "split-editor")
    }
}
