import Foundation

/// Symbol kinds, mirroring the Language Server Protocol's `SymbolKind` so a
/// remote language server's symbols drop into the same views.
public enum SymbolKind: String, CaseIterable, Codable, Sendable {
    case file, module, namespace, package, `class`, method, property, field, constructor
    case `enum`, interface, function, variable, constant, string, key, `struct`, enumMember
    case `extension`, typeParameter, heading, selector

    /// SF Symbol name used in the Outline view and Go to Symbol.
    public var iconName: String {
        switch self {
        case .file: "doc"
        case .module, .namespace, .package: "shippingbox"
        case .class: "c.square"
        case .method, .function: "f.cursive"
        case .constructor: "hammer"
        case .property, .field: "p.square"
        case .enum: "e.square"
        case .enumMember: "list.bullet"
        case .interface: "i.square"
        case .variable: "v.square"
        case .constant: "k.square"
        case .string: "textformat"
        case .key: "key"
        case .struct: "s.square"
        case .extension: "puzzlepiece.extension"
        case .typeParameter: "t.square"
        case .heading: "number"
        case .selector: "number.square"
        }
    }
}

/// A symbol in a document, with its children (members of a type, nested headings).
public struct DocumentSymbol: Hashable, Identifiable, Sendable {
    public var name: String
    public var kind: SymbolKind
    /// Zero-based line of the declaration.
    public var line: Int
    /// UTF-16 column of the name on that line.
    public var column: Int
    /// Last line of the symbol's body (its closing brace, or the last indented line).
    public var endLine: Int
    public var children: [DocumentSymbol]

    public var id: String { "\(line):\(column):\(name)" }

    /// The symbol and all of its descendants, depth first.
    public var flattened: [DocumentSymbol] {
        [self] + children.flatMap(\.flattened)
    }
}

/// Extracts symbols with per-language declaration patterns. Nesting comes from
/// brace depth measured on the tokenizer's punctuation tokens (so braces in
/// strings and comments do not count), or from indentation for Python and
/// YAML, and heading levels for Markdown.
public enum DocumentSymbols {
    public static func extract(from text: String, language: LanguageDefinition) -> [DocumentSymbol] {
        switch language.id {
        case "markdown": return markdownHeadings(text)
        case "python": return indentationSymbols(text, patterns: pythonPatterns)
        case "yaml": return yamlKeys(text)
        case "json": return jsonKeys(text, language: language)
        case "css", "scss", "less": return cssSelectors(text, language: language)
        default:
            guard let patterns = bracePatterns[language.id] ?? (language.style == .cLike ? genericPatterns : nil) else { return [] }
            return braceSymbols(text, language: language, patterns: patterns)
        }
    }

    // MARK: - Patterns

    struct Pattern: @unchecked Sendable {
        let regex: NSRegularExpression
        let kind: (String) -> SymbolKind
        /// Whether the symbol may contain members (only containers become parents).
        let isContainer: Bool

