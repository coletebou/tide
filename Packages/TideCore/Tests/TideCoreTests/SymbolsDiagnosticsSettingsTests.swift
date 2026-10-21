import Foundation
import Testing
@testable import TideCore

private func language(_ id: String) -> LanguageDefinition { LanguageRegistry.shared.language(id: id)! }

struct DocumentSymbolTests {
    @Test func swiftTypesAndMembers() {
        let text = """
        import SwiftUI

        @MainActor
        final class Workbench: ObservableObject {
            var title = "Tide"
            let id: UUID

            init(id: UUID) {
                let local = 1
                self.id = id
            }

            func open(_ path: String) {
                let ignored = "{"
            }
        }

        struct Point { var x: Double }
        enum Mode { case light, dark }
        func freeFunction() {}
        """
        let symbols = DocumentSymbols.extract(from: text, language: language("swift"))
        #expect(symbols.map(\.name) == ["Workbench", "Point", "Mode", "freeFunction"])
        #expect(symbols[0].kind == .class)
        #expect(symbols[0].children.map(\.name) == ["title", "id", "init", "open"])
        #expect(symbols[0].children.map(\.kind) == [.property, .constant, .constructor, .method])
        #expect(symbols[0].line == 3)
        #expect(symbols[0].endLine == 15)
        #expect(symbols[1].kind == .struct)
        #expect(symbols[2].kind == .enum)
    }

    @Test func pythonUsesIndentation() {
        let text = "class Shape:\n    def area(self):\n        return 0\n\n    def name(self):\n        pass\n\ndef main():\n    pass\n"
        let symbols = DocumentSymbols.extract(from: text, language: language("python"))
        #expect(symbols.map(\.name) == ["Shape", "main"])
        #expect(symbols[0].children.map(\.name) == ["area", "name"])
        #expect(symbols[0].endLine == 5)
    }

    @Test func javascriptFunctionsClassesAndArrows() {
        let text = "export class Store {\n  get items() {\n    return []\n  }\n}\nexport function load() {}\nconst save = async (x) => x\n"
        let symbols = DocumentSymbols.extract(from: text, language: language("javascript"))
        #expect(symbols.map(\.name) == ["Store", "load", "save"])
        #expect(symbols[0].children.map(\.name) == ["items"])
    }

    @Test func markdownHeadingsNest() {
        let text = "# Title\nintro\n## Install\n```\n# not a heading\n```\n## Usage\n### Flags\n# Appendix\n"
        let symbols = DocumentSymbols.extract(from: text, language: language("markdown"))
        #expect(symbols.map(\.name) == ["Title", "Appendix"])
        #expect(symbols[0].children.map(\.name) == ["Install", "Usage"])
        #expect(symbols[0].children[1].children.map(\.name) == ["Flags"])
        #expect(symbols.flatMap(\.flattened).count == 5)
    }

    @Test func dataAndStyleSymbols() {
        #expect(DocumentSymbols.extract(from: "{\n  \"name\": \"tide\",\n  \"scripts\": { \"build\": \"x\" }\n}", language: language("json")).map(\.name) == ["name", "scripts"])
        #expect(DocumentSymbols.extract(from: "name: tide\nsteps:\n  - run: x\n", language: language("yaml")).map(\.name) == ["name", "steps"])
        #expect(DocumentSymbols.extract(from: ".btn {\n}\n@media (x) {\n}\n", language: language("css")).map(\.name) == [".btn", "@media (x)"])
    }

    @Test func goRustAndKotlin() {
        #expect(DocumentSymbols.extract(from: "type Server struct {\n}\nfunc (s *Server) Start() {\n}\nfunc main() {}\n", language: language("go")).map(\.name) == ["Server", "Start", "main"])
        let rust = DocumentSymbols.extract(from: "pub struct Config {\n}\nimpl Config {\n    pub fn new() -> Self {\n    }\n}\nfn main() {}\n", language: language("rust"))
        #expect(rust.map(\.name) == ["Config", "Config", "main"])
        #expect(rust[1].children.map(\.name) == ["new"])
        #expect(DocumentSymbols.extract(from: "data class User(val name: String)\nfun greet() {}\n", language: language("kotlin")).map(\.name) == ["User", "greet"])
    }
}

struct DiagnosticsTests {
    @Test func validJSONHasNoProblems() {
        #expect(Diagnostics.validateJSON(#"{"a": [1, 2.5e3, -0.1, true, null, {"b": "é\n"}]}"#, allowComments: false).isEmpty)
        #expect(Diagnostics.validateJSON("", allowComments: false).isEmpty)
    }

