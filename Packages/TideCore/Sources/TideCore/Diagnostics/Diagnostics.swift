import Foundation

/// A problem in a document, shown as a squiggle and in the Problems panel.
/// Lines and columns are zero-based; columns are UTF-16 offsets.
public struct Diagnostic: Hashable, Identifiable, Sendable {
    public enum Severity: Int, Comparable, Codable, Sendable {
        case error = 0
        case warning = 1
        case info = 2
        case hint = 3

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var severity: Severity
    public var message: String
    public var line: Int
    public var column: Int
    public var length: Int
    public var source: String

    public init(severity: Severity, message: String, line: Int, column: Int, length: Int = 1, source: String) {
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
        self.length = max(1, length)
        self.source = source
    }

    public var id: String { "\(source):\(line):\(column):\(message)" }
}

/// Built-in diagnostics that need no language server: JSON syntax (with VS
/// Code's JSON language service messages) and unbalanced brackets.
public enum Diagnostics {
    public static func analyze(_ text: String, language: LanguageDefinition, fileName: String = "") -> [Diagnostic] {
        switch language.id {
        case "json":
            let lower = fileName.lowercased()
            let allowsComments = lower.hasSuffix(".jsonc") || lower.hasSuffix("settings.json") || lower.hasSuffix("keybindings.json")
                || lower.hasSuffix("tsconfig.json") || lower.hasSuffix(".code-workspace") || lower.hasPrefix(".") || lower.hasSuffix("jsconfig.json")
            return validateJSON(text, allowComments: allowsComments)
        case "plaintext", "markdown", "yaml", "toml", "ini", "diff", "ignore", "dockerfile", "makefile", "shellscript", "html", "xml", "sql":
            return []
        default:
            return bracketDiagnostics(text, language: language)
        }
    }

    // MARK: - Brackets

    /// Unexpected closing brackets and unclosed opening brackets, ignoring
    /// brackets inside strings and comments.
    public static func bracketDiagnostics(_ text: String, language: LanguageDefinition) -> [Diagnostic] {
        let nsText = text as NSString
        let lineIndex = LineIndex(nsText)
        let cache = TokenizationCache(tokenizer: LanguageRegistry.shared.tokenizer(for: language))
        cache.reset(text: nsText, lineIndex: lineIndex)
        let pairs: [UInt16: UInt16] = [CodeUnit.openParen: CodeUnit.closeParen, CodeUnit.openBracket: CodeUnit.closeBracket, CodeUnit.openBrace: CodeUnit.closeBrace]
        let closers = Set(pairs.values)
        var stack: [(unit: UInt16, line: Int, column: Int)] = []
        var problems: [Diagnostic] = []
        for line in 0..<lineIndex.lineCount {
            let start = lineIndex.lineStarts[line]
            for token in cache.tokens(forLine: line) where token.kind == .punctuation {
                for offset in token.start..<token.end {
                    let unit = nsText.character(at: start + offset)
                    if pairs[unit] != nil {
                        stack.append((unit, line, offset))
                    } else if closers.contains(unit) {
                        if let top = stack.last, pairs[top.unit] == unit {
                            stack.removeLast()
                        } else {
                            let character = String(utf16CodeUnits: [unit], count: 1)
                            problems.append(Diagnostic(severity: .error, message: "Unexpected '\(character)'.", line: line, column: offset, source: "tide"))
                            if problems.count > 50 { return problems }
                        }
                    }
                }
            }
        }
        for open in stack.prefix(20) {
            let character = String(utf16CodeUnits: [open.unit], count: 1)
            problems.append(Diagnostic(severity: .error, message: "'\(character)' was not closed.", line: open.line, column: open.column, source: "tide"))
        }
        return problems
    }

    // MARK: - JSON

