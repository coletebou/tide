import Foundation
import Testing
@testable import TideCore

struct TokenizerTests {
    @Test func swiftDeclarationsAndLiterals() {
        let pairs = tokens("swift", "let answer = 42 // the answer")
        #expect(kind(of: "let", in: pairs) == .keyword)
        #expect(kind(of: "answer", in: pairs) == .variable)
        #expect(kind(of: "=", in: pairs) == .operatorSymbol)
        #expect(kind(of: "42", in: pairs) == .number)
        #expect(kind(of: "// the answer", in: pairs) == .comment)
    }

    @Test func swiftFunctionAndTypes() {
        let pairs = tokens("swift", "@MainActor func greet(name: String) -> String { return name }")
        #expect(kind(of: "@MainActor", in: pairs) == .attribute)
        #expect(kind(of: "func", in: pairs) == .keyword)
        #expect(kind(of: "greet", in: pairs) == .function)
        #expect(kind(of: "String", in: pairs) == .type)
        #expect(kind(of: "return", in: pairs) == .control)
    }

    @Test func swiftStringInterpolation() {
        let pairs = tokens("swift", #"print("Hi \(name)!\n")"#)
        #expect(pairs.map(\.0) == ["print", "(", "\"Hi ", "\\(", "name", ")", "!", "\\n", "\"", ")"])
        #expect(pairs.map(\.1) == [.function, .punctuation, .string, .keyword, .variable, .keyword, .string, .escape, .string, .punctuation])
    }

    @Test func swiftDirectivesAndConstants() {
        let pairs = tokens("swift", "#if DEBUG && self.isEnabled == nil")
        #expect(kind(of: "#if", in: pairs) == .preprocessor)
        #expect(kind(of: "DEBUG", in: pairs) == .constant)
        #expect(kind(of: "self", in: pairs) == .constant)
        #expect(kind(of: "isEnabled", in: pairs) == .property)
        #expect(kind(of: "nil", in: pairs) == .constant)
    }

    @Test func blockCommentsCarryAcrossLines() {
        let lines = tokenizeLines("swift", "let a = 1 /* start\nstill comment\nend */ let b")
        #expect(lines[0].last?.1 == .comment)
        #expect(lines[1].map(\.1) == [.comment])
        #expect(lines[2].first?.0 == "end */")
        #expect(lines[2].first?.1 == .comment)
        #expect(kind(of: "let", in: lines[2]) == .keyword)
    }

    @Test func swiftNestedCommentsNeedEveryClose() {
        let lines = tokenizeLines("swift", "/* outer /* inner */ still\n*/ let x")
        #expect(lines[0].map(\.1) == [.comment])
        #expect(kind(of: "let", in: lines[1]) == .keyword)
    }

    @Test func multilineStringsCarryAcrossLines() {
        let lines = tokenizeLines("swift", "let s = \"\"\"\n  let not = code\n  \"\"\"\nlet x")
        #expect(lines[1].map(\.1) == [.string])
        #expect(lines[2].map(\.1) == [.string])
        #expect(kind(of: "let", in: lines[3]) == .keyword)
    }

    @Test func pythonDecoratorsPrefixesAndBuiltins() {
        #expect(kind(of: "@dataclass", in: tokens("python", "@dataclass")) == .function)
        let def = tokens("python", "def area(r: float) -> float:")
        #expect(kind(of: "def", in: def) == .keyword)
        #expect(kind(of: "area", in: def) == .function)
        #expect(kind(of: "float", in: def) == .type)
        let fString = tokens("python", "print(f\"r={r}\")  # done")
        #expect(kind(of: "print", in: fString) == .function)
        #expect(kind(of: "f\"r={r}\"", in: fString) == .string)
        #expect(kind(of: "# done", in: fString) == .comment)
        #expect(kind(of: "None", in: tokens("python", "x = None")) == .constant)
    }

    @Test func javascriptRegexVersusDivision() {
        #expect(kind(of: "/ab+c/gi", in: tokens("javascript", "const re = /ab+c/gi;")) == .regex)
        let division = tokens("javascript", "const half = total / 2 / count;")
        #expect(!division.contains { $0.1 == .regex })
        #expect(kind(of: "/[/]x/", in: tokens("javascript", "if (/[/]x/.test(s)) {}")) == .regex)
    }

    @Test func javascriptTemplateLiteralSpansLines() {
        let lines = tokenizeLines("javascript", "const t = `a ${b}\nc`;\nlet d")
        #expect(kind(of: "${", in: lines[0]) == .keyword)
        #expect(kind(of: "b", in: lines[0]) == .variable)
        #expect(lines[1].first?.1 == .string)
        #expect(kind(of: "let", in: lines[2]) == .keyword)
    }

    @Test func jsonKeysAreProperties() {
        let pairs = tokens("json", #"{"name": "tide", "count": 2, "ok": true, "none": null}"#)
        #expect(kind(of: "\"name\"", in: pairs) == .property)
        #expect(kind(of: "\"tide\"", in: pairs) == .string)
        #expect(kind(of: "2", in: pairs) == .number)
        #expect(kind(of: "true", in: pairs) == .constant)
        #expect(kind(of: "null", in: pairs) == .constant)
    }

    @Test func rustLifetimesMacrosAndAttributes() {
        let pairs = tokens("rust", "fn first<'a>(x: &'a str) -> char { println!(\"{}\", x); 'z' }")
        #expect(kind(of: "fn", in: pairs) == .keyword)
        #expect(kind(of: "first", in: pairs) == .function)
        #expect(kind(of: "'a", in: pairs) == .keyword)
        #expect(kind(of: "println!", in: pairs) == .function)
        #expect(kind(of: "'z'", in: pairs) == .string)
        #expect(kind(of: "#[derive(Debug, Clone)]", in: tokens("rust", "#[derive(Debug, Clone)]")) == .attribute)
    }

    @Test func cPreprocessorIncludes() {
        let pairs = tokens("c", "#include <stdio.h>")
        #expect(kind(of: "#include", in: pairs) == .preprocessor)
        #expect(kind(of: "<stdio.h>", in: pairs) == .string)
        #expect(!tokens("c", "x = a #b").contains { $0.1 == .preprocessor })
    }

    @Test func shellVariablesAndBuiltins() {
        let pairs = tokens("shellscript", "echo \"home is $HOME\" ${USER} # note")
        #expect(kind(of: "echo", in: pairs) == .function)
        #expect(kind(of: "$HOME", in: pairs) == .variable)
        #expect(kind(of: "${USER}", in: pairs) == .variable)
        #expect(kind(of: "# note", in: pairs) == .comment)
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        let pairs = tokens("sql", "SELECT name FROM users WHERE id = 1 -- by id")
        #expect(kind(of: "SELECT", in: pairs) == .keyword)
        #expect(kind(of: "FROM", in: pairs) == .keyword)
        #expect(kind(of: "-- by id", in: pairs) == .comment)
    }

    @Test func markdownBlocksAndInlines() {
        #expect(tokens("markdown", "## Getting started").map(\.1) == [.heading])
        let item = tokens("markdown", "- Use `tide` and **bold** or *em* [docs](https://x.y)")
        #expect(kind(of: "-", in: item) == .listMarker)
        #expect(kind(of: "`tide`", in: item) == .code)
        #expect(kind(of: "**bold**", in: item) == .strong)
        #expect(kind(of: "*em*", in: item) == .emphasis)
        #expect(kind(of: "[docs]", in: item) == .link)
        #expect(tokens("markdown", "> quoted").map(\.1) == [.quote])
    }

    @Test func markdownFencedCodeUsesEmbeddedLanguage() {
        let lines = tokenizeLines("markdown", "```swift\nlet x = 1\n```\nplain *text*")
        #expect(lines[0].first?.1 == .punctuation)
        #expect(kind(of: "let", in: lines[1]) == .keyword)
        #expect(kind(of: "1", in: lines[1]) == .number)
        #expect(lines[2].map(\.1) == [.punctuation])
        #expect(kind(of: "*text*", in: lines[3]) == .emphasis)
    }

    @Test func htmlTagsAttributesAndEntities() {
        let pairs = tokens("html", #"<a href="/x" class='y'>Hi &amp; bye</a>"#)
        #expect(kind(of: "a", in: pairs) == .tag)
        #expect(kind(of: "href", in: pairs) == .attributeName)
        #expect(kind(of: "\"/x\"", in: pairs) == .string)
        #expect(kind(of: "&amp;", in: pairs) == .constant)
        #expect(kind(of: "</", in: pairs) == .punctuation)
    }

    @Test func htmlEmbedsScriptAndStyle() {
        let lines = tokenizeLines("html", "<script>\nconst a = 1;\n</script>\n<style>p { color: red; }</style>")
        #expect(kind(of: "const", in: lines[1]) == .keyword)
        #expect(kind(of: "script", in: lines[2]) == .tag)
        #expect(kind(of: "color", in: lines[3]) == .property)
    }

    @Test func htmlCommentsSpanLines() {
        let lines = tokenizeLines("html", "<!-- one\ntwo -->\n<p>")
        #expect(lines[1].first?.1 == .comment)
        #expect(kind(of: "p", in: lines[2]) == .tag)
    }

    @Test func cssSelectorsPropertiesAndValues() {
        let pairs = tokens("css", ".button:hover > span { color: #fff; margin: 0 4px !important; width: calc(100% - 2em); }")
        #expect(kind(of: ".button:hover", in: pairs) == .selector)
        #expect(kind(of: "color", in: pairs) == .property)
        #expect(kind(of: "#fff", in: pairs) == .number)
        #expect(kind(of: "4px", in: pairs) == .number)
        #expect(kind(of: "!important", in: pairs) == .keyword)
        #expect(kind(of: "calc", in: pairs) == .function)
    }

    @Test func yamlKeysScalarsAndComments() {
        let pairs = tokens("yaml", "  - name: tide # app")
        #expect(kind(of: "-", in: pairs) == .listMarker)
        #expect(kind(of: "name", in: pairs) == .tag)
        #expect(kind(of: "tide", in: pairs) == .string)
        #expect(kind(of: "# app", in: pairs) == .comment)
        #expect(kind(of: "true", in: tokens("yaml", "enabled: true")) == .constant)
        #expect(kind(of: "3", in: tokens("yaml", "retries: 3")) == .number)
    }

    @Test func iniSectionsAndKeys() {
        #expect(tokens("toml", "[package]").map(\.1) == [.type])
        let pairs = tokens("toml", "name = \"tide\" # comment")
        #expect(kind(of: "name", in: pairs) == .property)
        #expect(kind(of: "\"tide\"", in: pairs) == .string)
    }

    @Test func diffLines() {
        #expect(tokens("diff", "+added").map(\.1) == [.inserted])
        #expect(tokens("diff", "-removed").map(\.1) == [.deleted])
        #expect(tokens("diff", "@@ -1,2 +1,3 @@").map(\.1) == [.control])
    }

    @Test func tokensAreSortedAndInBounds() {
        let samples = [
            ("swift", "struct A<T>: B where T: C { var x = [1, 2.5e3, 0xFF] ; func f() async throws -> T? { try await g(\"\\u{1F600}\") } }"),
            ("javascript", "export default async function* gen(a = /x/, b = `t${`n${1}`}`) { yield a ?? b?.c }"),
            ("python", "lambda x: [y for y in range(10) if y % 2 == 0]  # '''"),
            ("html", "<input type=text disabled /><!-- a --><b>c</b>"),
            ("markdown", "1. **a** `b` _c_ ![d](e) <span>f</span>"),
        ]
        for (language, line) in samples {
            let tokenizer = LanguageRegistry.shared.tokenizer(for: LanguageRegistry.shared.language(id: language)!)
            let units = Array(line.utf16)
            let result = tokenizer.tokenize(units, state: .root).tokens
            var lastEnd = 0
            for token in result {
                #expect(token.start >= lastEnd, "\(language): overlapping token \(token)")
                #expect(token.length > 0)
                #expect(token.end <= units.count)
                lastEnd = token.end
            }
        }
    }
}

struct LanguageDetectionTests {
    let registry = LanguageRegistry.shared

    @Test func detectsByExtensionFileNameAndShebang() {
        #expect(registry.language(forFileName: "main.swift").id == "swift")
        #expect(registry.language(forFileName: "App.TSX").id == "typescript")
        #expect(registry.language(forFileName: "Makefile").id == "makefile")
        #expect(registry.language(forFileName: "Dockerfile").id == "dockerfile")
        #expect(registry.language(forFileName: ".gitignore").id == "ignore")
        #expect(registry.language(forFileName: "README.md").id == "markdown")
        #expect(registry.language(forFileName: ".zshrc").id == "shellscript")
        #expect(registry.language(forFileName: "deploy", firstLine: "#!/usr/bin/env python3").id == "python")
        #expect(registry.language(forFileName: "run", firstLine: "#!/bin/bash -e").id == "shellscript")
        #expect(registry.language(forFileName: "notes.unknownext").id == "plaintext")
    }

    @Test func everyLanguageHasATokenizer() {
        for language in registry.languages {
            _ = registry.tokenizer(for: language).tokenize(Array("x = 1 // y".utf16), state: .root)
        }
        #expect(registry.languages.count >= 30)
    }
}
