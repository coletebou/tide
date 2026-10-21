import Foundation
import Testing
@testable import TideCore

struct TokenizationCacheTests {
    /// After every random edit, the incrementally updated cache must equal a
    /// cache built from scratch. This exercises state propagation through
    /// block comments and multi-line strings in both directions.
    @Test(arguments: ["swift", "javascript", "python", "html", "markdown", "css"])
    func incrementalUpdatesMatchFullTokenization(languageID: String) {
        let language = LanguageRegistry.shared.language(id: languageID)!
        let tokenizer = LanguageRegistry.shared.tokenizer(for: language)
        var rng = SeededGenerator(seed: UInt64(languageID.utf8.reduce(7) { $0 &* 31 &+ UInt64($1) }))
        let pieces = ["let ", "x", " = ", "\"", "'", "`", "/*", "*/", "\n", "\"\"\"", "'''", "// c", "# h", "1", "{", "}",
                      "<!--", "-->", "<p>", "```", "```swift\n", "<script>", "</script>", "${", "(", ")", "  "]
        let text = NSMutableString(string: "let a = 1\n/* c */\nfunc f() {\n  \"s\"\n}\n")
        var index = LineIndex(text)
        let cache = TokenizationCache(tokenizer: tokenizer)
        cache.reset(text: text, lineIndex: index)

        for step in 0..<600 {
            let location = Int.random(in: 0...text.length, using: &rng)
            let length = Int.random(in: 0...min(5, text.length - location), using: &rng)
            let insertion = (0..<Int.random(in: 0...2, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            text.replaceCharacters(in: NSRange(location: location, length: length), with: insertion)
            let edit = index.applyEdit(oldRange: NSRange(location: location, length: length), replacementLength: (insertion as NSString).length, newText: text)
            cache.apply(edit, text: text, lineIndex: index)

            let fresh = TokenizationCache(tokenizer: tokenizer)
            fresh.reset(text: text, lineIndex: index)
            #expect(cache.lineTokens == fresh.lineTokens, "\(languageID) step \(step): tokens diverged")
            #expect(cache.endStates == fresh.endStates, "\(languageID) step \(step): states diverged")
            if cache.lineTokens != fresh.lineTokens || cache.endStates != fresh.endStates { return }
            if text.length > 600 {
                text.setString(text.substring(to: 200))
                index = LineIndex(text)
                cache.reset(text: text, lineIndex: index)
            }
        }
    }

    @Test func typingInsideAFunctionRetokenizesOneLine() {
        let tokenizer = LanguageRegistry.shared.tokenizer(forID: "swift")!
        let lines = (0..<500).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let text = NSMutableString(string: lines)
        var index = LineIndex(text)
        let cache = TokenizationCache(tokenizer: tokenizer)
        cache.reset(text: text, lineIndex: index)

        let location = index.lineStarts[250] + 3
        text.replaceCharacters(in: NSRange(location: location, length: 0), with: "x")
        let edit = index.applyEdit(oldRange: NSRange(location: location, length: 0), replacementLength: 1, newText: text)
        let changed = cache.apply(edit, text: text, lineIndex: index)
        #expect(changed.count <= 2)

        // Opening a block comment re-colors everything below it.
        let start = index.lineStarts[100]
        text.replaceCharacters(in: NSRange(location: start, length: 0), with: "/*")
        let commentEdit = index.applyEdit(oldRange: NSRange(location: start, length: 0), replacementLength: 2, newText: text)
        let recolored = cache.apply(commentEdit, text: text, lineIndex: index)
        #expect(recolored.upperBound == index.lineCount)
        #expect(cache.tokens(forLine: 400).allSatisfy { $0.kind == .comment })
    }

    @Test func kindAtOffset() {
        let tokenizer = LanguageRegistry.shared.tokenizer(forID: "swift")!
        let text = "let s = \"hi\" // c" as NSString
        let index = LineIndex(text)
        let cache = TokenizationCache(tokenizer: tokenizer)
        cache.reset(text: text, lineIndex: index)
        #expect(cache.kind(at: 1, lineIndex: index) == .keyword)
        #expect(cache.kind(at: 9, lineIndex: index) == .string)
        #expect(cache.kind(at: 3, lineIndex: index) == .plain)
        #expect(cache.kind(at: 15, lineIndex: index) == .comment)
    }
}
