import Foundation
import Testing
@testable import TideCore

struct FuzzyScorerTests {
    @Test func requiresCharactersInOrder() {
        #expect(FuzzyScorer.score("window.ts", query: "wts") != nil)
        #expect(FuzzyScorer.score("window.ts", query: "tsw") == nil)
        #expect(FuzzyScorer.score("abc", query: "abcd") == nil)
        #expect(FuzzyScorer.score("abc", query: "") == nil)
    }

    @Test func reportsMatchPositions() {
        let match = FuzzyScorer.score("WorkbenchView.swift", query: "wbv")
        #expect(match?.positions == [0, 4, 9])
        #expect(match?.ranges == [0..<1, 4..<5, 9..<10])
    }

    @Test func prefersWordStartsAndContiguousRuns() {
        let start = FuzzyScorer.score("editorGroup", query: "edit")!.score
        let middle = FuzzyScorer.score("creditor", query: "edit")!.score
        #expect(start > middle)
        // The camelCase bonus needs matching case, as in VS Code's own comment
        // ("NPE => NullPointerException = boost"); a lowercase "npe" prefers
        // the contiguous "pe" in "nonperishable".
        let camel = FuzzyScorer.score("NullPointerException", query: "NPE")!.score
        let flat = FuzzyScorer.score("nonperishable", query: "NPE")!.score
        #expect(camel > flat)
        #expect(FuzzyScorer.score("nonperishable", query: "npe")!.score > FuzzyScorer.score("NullPointerException", query: "npe")!.score)
    }

    @Test func labelPrefixMatchesOutrankPathMatches() {
        let file = FuzzyScorer.scoreItem(label: "window.ts", description: "src/vs", query: "window")!
        let longer = FuzzyScorer.scoreItem(label: "windowActions.ts", description: "src/vs", query: "window")!
        let pathOnly = FuzzyScorer.scoreItem(label: "actions.ts", description: "src/window", query: "window")!
        #expect(file.score > longer.score)
        #expect(longer.score > pathOnly.score)
        #expect(pathOnly.labelPositions.isEmpty)
        #expect(pathOnly.descriptionPositions == [4, 5, 6, 7, 8, 9])
    }

    @Test func exactPathIsIdentity() {
        let identity = FuzzyScorer.scoreItem(label: "main.swift", description: "Sources", query: "Sources/main.swift")!
        #expect(identity.score == FuzzyScorer.pathIdentityScore)
    }

    @Test func multiWordQueriesNeedEveryPiece() {
        #expect(FuzzyScorer.scoreItem(label: "TabBar.swift", description: "App/Editor", query: "editor tab") != nil)
        #expect(FuzzyScorer.scoreItem(label: "TabBar.swift", description: "App/Editor", query: "editor zzz") == nil)
    }
}

struct WordFilterTests {
    @Test func matchesWordStarts() {
        // A query space that equals the target's space is highlighted too
        // (VS Code only drops separators that differ, such as "-" vs " ").
        let ranges = WordFilter.matches("tog min", in: "View: Toggle Minimap")
        #expect(ranges == [6..<9, 12..<16])
        #expect(WordFilter.matches("tog-min", in: "View: Toggle Minimap") == [6..<9, 13..<16])
    }

    @Test func matchesSubstringsCaseAndAccentInsensitively() {
        #expect(WordFilter.matches("save", in: "File: Save As...") == [6..<10])
        #expect(WordFilter.matches("cafe", in: "Open Café") == [5..<9])
        #expect(WordFilter.matches("xyz", in: "File: Save") == nil)
        #expect(WordFilter.matches("  ", in: "anything") == [])
    }

    @Test func wordsMayBeSkipped() {
        // Whole words may be skipped, but letters inside a word may not:
        // VS Code's palette finds "com pal" but not "cmd pal".
        #expect(WordFilter.matches("com pal", in: "Show Command Palette") != nil)
        #expect(WordFilter.matches("cmd pal", in: "Show Command Palette") == nil)
        #expect(WordFilter.matches("fsave", in: "File: Save") == [0..<1, 6..<10])
    }
}

struct ThemeTests {
    @Test func parsesHexColors() {
        #expect(RGBAColor(hex: "#FFF") == RGBAColor(red: 1, green: 1, blue: 1))
        #expect(RGBAColor(hex: "#00000080")?.alpha == Double(0x80) / 255)
        #expect(RGBAColor(hex: "#1F1F1F")?.hexString == "#1F1F1F")
        #expect(RGBAColor(hex: "nope") == nil)
        #expect(RGBAColor(hex: "#12345") == nil)
    }

