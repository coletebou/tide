import Foundation
@testable import TideCore

/// Deterministic random numbers for reproducible randomized tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Tokenizes one line of `language` and returns (text, kind) pairs.
func tokens(_ languageID: String, _ line: String, state: LineState = .root) -> [(String, TokenKind)] {
    let language = LanguageRegistry.shared.language(id: languageID)!
    let tokenizer = LanguageRegistry.shared.tokenizer(for: language)
    let units = Array(line.utf16)
    return tokenizer.tokenize(units, state: state).tokens.map { token in
        (String(decoding: units[token.start..<token.end], as: UTF16.self), token.kind)
    }
}

/// The kind of the first token whose text equals `text`.
func kind(of text: String, in pairs: [(String, TokenKind)]) -> TokenKind? {
    pairs.first { $0.0 == text }?.1
}

/// Tokenizes a multi-line text and returns (text, kind) pairs per line.
func tokenizeLines(_ languageID: String, _ text: String) -> [[(String, TokenKind)]] {
    let language = LanguageRegistry.shared.language(id: languageID)!
    let tokenizer = LanguageRegistry.shared.tokenizer(for: language)
    let nsText = text as NSString
    let index = LineIndex(nsText)
    let cache = TokenizationCache(tokenizer: tokenizer)
    cache.reset(text: nsText, lineIndex: index)
    return (0..<index.lineCount).map { line in
        let range = index.contentRange(ofLine: line, in: nsText)
        let lineText = nsText.substring(with: range) as NSString
        return cache.tokens(forLine: line).map { token in
            (lineText.substring(with: NSRange(location: token.start, length: token.length)), token.kind)
        }
    }
}