    @Test func reportsJSONErrorsWithPositions() {
        let missingComma = Diagnostics.validateJSON("{\n  \"a\": 1\n  \"b\": 2\n}", allowComments: false)
        #expect(missingComma.first?.message == "Comma expected.")
        #expect(missingComma.first?.line == 2)
        #expect(missingComma.first?.column == 2)
        #expect(Diagnostics.validateJSON("{\"a\" 1}", allowComments: false).first?.message == "Colon expected.")
        #expect(Diagnostics.validateJSON("[1, 2", allowComments: false).first?.message == "Closing bracket expected.")
        #expect(Diagnostics.validateJSON("{\"a\": }", allowComments: false).first?.message == "Value expected.")
        #expect(Diagnostics.validateJSON("{} x", allowComments: false).first?.message == "End of file expected.")
        #expect(Diagnostics.validateJSON("{\"a\": \"unterminated}", allowComments: false).first?.message == "Unexpected end of string.")
        #expect(Diagnostics.validateJSON("{\"a\": 01}", allowComments: false).first?.message == "Comma expected.")
    }

    @Test func commentsAndTrailingCommasDependOnFlavor() {
        let jsonc = "{\n  // comment\n  \"a\": 1,\n}"
        #expect(Diagnostics.validateJSON(jsonc, allowComments: false).map(\.message) == ["Comments are not permitted in JSON."])
        let lenient = Diagnostics.validateJSON(jsonc, allowComments: true)
        #expect(lenient.map(\.message) == ["Trailing comma"])
        #expect(lenient.first?.severity == .warning)
        #expect(Diagnostics.analyze(jsonc, language: language("json"), fileName: "settings.json").allSatisfy { $0.severity == .warning })
    }

    @Test func warnsAboutDuplicateKeys() {
        let problems = Diagnostics.validateJSON(#"{"a": 1, "a": 2}"#, allowComments: false)
        #expect(problems.map(\.message) == ["Duplicate object key"])
        #expect(problems.first?.severity == .warning)
    }

    @Test func bracketBalance() {
        #expect(Diagnostics.analyze("func f() { print(\")\") }", language: language("swift")).isEmpty)
        let unexpected = Diagnostics.analyze("let a = [1, 2)]", language: language("swift"))
        #expect(unexpected.first?.message == "Unexpected ')'.")
        let unclosed = Diagnostics.analyze("func f() {\n  if x {\n}", language: language("swift"))
        #expect(unclosed.map(\.message) == ["'{' was not closed."])
        #expect(unclosed.first?.line == 0)
    }
}

struct SettingsTests {
    @Test func defaultsComeFromTheRegistry() {
        let store = SettingsStore()
        #expect(store.number("editor.fontSize") == 14)
        #expect(store.bool("editor.minimap.enabled"))
        #expect(store.string("workbench.colorTheme") == "Dark 2026")
        #expect(store.globs("files.exclude").contains("**/.git"))
        #expect(!store.isModified("editor.fontSize"))
    }

    @Test func parsesAndWritesSettingsJSON() {
        let text = """
        {
            // Bigger text on the iPad
            "editor.fontSize": 16,
            "editor.minimap.enabled": false,
            "workbench.colorTheme": "Monokai",
            "editor.tabSize": "four",
            "my.extension.flag": [1, 2],
        }
        """
        let (store, problems) = SettingsStore.parse(text)
        #expect(store.number("editor.fontSize") == 16)
        #expect(store.bool("editor.minimap.enabled") == false)
        #expect(store.string("workbench.colorTheme") == "Monokai")
        #expect(store.number("editor.tabSize") == 4)
        #expect(problems == ["Incorrect type for 'editor.tabSize'."])
        let json = store.json()
        #expect(json.contains("    \"editor.fontSize\" : 16"))
        #expect(json.contains("\"my.extension.flag\""))
        let (reparsed, _) = SettingsStore.parse(json)
        #expect(reparsed == store)
    }

    /// A number outside the setting's range is reported and ignored, like a
    /// value of the wrong type; huge ones would otherwise trap in `int(_:)`.
    @Test func outOfRangeNumbersKeepTheDefault() {
        let (store, problems) = SettingsStore.parse(#"{"editor.tabSize": 1e100, "editor.fontSize": -3, "files.autoSaveDelay": 2000}"#)
        #expect(store.number("editor.tabSize") == 4)
        #expect(store.number("editor.fontSize") == 14)
        #expect(store.int("files.autoSaveDelay") == 2000)
        #expect(Set(problems) == ["'editor.tabSize' must be between 1 and 8.", "'editor.fontSize' must be between 8 and 36."])
    }

    #if os(macOS)
    @Test func hugeNumbersDoNotCrashIntegerReads() async {
        await #expect(processExitsWith: .success) {
            _ = SettingsStore.parse(#"{"editor.tabSize": 1e100}"#).store.int("editor.tabSize")
        }
    }
    #endif

    @Test func settingTheDefaultRemovesTheOverride() {
        var store = SettingsStore()
        store.set("editor.fontSize", .number(18))
        #expect(store.isModified("editor.fontSize"))
        store.set("editor.fontSize", .number(14))
        #expect(!store.isModified("editor.fontSize"))
        #expect(store.json() == "{\n}\n")
    }

    @Test func defaultSettingsListingIsValidJSONC() throws {
        let listing = SettingsStore.defaultSettingsJSON()
        let object = try JSONC.parseObject(listing)
        #expect(object.count == SettingsRegistry.descriptors.count)
    }
}