    /// Validates JSON, or JSON with comments, reporting the first syntax
    /// error plus duplicate keys and trailing commas.
    public static func validateJSON(_ text: String, allowComments: Bool) -> [Diagnostic] {
        var parser = JSONValidator(text: text, allowComments: allowComments)
        parser.run()
        return parser.diagnostics
    }
}

/// A small recursive-descent JSON parser that reports positions and messages
/// in the style of VS Code's `jsonc-parser`.
struct JSONValidator {
    private let units: [UInt16]
    private let allowComments: Bool
    private let lineIndex: LineIndex
    private var position = 0
    private(set) var diagnostics: [Diagnostic] = []
    private var failed = false

    init(text: String, allowComments: Bool) {
        units = Array(text.utf16)
        self.allowComments = allowComments
        lineIndex = LineIndex(text)
    }

    mutating func run() {
        skipTrivia()
        if position >= units.count { return }
        parseValue(depth: 0)
        guard !failed else { return }
        skipTrivia()
        if position < units.count {
            error("End of file expected.", at: position)
        }
    }

    private mutating func error(_ message: String, at offset: Int, length: Int = 1, severity: Diagnostic.Severity = .error) {
        if severity == .error {
            guard !failed else { return }
            failed = true
        }
        let clamped = min(max(0, offset), max(0, units.count - 1))
        let (line, column) = lineIndex.position(of: units.isEmpty ? 0 : clamped)
        diagnostics.append(Diagnostic(severity: severity, message: message, line: line, column: column, length: length, source: "json"))
    }

    private mutating func skipTrivia() {
        while position < units.count {
            let unit = units[position]
            if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xFEFF {
                position += 1
            } else if unit == CodeUnit.slash, position + 1 < units.count, units[position + 1] == CodeUnit.slash || units[position + 1] == CodeUnit.asterisk {
                let start = position
                if units[position + 1] == CodeUnit.slash {
                    while position < units.count, units[position] != 0x0A { position += 1 }
                } else {
                    position += 2
                    var closed = false
                    while position + 1 < units.count {
                        if units[position] == CodeUnit.asterisk, units[position + 1] == CodeUnit.slash {
                            position += 2
                            closed = true
                            break
                        }
                        position += 1
                    }
                    if !closed {
                        position = units.count
                        error("Unexpected end of comment.", at: start, length: 2)
                    }
                }
                if !allowComments {
                    error("Comments are not permitted in JSON.", at: start, length: 2)
                }
            } else {
                return
            }
        }
    }

    private mutating func parseValue(depth: Int) {
        guard !failed else { return }
        guard depth < 512 else { return error("Nesting too deep.", at: position) }
        skipTrivia()
        guard position < units.count else { return error("Value expected.", at: units.count - 1) }
        switch units[position] {
        case CodeUnit.openBrace: parseObject(depth: depth)
        case CodeUnit.openBracket: parseArray(depth: depth)
        case CodeUnit.quote: _ = parseString()
        case CodeUnit.minus, 0x30...0x39: parseNumber()
        default:
            for literal in ["true", "false", "null"] where units.hasPrefix(literal.utf16Array, at: position) {
                position += literal.utf16.count
                return
            }
            error("Value expected.", at: position)
        }
    }

    private mutating func parseObject(depth: Int) {
        let open = position
        position += 1
        var keys: Set<String> = []
        skipTrivia()
        if position < units.count, units[position] == CodeUnit.closeBrace {
            position += 1
            return
        }
        while !failed {
            skipTrivia()
            guard position < units.count else { return error("Closing brace expected.", at: open) }
            guard units[position] == CodeUnit.quote else {
                if units[position] == CodeUnit.closeBrace {
                    return error("Property expected.", at: position)
                }
                return error("Property expected.", at: position)
            }
            let keyStart = position
            guard let key = parseString() else { return }
            if keys.contains(key) {
                error("Duplicate object key", at: keyStart, length: position - keyStart, severity: .warning)
            }
            keys.insert(key)
            skipTrivia()
            guard position < units.count, units[position] == CodeUnit.colon else { return error("Colon expected.", at: min(position, units.count - 1)) }
            position += 1
            parseValue(depth: depth + 1)
            guard !failed else { return }
            skipTrivia()
            guard position < units.count else { return error("Closing brace expected.", at: open) }
            if units[position] == CodeUnit.comma {
                let comma = position
                position += 1
                skipTrivia()
                if position < units.count, units[position] == CodeUnit.closeBrace {
                    error("Trailing comma", at: comma, severity: allowComments ? .warning : .error)
                    position += 1
                    return
                }
                continue
            }
            if units[position] == CodeUnit.closeBrace {
                position += 1
                return
            }
            return error("Comma expected.", at: position)
        }
    }