        init(_ pattern: String, isContainer: Bool = false, kind: @escaping @Sendable (String) -> SymbolKind) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.kind = kind
            self.isContainer = isContainer
        }
    }

    private static let modifiers = #"(?:(?:@[\w.]+(?:\([^)]*\))?|public|private|fileprivate|internal|open|package|static|class|final|override|mutating|nonmutating|nonisolated|convenience|required|lazy|weak|unowned|async|export|default|abstract|protected|readonly|declare|pub(?:\([^)]*\))?|unsafe|extern|virtual|inline|const|sealed|data|inner|suspend|operator|infix|tailrec|external|actual|expect)\s+)*"#

    static let swiftTypeKinds: [String: SymbolKind] = [
        "class": .class, "struct": .struct, "enum": .enum, "protocol": .interface, "extension": .extension, "actor": .class,
    ]

    static let bracePatterns: [String: [Pattern]] = [
        "swift": [
            Pattern("^\\s*" + modifiers + #"(class|struct|enum|protocol|extension|actor)\s+([A-Za-z_][\w.]*)"#, isContainer: true) { swiftTypeKinds[$0] ?? .class },
            Pattern("^\\s*" + modifiers + #"(func)\s+([A-Za-z_]\w*|[^\s(]+)"#) { _ in .method },
            Pattern("^\\s*" + modifiers + #"(init|deinit)()"#) { _ in .constructor },
            Pattern("^\\s*" + modifiers + #"(var|let)\s+([A-Za-z_]\w*)"#) { $0 == "let" ? .constant : .property },
            Pattern(#"^\s*(case)\s+([A-Za-z_]\w*)"#) { _ in .enumMember },
            Pattern("^\\s*" + modifiers + #"(typealias)\s+([A-Za-z_]\w*)"#) { _ in .typeParameter },
        ],
        "javascript": jsPatterns,
        "typescript": jsPatterns + [
            Pattern("^\\s*" + modifiers + #"(interface|enum|namespace|module)\s+([A-Za-z_$][\w$.]*)"#, isContainer: true) { ["interface": .interface, "enum": .enum][$0] ?? .namespace },
            Pattern("^\\s*" + modifiers + #"(type)\s+([A-Za-z_$][\w$]*)"#) { _ in .typeParameter },
        ],
        "rust": [
            Pattern("^\\s*" + modifiers + #"(struct|enum|trait|impl|mod|union)\b(?:<[^>]*>)?\s*([A-Za-z_][\w:<>, ]*?)\s*(?:\{|where|$|for\b)"#, isContainer: true) {
                ["struct": .struct, "enum": .enum, "trait": .interface, "mod": .module, "impl": .extension][$0] ?? .struct
            },
            Pattern("^\\s*" + modifiers + #"(fn)\s+([A-Za-z_]\w*)"#) { _ in .function },
            Pattern("^\\s*" + modifiers + #"(const|static)\s+([A-Z_][A-Z0-9_]*)"#) { _ in .constant },
        ],
        "go": [
            Pattern(#"^\s*(type)\s+([A-Za-z_]\w*)\s+(?:struct|interface)"#, isContainer: true) { _ in .struct },
            Pattern(#"^\s*(func)\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#) { _ in .function },
            Pattern(#"^\s*(type)\s+([A-Za-z_]\w*)"#) { _ in .typeParameter },
        ],
        "kotlin": [
            Pattern("^\\s*" + modifiers + #"(class|interface|object|enum class)\s+([A-Za-z_]\w*)"#, isContainer: true) { $0 == "interface" ? .interface : .class },
            Pattern("^\\s*" + modifiers + #"(fun)\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?([A-Za-z_]\w*)"#) { _ in .function },
            Pattern("^\\s*" + modifiers + #"(val|var)\s+([A-Za-z_]\w*)"#) { $0 == "val" ? .constant : .property },
        ],
        "java": javaLikePatterns,
        "csharp": javaLikePatterns,
        "dart": javaLikePatterns,
        "php": [
            Pattern("^\\s*" + modifiers + #"(class|interface|trait|enum)\s+([A-Za-z_]\w*)"#, isContainer: true) { $0 == "interface" ? .interface : .class },
            Pattern("^\\s*" + modifiers + #"(function)\s+&?([A-Za-z_]\w*)"#) { _ in .function },
        ],
    ]

    static let jsPatterns: [Pattern] = [
        Pattern("^\\s*" + modifiers + #"(class)\s+([A-Za-z_$][\w$]*)"#, isContainer: true) { _ in .class },
        Pattern("^\\s*" + modifiers + #"(function\*?)\s*([A-Za-z_$][\w$]*)"#) { _ in .function },
        Pattern("^\\s*" + modifiers + #"(const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>"#) { _ in .function },
        Pattern("^\\s*" + modifiers + #"()(?:get\s+|set\s+|async\s+|\*\s*)?([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*(?::[^{]+)?\{\s*$"#) { _ in .method },
    ]

    static let javaLikePatterns: [Pattern] = [
        Pattern("^\\s*" + modifiers + #"(class|interface|enum|record|struct|mixin|extension)\s+([A-Za-z_]\w*)"#, isContainer: true) {
            ["interface": .interface, "enum": .enum, "struct": .struct, "extension": .extension][$0] ?? .class
        },
        Pattern("^\\s*" + modifiers + #"()(?:<[^>]+>\s+)?[\w<>\[\],.?]+\s+([A-Za-z_]\w*)\s*\([^;]*$"#) { _ in .method },
    ]

    static let genericPatterns: [Pattern] = [
        Pattern("^\\s*" + modifiers + #"(class|struct|enum|interface|union|namespace)\s+([A-Za-z_]\w*)"#, isContainer: true) {
            ["struct": .struct, "enum": .enum, "interface": .interface, "namespace": .namespace][$0] ?? .class
        },
        Pattern(#"^\s*(?:[\w:*&<>,]+\s+)+\**([A-Za-z_][\w:~]*)\s*\([^;]*\)\s*(?:const\s*)?\{?\s*$"#) { _ in .function },
        Pattern(#"^\s*(function|fn|func|def|sub)\s+([A-Za-z_][\w.:]*)"#) { _ in .function },
    ]

    static let pythonPatterns: [Pattern] = [
        Pattern(#"^\s*(class)\s+([A-Za-z_]\w*)"#, isContainer: true) { _ in .class },
        Pattern(#"^\s*(?:async\s+)?(def)\s+([A-Za-z_]\w*)"#, isContainer: true) { _ in .function },
    ]

    // MARK: - Brace languages

    private static func braceSymbols(_ text: String, language: LanguageDefinition, patterns: [Pattern]) -> [DocumentSymbol] {
        let nsText = text as NSString
        let lineIndex = LineIndex(nsText)
        let cache = TokenizationCache(tokenizer: LanguageRegistry.shared.tokenizer(for: language))
        cache.reset(text: nsText, lineIndex: lineIndex)

        struct Open {
            var symbol: DocumentSymbol
            var depth: Int
            var isContainer: Bool
        }
        var roots: [DocumentSymbol] = []
        var stack: [Open] = []
        var depth = 0
        var pending: Open?

        func close(_ item: Open, at line: Int) {
            var symbol = item.symbol
            symbol.endLine = max(symbol.endLine, line)
            if stack.isEmpty {
                roots.append(symbol)
            } else {
                stack[stack.count - 1].symbol.children.append(symbol)
            }
        }

        for line in 0..<lineIndex.lineCount {
            let range = lineIndex.contentRange(ofLine: line, in: nsText)
            let lineText = nsText.substring(with: range)
            let tokens = cache.tokens(forLine: line)
            let firstKind = tokens.first(where: { $0.kind != .plain })?.kind
            if firstKind != .comment, firstKind != .string, let match = match(lineText, patterns: patterns) {
                // Members only inside containers: skip locals inside function bodies.
                let insideFunction = stack.last.map { !$0.isContainer } ?? false
                if !insideFunction {
                    if let pending { close(pending, at: line - 1) }
                    pending = Open(
                        symbol: DocumentSymbol(name: match.name, kind: match.kind, line: line, column: match.column, endLine: line, children: []),
                        depth: depth,
                        isContainer: match.isContainer
                    )
                }
            }
            // Adjacent punctuation merges into one token ("{}"), so look at every unit.
            for token in tokens where token.kind == .punctuation {
                for offset in token.start..<token.end {
                    let unit = nsText.character(at: range.location + offset)
                    if unit == CodeUnit.openBrace {
                        depth += 1
                        if let open = pending, open.depth == depth - 1 {
                            stack.append(open)
                            pending = nil
                        }
                    } else if unit == CodeUnit.closeBrace {
                        depth = max(0, depth - 1)
                        if let top = stack.last, top.depth >= depth {
                            stack.removeLast()
                            close(top, at: line)
                        }
                    }
                }
            }
            // A declaration without a body ends on its own line.
            if let open = pending, !(lineText.trimmingCharacters(in: .whitespaces).hasSuffix("(") || lineText.hasSuffix(",")) {
                pending = nil
                close(open, at: line)
            }
        }
        if let pending { close(pending, at: lineIndex.lineCount - 1) }
        while let top = stack.popLast() { close(top, at: lineIndex.lineCount - 1) }
        return roots
    }

    private struct Match {
        var name: String
        var kind: SymbolKind
        var column: Int
        var isContainer: Bool
    }

    private static func match(_ line: String, patterns: [Pattern]) -> Match? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        for pattern in patterns {
            guard let result = pattern.regex.firstMatch(in: line, range: range) else { continue }
            let keywordRange = result.numberOfRanges > 2 ? result.range(at: 1) : NSRange(location: NSNotFound, length: 0)
            let nameRange = result.range(at: result.numberOfRanges - 1)
            let keyword = keywordRange.location == NSNotFound ? "" : (line as NSString).substring(with: keywordRange)
            var name = nameRange.location == NSNotFound || nameRange.length == 0 ? keyword : (line as NSString).substring(with: nameRange)
            name = name.trimmingCharacters(in: .whitespaces)
            // Keyword-less patterns (methods) must not pick up control flow such as `if (x) {`.
            guard !name.isEmpty, !(keyword.isEmpty && ["if", "for", "while", "switch", "return", "catch", "else", "new", "await", "throw", "function"].contains(name)) else { continue }
            let column = nameRange.location == NSNotFound || nameRange.length == 0 ? max(0, keywordRange.location) : nameRange.location
            return Match(name: name, kind: pattern.kind(keyword), column: column, isContainer: pattern.isContainer)
        }
        return nil
    }

    // MARK: - Indentation languages

    private static func indentationSymbols(_ text: String, patterns: [Pattern]) -> [DocumentSymbol] {
        let lines = LineDiff.lines(of: text)
        struct Open {
            var symbol: DocumentSymbol
            var indent: Int
        }
        var roots: [DocumentSymbol] = []
        var stack: [Open] = []
        var lastContentLine = 0

        func popTo(indent: Int) {
            while let top = stack.last, top.indent >= indent {
                stack.removeLast()
                var symbol = top.symbol
                symbol.endLine = max(symbol.line, lastContentLine)
                if stack.isEmpty { roots.append(symbol) } else { stack[stack.count - 1].symbol.children.append(symbol) }
            }
        }

        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            popTo(indent: indent)
            if let match = match(line, patterns: patterns) {
                stack.append(Open(symbol: DocumentSymbol(name: match.name, kind: match.kind, line: number, column: match.column, endLine: number, children: []), indent: indent))
            }
            lastContentLine = number
        }
        popTo(indent: 0)
        return roots
    }

    // MARK: - Markup and data

    private static func markdownHeadings(_ text: String) -> [DocumentSymbol] {
        var roots: [DocumentSymbol] = []
        var stack: [(level: Int, symbol: DocumentSymbol)] = []
        var inFence = false
        let lines = LineDiff.lines(of: text)

        func pop(toLevel level: Int, endLine: Int) {
            while let top = stack.last, top.level >= level {
                stack.removeLast()
                var symbol = top.symbol
                symbol.endLine = endLine
                if stack.isEmpty { roots.append(symbol) } else { stack[stack.count - 1].symbol.children.append(symbol) }
            }
        }

        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix { $0 == "#" }.count
            guard level <= 6, trimmed.dropFirst(level).first == " " else { continue }
            let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
            pop(toLevel: level, endLine: max(0, number - 1))
            stack.append((level, DocumentSymbol(name: title, kind: .heading, line: number, column: line.prefix { $0 == " " }.count + level + 1, endLine: number, children: [])))
        }
        pop(toLevel: 1, endLine: max(0, lines.count - 1))
        return roots
    }

    private static func yamlKeys(_ text: String) -> [DocumentSymbol] {
        var symbols: [DocumentSymbol] = []
        for (number, line) in LineDiff.lines(of: text).enumerated() {
            guard let first = line.first, first != " ", first != "#", first != "-", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard !key.isEmpty else { continue }
            symbols.append(DocumentSymbol(name: key, kind: .key, line: number, column: 0, endLine: number, children: []))
        }
        return symbols
    }

    private static func jsonKeys(_ text: String, language: LanguageDefinition) -> [DocumentSymbol] {
        let nsText = text as NSString
        let lineIndex = LineIndex(nsText)
        let cache = TokenizationCache(tokenizer: LanguageRegistry.shared.tokenizer(for: language))
        cache.reset(text: nsText, lineIndex: lineIndex)
        var symbols: [DocumentSymbol] = []
        var depth = 0
        for line in 0..<lineIndex.lineCount {
            let start = lineIndex.lineStarts[line]
            for token in cache.tokens(forLine: line) {
                if token.kind == .punctuation {
                    for offset in token.start..<token.end {
                        let unit = nsText.character(at: start + offset)
                        if unit == CodeUnit.openBrace || unit == CodeUnit.openBracket { depth += 1 }
                        if unit == CodeUnit.closeBrace || unit == CodeUnit.closeBracket { depth -= 1 }
                    }
                } else if token.kind == .property, depth == 1 {
                    let name = nsText.substring(with: NSRange(location: start + token.start, length: token.length)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    symbols.append(DocumentSymbol(name: name, kind: .key, line: line, column: token.start, endLine: line, children: []))
                }
            }
        }
        return symbols
    }

    private static func cssSelectors(_ text: String, language: LanguageDefinition) -> [DocumentSymbol] {
        var symbols: [DocumentSymbol] = []
        for (number, line) in LineDiff.lines(of: text).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("{"), !trimmed.hasPrefix("/*"), !trimmed.hasPrefix("//") else { continue }
            let selector = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { continue }
            symbols.append(DocumentSymbol(name: selector, kind: .selector, line: number, column: line.prefix { $0 == " " || $0 == "\t" }.count, endLine: number, children: []))
        }
        return symbols
    }
}
