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
        press(app, "p", [.command, .shift], opening: "the Command Palette") { app.paletteField.exists }
        let field = focus(app, app.paletteField, "the Command Palette")
        XCTAssertEqual(field.stringValue, ">")
        // The list is lazy, so only the rows on screen exist.
        require(app, "the palette to list the commands") { app.paletteRows.count >= 10 }
        field.typeText("toggle terminal")
        require(app, "View: Toggle Terminal as the top match") { app.paletteRows.firstMatch.label.contains("View: Toggle Terminal") }
        screenshot(app, "command-palette")
        field.typeText("\n")
        require(app, "the palette to close") { !app.paletteField.exists }
        require(app, "the terminal to open") { app.element("terminal").exists }

        press(app, "p", [.command, .shift], opening: "the Command Palette") { app.paletteField.exists }
        focus(app, app.paletteField, "the Command Palette").typeText("zzqx")
        require(app, "the empty-result message") { app.staticTexts["quick-input-message"].label == "No matching commands" }
        // A tap outside closes the palette, as on a touch screen. Escape is not
        // checked: XCTest detaches the simulator's hardware keyboard during UI
        // tests, and key commands such as the palette's Escape need one.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        require(app, "a tap outside to close the palette") { !app.paletteField.exists }
    }

    @MainActor
    func testQuickOpenOpensAFileAndGoesToALine() throws {
        let app = try launchTide()
        press(app, "p", .command, opening: "Quick Open") { app.paletteField.exists }
        let field = focus(app, app.paletteField, "Quick Open")
        field.typeText("Note.swift")
        require(app, "Note.swift as the top match") { app.paletteRows.firstMatch.label.contains("Note.swift") }
        field.typeText("\n")
        require(app, "a tab for Note.swift") { app.element("tab-Note.swift").exists }
        require(app, "the editor to show Note.swift") { app.editor.stringValue.contains("TODO: support tags and pinning") }

        press(app, "g", .control, opening: "Go to Line") { app.paletteField.exists }
        focus(app, app.paletteField, "Go to Line").typeText("10\n")
        require(app, "the cursor on line 10") { app.statusPosition.label.hasPrefix("Ln 10,") }
        screenshot(app, "quick-open-go-to-line")
    }

    @MainActor
    func testTerminalRunsBuiltInCommands() throws {
        let app = try launchTide()
        let terminal = app.element("terminal")
        press(app, "`", .control, opening: "the terminal") { terminal.exists }
        focus(app, terminal, "the terminal").typeText("code notes/todo.md\n")
        require(app, "`code` to open notes/todo.md") { app.element("tab-todo.md").exists }

        focus(app, terminal, "the terminal").typeText("echo tidemarker42 > probe.txt\n")
        let search = app.textFields["search-search"]
        press(app, "f", [.command, .shift], opening: "the Search view") { search.exists }
        focus(app, search, "the Search field").typeText("tidemarker42")
        require(app, "Search to find the file the shell wrote") { app.staticTexts["search-summary"].label == "1 result in 1 file" }
        XCTAssertTrue(app.buttons["search-match-probe.txt-0"].exists)
        screenshot(app, "terminal")

        focus(app, terminal, "the terminal").typeText("exit\n")
        require(app, "exit to close the last terminal") { app.staticTexts["No terminal"].exists }
    }

    @MainActor
    func testSearchFindsTextAcrossTheWorkspace() throws {
        let app = try launchTide()
        let search = app.textFields["search-search"]
        press(app, "f", [.command, .shift], opening: "the Search view") { search.exists }
        focus(app, search, "the Search field").typeText("TODO")
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
        let find = app.textFields["find-find"]
        press(app, "f", .command, opening: "the Find widget") { find.exists }
        focus(app, find, "the Find field").typeText("Tide")
        let summary = app.staticTexts["find-summary"]
        require(app, "three matches in README.md") { summary.label.hasSuffix("of 3") }

        let replace = app.textFields["find-replace"]
        press(app, "f", [.command, .option], opening: "the Replace field") { replace.exists }
        focus(app, replace, "the Replace field").typeText("Tidal")
        app.buttons["Replace All"].tap()
        require(app, "every match to be replaced") { summary.label == "No results" }
        XCTAssertTrue(app.editor.stringValue.hasPrefix("# Welcome to Tidal"))
        XCTAssertEqual(app.buttons["Close README.md"].stringValue, "Unsaved changes")
        screenshot(app, "find-replace")
    }

    @MainActor
    func testFindNextAndPreviousMoveBetweenMatches() throws {
        let app = try launchTide()
        let find = app.textFields["find-find"]
        press(app, "f", .command, opening: "the Find widget") { find.exists }
        focus(app, find, "the Find field").typeText("Tide")
        let summary = app.staticTexts["find-summary"]
        require(app, "three matches in README.md") { summary.label.hasSuffix("of 3") }

        let first = summary.label
        app.typeKey("g", modifierFlags: .command)
        require(app, "⌘G to move to the next match") { summary.label != first && summary.label.hasSuffix("of 3") }
        app.typeKey("g", modifierFlags: [.command, .shift])
        require(app, "⇧⌘G to move back") { summary.label == first }
    }

    @MainActor
    func testSavingClearsTheUnsavedChangesMarker() throws {
        let app = try launchTide()
        press(app, "n", .command, opening: "a new untitled file") { app.element("tab-Untitled-1.txt").exists }
        focus(app, app.editor, "the editor").typeText("hello from tide")
        let close = app.buttons["Close Untitled-1.txt"]
        require(app, "the tab to show unsaved changes") { close.stringValue == "Unsaved changes" }
        screenshot(app, "unsaved")

        app.typeKey("s", modifierFlags: .command)
        require(app, "saving to clear the marker") { close.stringValue.isEmpty }
        let search = app.textFields["search-search"]
        press(app, "f", [.command, .shift], opening: "the Search view") { search.exists }
        focus(app, search, "the Search field").typeText("hello from tide")
        require(app, "Search to find the saved text on disk") { app.staticTexts["search-summary"].label == "1 result in 1 file" }
    }

    @MainActor
    func testSettingsEditorChangesAndResetsASetting() throws {
        let app = try launchTide()
        press(app, ",", .command, opening: "the Settings editor") { app.element("tab-Settings").exists }
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
        press(app, "p", [.command, .shift], opening: "the Command Palette") { app.paletteField.exists }
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
        press(app, "p", [.command, .shift], opening: "the Command Palette") { app.paletteField.exists }
        focus(app, app.paletteField, "the Command Palette").typeText("color theme\n")
        let current = app.paletteRows.matching(NSPredicate(format: "selected == true")).firstMatch
        require(app, "the current theme in the picker") { current.exists }
        XCTAssertTrue(current.label.contains("Monokai"))
    }

    @MainActor
    func testSplitEditorShowsTheSameFileTwice() throws {
        let app = try launchTide()
        press(app, "\\", .command, opening: "a second editor group") { app.editors.count == 2 }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "tab-README.md").count, 2)

        let right = app.editors.element(boundBy: 1)
        focus(app, right, "the right editor").typeText("split ")
        let left = app.editors.element(boundBy: 0)
        require(app, "the edit to show in both editors") { left.stringValue.contains("split ") && left.stringValue == right.stringValue }
        screenshot(app, "split-editor")
    }
}