    private mutating func parseArray(depth: Int) {
        let open = position
        position += 1
        skipTrivia()
        if position < units.count, units[position] == CodeUnit.closeBracket {
            position += 1
            return
        }
        while !failed {
            parseValue(depth: depth + 1)
            guard !failed else { return }
            skipTrivia()
            guard position < units.count else { return error("Closing bracket expected.", at: open) }
            if units[position] == CodeUnit.comma {
                let comma = position
                position += 1
                skipTrivia()
                if position < units.count, units[position] == CodeUnit.closeBracket {
                    error("Trailing comma", at: comma, severity: allowComments ? .warning : .error)
                    position += 1
                    return
                }
                continue
            }
            if units[position] == CodeUnit.closeBracket {
                position += 1
                return
            }
            return error("Comma expected.", at: position)
        }
    }

    private mutating func parseString() -> String? {
        let start = position
        position += 1
        var value: [UInt16] = []
        while position < units.count {
            let unit = units[position]
            if unit == CodeUnit.quote {
                position += 1
                return String(decoding: value, as: UTF16.self)
            }
            if unit == CodeUnit.backslash {
                guard position + 1 < units.count else { break }
                let escape = units[position + 1]
                switch escape {
                case CodeUnit.quote, CodeUnit.backslash, CodeUnit.slash, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    value.append(escape)
                    position += 2
                case 0x75:
                    let digits = units[min(position + 2, units.count)..<min(position + 6, units.count)]
                    guard digits.count == 4, digits.allSatisfy(CodeUnit.isHexDigit) else {
                        error("Invalid unicode sequence in string.", at: position, length: 2)
                        return nil
                    }
                    position += 6
                default:
                    error("Invalid escape character in string.", at: position, length: 2)
                    return nil
                }
                continue
            }
            if unit < 0x20 {
                if unit == 0x0A || unit == 0x0D { break }
                error("Invalid characters in string. Control characters must be escaped.", at: position)
                return nil
            }
            value.append(unit)
            position += 1
        }
        error("Unexpected end of string.", at: start, length: max(1, position - start))
        return nil
    }

    private mutating func parseNumber() {
        let start = position
        if units[position] == CodeUnit.minus { position += 1 }
        guard position < units.count, CodeUnit.isDigit(units[position]) else { return error("Invalid number format.", at: start) }
        if units[position] == 0x30 {
            position += 1
        } else {
            while position < units.count, CodeUnit.isDigit(units[position]) { position += 1 }
        }
        if position < units.count, units[position] == CodeUnit.dot {
            position += 1
            guard position < units.count, CodeUnit.isDigit(units[position]) else { return error("Invalid number format.", at: start, length: position - start) }
            while position < units.count, CodeUnit.isDigit(units[position]) { position += 1 }
        }
        if position < units.count, units[position] == 0x65 || units[position] == 0x45 {
            position += 1
            if position < units.count, units[position] == CodeUnit.plus || units[position] == CodeUnit.minus { position += 1 }
            guard position < units.count, CodeUnit.isDigit(units[position]) else { return error("Invalid number format.", at: start, length: position - start) }
            while position < units.count, CodeUnit.isDigit(units[position]) { position += 1 }
        }
    }
}
