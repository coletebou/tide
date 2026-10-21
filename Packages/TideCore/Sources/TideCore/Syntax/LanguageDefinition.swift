import Foundation

/// How a string literal opens, closes and escapes.
public struct StringRule: Hashable, Sendable {
    public var open: String
    public var close: String
    /// Escape character, or nil for raw strings.
    public var escape: String? = "\\"
    /// Whether the string may span lines.
    public var multiline = false
    /// Opening delimiter of an interpolated expression, such as `\(` or `${`.
    public var interpolationOpen: String?
    /// Whether `$name` inside the string is a variable (shell, Kotlin).
    public var dollarVariables = false
}

/// Which tokenizer implementation a language uses.
public enum TokenizerStyle: Hashable, Sendable {
    case cLike
    case markdown
    case html
    case xml
    case css
    case yaml
    case ini
    case diff
    case plain
}

/// A bracket pair, used for matching, auto-closing and indentation.
public struct BracketPair: Hashable, Sendable {
    public var open: String
    public var close: String

    public init(_ open: String, _ close: String) {
        self.open = open
        self.close = close
    }
}

/// Everything Tide knows about one language: detection, tokenizing rules and
/// editing behavior (comments, brackets, indentation). The C-like tokenizer is
/// driven entirely by these fields, so most languages are pure data.
public struct LanguageDefinition: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    var extensions: [String] = []
    var fileNames: [String] = []
    /// Interpreter names matched against a `#!` first line.
    var shebangs: [String] = []
    var style: TokenizerStyle = .cLike

    public internal(set) var lineComment: String?
    var extraLineComments: [String] = []
    public internal(set) var blockComment: BracketPair?
    var nestedBlockComments = false
    var strings: [StringRule] = []
    /// Prefixes that may precede a string quote (Python `f`, `r`, `b`).
    var stringPrefixes: Set<String> = []

    var keywords: Set<String> = []
    var controlKeywords: Set<String> = []
    var constants: Set<String> = []
    var types: Set<String> = []
    var builtins: Set<String> = []
    /// Keywords after which the next identifier names a function.
    var functionDeclarators: Set<String> = []
    /// Keywords after which the next identifier names a type.
    var typeDeclarators: Set<String> = []
    var caseInsensitiveKeywords = false

    /// `@` for attributes and decorators, colored as `attributeKind`.
    var attributePrefix: Character?
    var attributeKind: TokenKind = .attribute
    /// `#` for directives (`#if`, `#include`).
    var directivePrefix: Character?
    var directivesAtLineStartOnly = false
    /// A bracketed attribute opener such as Rust's `#[`.
    var bracketAttributeOpen: String?
    /// Prefixes that mark a variable (`$` in shell and PHP, `@` in Ruby).
    var variablePrefixes: Set<Character> = []
    /// Extra identifier characters (`$` in JavaScript and Swift).
    var identifierExtras: Set<Character> = []

    var capitalizedTypes = true
    var identifiersAsVariables = true
    var regexLiterals = false
    /// Rust lifetimes (`'a`).
    var lifetimes = false
    /// Rust-style macro calls (`println!`).
    var macroBang = false
    /// JSON: a string followed by `:` is a property key.
    var stringKeysAsProperties = false
    /// Makefile targets and similar `name:` labels at the start of a line.
    var lineStartLabelKind: TokenKind?

    public internal(set) var brackets: [BracketPair] = [BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}")]
    public internal(set) var autoClosingPairs: [BracketPair] = [
        BracketPair("(", ")"), BracketPair("[", "]"), BracketPair("{", "}"),
        BracketPair("\"", "\""), BracketPair("'", "'"),
    ]
    /// Line endings (after trimming) that indent the next line, beyond open brackets.
    public internal(set) var indentAfterSuffixes: [String] = []

    public static func == (lhs: LanguageDefinition, rhs: LanguageDefinition) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Built-in languages and lookup by id, file name or shebang line.
public final class LanguageRegistry: Sendable {
    public static let shared = LanguageRegistry(languages: Languages.all)

    public let languages: [LanguageDefinition]
    private let byID: [String: LanguageDefinition]
    private let byExtension: [String: LanguageDefinition]
    private let byFileName: [String: LanguageDefinition]
    private let tokenizers: [String: any LineTokenizer]

    public init(languages: [LanguageDefinition]) {
        self.languages = languages
        var byID: [String: LanguageDefinition] = [:]
        var byExtension: [String: LanguageDefinition] = [:]
        var byFileName: [String: LanguageDefinition] = [:]
        for language in languages {
            byID[language.id] = language
            for ext in language.extensions where byExtension[ext] == nil {
                byExtension[ext] = language
            }
            for name in language.fileNames {
                byFileName[name.lowercased()] = language
            }
        }
        self.byID = byID
        self.byExtension = byExtension
        self.byFileName = byFileName
        var tokenizers: [String: any LineTokenizer] = [:]
        for language in languages {
            tokenizers[language.id] = Self.makeTokenizer(for: language)
        }
        self.tokenizers = tokenizers
    }

    public var plainText: LanguageDefinition { byID["plaintext"]! }

    public func language(id: String) -> LanguageDefinition? {
        byID[id.lowercased()] ?? languages.first { $0.name.lowercased() == id.lowercased() }
    }

    /// Detects a language from a file name and, failing that, from a shebang line.
    public func language(forFileName fileName: String, firstLine: String? = nil) -> LanguageDefinition {
        let lower = fileName.lowercased()
        if let language = byFileName[lower] { return language }
        if let dot = lower.lastIndex(of: "."), dot != lower.startIndex || lower.count > 1 {
            let ext = String(lower[lower.index(after: dot)...])
            if let language = byExtension[ext] { return language }
        }
        if let firstLine, firstLine.hasPrefix("#!"), let language = language(forShebang: firstLine) {
            return language
        }
        return plainText
    }

    func language(forShebang line: String) -> LanguageDefinition? {
        let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "/" })
        for word in words.reversed() {
            let name = word.trimmingCharacters(in: .decimalDigits.union(CharacterSet(charactersIn: ".")))
            if let language = languages.first(where: { $0.shebangs.contains(name) }) {
                return language
            }
        }
        return nil
    }

    public func tokenizer(for language: LanguageDefinition) -> any LineTokenizer {
        tokenizers[language.id] ?? PlainTokenizer()
    }

    public func tokenizer(forID id: String) -> (any LineTokenizer)? {
        tokenizers[id]
    }

    static func makeTokenizer(for language: LanguageDefinition) -> any LineTokenizer {
        switch language.style {
        case .cLike: CLikeTokenizer(language)
        case .markdown: MarkdownTokenizer()
        case .html: MarkupTokenizer(html: true)
        case .xml: MarkupTokenizer(html: false)
        case .css: CSSTokenizer(lineComments: language.lineComment != nil)
        case .yaml: YAMLTokenizer()
        case .ini: INITokenizer()
        case .diff: DiffTokenizer()
        case .plain: PlainTokenizer()
        }
    }
}