    @Test func builtinThemesResolveEveryKindAndKey() {
        for theme in BuiltinThemes.all {
            for kind in TokenKind.allCases {
                #expect(theme.style(for: kind).color != nil, "\(theme.name) has no color for \(kind)")
            }
            for key in ["editor.background", "sideBar.background", "statusBar.background", "tab.activeBackground", "quickInput.background", "terminal.ansiRed", "list.highlightForeground"] {
                _ = theme[key]
            }
        }
        #expect(BuiltinThemes.defaultDark.name == "Dark 2026")
        #expect(BuiltinThemes.theme(id: "Dark Modern")?.id == "dark-modern")
    }

    @Test func fallsBackThroughAliasesThenKindDefaults() {
        let theme = Theme(id: "t", name: "T", kind: .dark, colors: ["editor.background": RGBAColor(hex: "#101010")!], tokenStyles: [:])
        #expect(theme["tab.activeBackground"] == RGBAColor(hex: "#101010"))
        #expect(theme["editorError.foreground"] == RGBAColor(hex: "#F14C4C"))
        #expect(theme.style(for: .comment).color == theme["editor.foreground"])
    }
}

struct VSCodeThemeImporterTests {
    @Test func importsColorsAndResolvesScopes() throws {
        let json = """
        {
          // A VS Code theme file is JSONC.
          "name": "Test Night",
          "type": "dark",
          "colors": { "editor.background": "#000011", "activityBar.background": "#111122", },
          "tokenColors": [
            { "settings": { "foreground": "#EEEEEE" } },
            { "scope": "comment", "settings": { "foreground": "#777777", "fontStyle": "italic" } },
            { "scope": ["keyword", "storage.type"], "settings": { "foreground": "#FF0000" } },
            { "scope": "keyword.control", "settings": { "foreground": "#FF00FF" } },
            { "scope": "string, constant.character.escape", "settings": { "foreground": "#00FF00" } },
            { "scope": "entity.name.function", "settings": { "foreground": "#FFFF00", "fontStyle": "bold underline" } },
            { "scope": "source.js meta.object-literal.key", "settings": { "foreground": "#123456" } },
          ]
        }
        """
        let theme = try VSCodeThemeImporter.importTheme(from: json)
        #expect(theme.name == "Test Night")
        #expect(theme.kind == .dark)
        #expect(theme["editor.background"] == RGBAColor(hex: "#000011"))
        #expect(theme["editor.foreground"] == RGBAColor(hex: "#EEEEEE"))
        #expect(theme.style(for: .comment) == TokenStyle("#777777", italic: true))
        #expect(theme.style(for: .keyword).color == RGBAColor(hex: "#FF0000"))
        #expect(theme.style(for: .control).color == RGBAColor(hex: "#FF00FF"))
        #expect(theme.style(for: .escape).color == RGBAColor(hex: "#00FF00"))
        #expect(theme.style(for: .function) == TokenStyle("#FFFF00", bold: true, underline: true))
        #expect(theme.style(for: .property).color == RGBAColor(hex: "#123456"))
    }

    @Test func rejectsNonThemes() {
        #expect(throws: VSCodeThemeImporter.ImportError.notATheme) {
            try VSCodeThemeImporter.importTheme(from: #"{"editor.fontSize": 14}"#)
        }
    }
}

struct JSONCTests {
    @Test func stripsCommentsAndTrailingCommas() throws {
        let text = """
        {
          // line comment
          "a": "keep // this", /* block */
          "b": [1, 2, 3,],
          "c": { "d": "/* not a comment */", },
        }
        """
        let object = try JSONC.parseObject(text)
        #expect(object["a"] as? String == "keep // this")
        #expect((object["b"] as? [Int]) == [1, 2, 3])
        #expect((object["c"] as? [String: String])?["d"] == "/* not a comment */")
    }

    @Test func emptyDocumentIsAnEmptyObject() throws {
        #expect(try JSONC.parseObject("  // nothing\n").isEmpty)
        #expect(throws: JSONC.ParseError.self) { try JSONC.parseObject("[1, 2]") }
    }
}
