import Foundation

/// Semantic category of a token. Themes map each kind to a color and font
/// style, the way VS Code themes map TextMate scopes.
public enum TokenKind: UInt8, CaseIterable, Codable, Sendable {
    case plain
    case comment
    case string
    case escape
    case number
    /// Declaration and storage keywords: `let`, `func`, `class`, `var`.
    case keyword
    /// Control-flow keywords: `if`, `return`, `import`, `try`.
    case control
    case type
    case function
    case variable
    case property
    /// Language constants and constant-like names: `true`, `nil`, `MAX_SIZE`.
    case constant
    case operatorSymbol
    case punctuation
    /// Attributes and decorators: `@MainActor`, `@property`.
    case attribute
    /// Compiler directives: `#if`, `#include`.
    case preprocessor
    case regex
    /// Markup tag names (HTML, XML).
    case tag
    /// Markup attribute names.
    case attributeName
    /// CSS selectors.
    case selector
    case heading
    case emphasis
    case strong
    case link
    /// Inline and fenced code in Markdown.
    case code
    case quote
    case listMarker
    case inserted
    case deleted
    case invalid
}

/// A token within one line. Offsets are UTF-16 units from the start of the line.
public struct Token: Equatable, Sendable {
    public var start: Int
    public var length: Int
    public var kind: TokenKind

    public init(start: Int, length: Int, kind: TokenKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }

    public var end: Int { start + length }
}

/// Tokenizer state carried from the end of one line to the start of the next,
/// following VS Code's line-state tokenization model. When an edit leaves a
/// line's end state unchanged, the lines after it do not need re-tokenizing.
public indirect enum LineState: Hashable, Sendable {
    case root
    /// Inside a block comment; `depth` > 1 for nested comments (Swift, Rust).
    case blockComment(depth: Int)
    /// Inside a multi-line string opened by the language's string rule `rule`.
    case openString(rule: Int)
    /// Inside a Markdown fenced code block, with the embedded language's state.
    case markdownFence(fence: String, language: String, inner: LineState)
    /// Inside an HTML or XML comment.
    case markupComment
    /// Inside a start tag that spans lines; `quote` is the open attribute quote or 0.
    case markupTag(quote: UInt16)
    /// Inside `<script>` or `<style>`: the embedded language and its state.
    case markupEmbedded(tag: String, language: String, inner: LineState)
    /// CSS block nesting depth and whether a comment is open.
    case css(depth: Int, inComment: Bool)
}

/// Turns one line of text into tokens.
public protocol LineTokenizer: Sendable {
    /// Tokenizes `line` (UTF-16 units, without its terminator) starting in `state`.
    /// Tokens must be sorted, non-overlapping and within the line.
    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState)
}

/// Tokenizer for plain text: no tokens, no state.
public struct PlainTokenizer: LineTokenizer {
    public init() {}

    public func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        ([], .root)
    }
}
