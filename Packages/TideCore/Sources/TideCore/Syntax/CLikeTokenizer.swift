import Foundation

/// A data-driven tokenizer for C-family and scripting languages. One instance
/// serves one `LanguageDefinition`; every rule comes from the definition, so
/// adding a language is a matter of filling in keyword sets and delimiters.
struct CLikeTokenizer: LineTokenizer {
    private struct CompiledString: Sendable {
        var open: [UInt16]
        var close: [UInt16]
        var escape: UInt16?
        var multiline: Bool
        var interpolationOpen: [UInt16]?
        var dollarVariables: Bool
    }

    private let language: LanguageDefinition
    private let lineComments: [[UInt16]]
    private let blockOpen: [UInt16]?
    private let blockClose: [UInt16]?
    private let strings: [CompiledString]
    /// String rule indices ordered longest opener first, so `"""` wins over `"`.
    private let stringOrder: [Int]
    private let stringPrefixes: Set<String>
    private let keywords: Set<String>
    private let controlKeywords: Set<String>
    private let constants: Set<String>
    private let types: Set<String>
    private let builtins: Set<String>
    private let attributePrefix: UInt16?
    private let directivePrefix: UInt16?
    private let bracketAttributeOpen: [UInt16]?
    private let variablePrefixes: Set<UInt16>
    private let identifierExtras: Set<UInt16>
    /// Words after which a `/` starts a regular expression rather than a division.
    private static let regexAfterWords: Set<String> = [
        "return", "typeof", "case", "do", "else", "in", "of", "instanceof", "new", "delete", "void", "throw", "yield", "await",
    ]

    init(_ language: LanguageDefinition) {
        self.language = language
        lineComments = ([language.lineComment].compactMap { $0 } + language.extraLineComments).map(\.utf16Array)
        blockOpen = language.blockComment?.open.utf16Array
        blockClose = language.blockComment?.close.utf16Array
        strings = language.strings.map {
            CompiledString(
                open: $0.open.utf16Array,
                close: $0.close.utf16Array,
                escape: $0.escape?.utf16.first,
                multiline: $0.multiline,
                interpolationOpen: $0.interpolationOpen?.utf16Array,
                dollarVariables: $0.dollarVariables
            )
        }
        stringOrder = language.strings.indices.sorted { language.strings[$0].open.utf16.count > language.strings[$1].open.utf16.count }
        stringPrefixes = Set(language.stringPrefixes.map { $0.lowercased() })
        let normalize: (Set<String>) -> Set<String> = { words in
            language.caseInsensitiveKeywords ? Set(words.map { $0.lowercased() }) : words
        }
        keywords = normalize(language.keywords)
        controlKeywords = normalize(language.controlKeywords)
        constants = normalize(language.constants)
        types = normalize(language.types)
        builtins = normalize(language.builtins)
        attributePrefix = language.attributePrefix.flatMap { $0.utf16.first }
        directivePrefix = language.directivePrefix.flatMap { $0.utf16.first }
        bracketAttributeOpen = language.bracketAttributeOpen?.utf16Array
        variablePrefixes = Set(language.variablePrefixes.compactMap { $0.utf16.first })
        identifierExtras = Set(language.identifierExtras.compactMap { $0.utf16.first })
    }

    /// Per-line scanning context.
    private struct Context {
        var tokens: [Token] = []
        /// Kind of declaration the next identifier names (`func name`, `class Name`).
        var pendingDeclaration: TokenKind?
        /// Last significant token, for regex and property detection.
        var lastKind: TokenKind?
        var lastWord: String?
        var lastWasDot = false
        var lastClosesExpression = false

        mutating func emit(_ kind: TokenKind, _ start: Int, _ end: Int) {
            guard end > start else { return }
            if kind == .plain {
                lastKind = .plain
                return
            }
            if let last = tokens.last, last.kind == kind, last.end == start {
                tokens[tokens.count - 1].length += end - start
            } else {
                tokens.append(Token(start: start, length: end - start, kind: kind))
            }
        }

        mutating func significant(_ kind: TokenKind, word: String? = nil, dot: Bool = false, closes: Bool = false) {
            lastKind = kind
            lastWord = word
            lastWasDot = dot
            lastClosesExpression = closes
        }
    }

    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        var context = Context()
        var index = 0
        let count = line.count

        switch state {
        case .blockComment(let depth):
            let (end, remaining) = scanBlockComment(line, from: 0, depth: depth)
            context.emit(.comment, 0, end)
            if remaining > 0 { return (context.tokens, .blockComment(depth: remaining)) }
            index = end
        case .openString(let rule) where rule < strings.count:
            let (end, closed) = scanString(line, contentStart: 0, tokenStart: 0, rule: strings[rule], context: &context)
            if !closed { return (context.tokens, .openString(rule: rule)) }
            index = end
            context.significant(.string, closes: true)
        default:
            break
        }

        while index < count {
            let unit = line[index]
            if CodeUnit.isWhitespace(unit) {
                index += 1
                continue
            }

            // Block comments are checked before line comments so Lua's `--[[`
            // is not mistaken for a `--` line comment.
            if let open = blockOpen, line.hasPrefix(open, at: index) {
                let (end, depth) = scanBlockComment(line, from: index + open.count, depth: 1)
                context.emit(.comment, index, end)
                if depth > 0 { return (context.tokens, .blockComment(depth: depth)) }
                index = end
                continue
            }
            if lineComments.contains(where: { line.hasPrefix($0, at: index) }) {
                context.emit(.comment, index, count)
                return (context.tokens, .root)
            }

            if let label = language.lineStartLabelKind, let end = lineStartLabelEnd(line, at: index) {
                context.emit(label, index, end)
                context.significant(label)
                index = end
                continue
            }

            if let open = bracketAttributeOpen, line.hasPrefix(open, at: index) {
                let end = matchingBracketEnd(line, from: index + open.count)
                context.emit(.attribute, index, end)
                context.significant(.attribute)
                index = end
                continue
            }

            // Before strings: a Rust lifetime `'a` would otherwise open a char literal.
            if language.lifetimes, unit == CodeUnit.apostrophe, let end = lifetimeEnd(line, at: index) {
                context.emit(.keyword, index, end)
                context.significant(.keyword)
                index = end
                continue
            }

            if let ruleIndex = stringRule(at: index, in: line) {
                let rule = strings[ruleIndex]
                let firstToken = context.tokens.count
                let (end, closed) = scanString(line, contentStart: index + rule.open.count, tokenStart: index, rule: rule, context: &context)
                if !closed, rule.multiline {
                    return (context.tokens, .openString(rule: ruleIndex))
                }
                if language.stringKeysAsProperties {
                    let next = line.skippingWhitespace(from: end)
                    if next < count, line[next] == CodeUnit.colon {
                        for token in firstToken..<context.tokens.count where context.tokens[token].kind == .string {
                            context.tokens[token].kind = .property
                        }
                    }
                }
                context.significant(.string, closes: true)
                index = end
                continue
            }

            if CodeUnit.isDigit(unit) || (unit == CodeUnit.dot && index + 1 < count && CodeUnit.isDigit(line[index + 1]) && !context.lastClosesExpression) {
                let end = scanNumber(line, from: index)
                context.emit(.number, index, end)
                context.significant(.number, closes: true)
                index = end
                continue
            }

            if variablePrefixes.contains(unit), let end = variableEnd(line, at: index) {
                context.emit(.variable, index, end)
                context.significant(.variable, closes: true)
                index = end
                continue
            }

            if unit == attributePrefix, index + 1 < count, CodeUnit.isIdentifierStart(line[index + 1]) {
                var end = scanIdentifier(line, from: index + 1)
                // Dotted decorators: `@app.route`.
                while end + 1 < count, line[end] == CodeUnit.dot, CodeUnit.isIdentifierStart(line[end + 1]) {
                    end = scanIdentifier(line, from: end + 1)
                }
                context.emit(language.attributeKind, index, end)
                context.significant(language.attributeKind)
                index = end
                continue
            }

            if unit == directivePrefix, index + 1 < count, CodeUnit.isIdentifierStart(line[index + 1]),
               !language.directivesAtLineStartOnly || line.skippingWhitespace(from: 0) == index {
                let end = scanIdentifier(line, from: index + 1)
                context.emit(.preprocessor, index, end)
                context.significant(.preprocessor)
                index = end
                // `#include <stdio.h>`: the angle-bracketed path is a string.
                let next = line.skippingWhitespace(from: index)
                if next < count, line[next] == CodeUnit.lessThan, let close = line[next...].firstIndex(of: CodeUnit.greaterThan) {
                    context.emit(.string, next, close + 1)
                    index = close + 1
                }
                continue
            }

            if CodeUnit.isIdentifierStart(unit) || identifierExtras.contains(unit) {
                let end = scanIdentifier(line, from: index)
                let word = line.string(index..<end)
                // String prefixes: Python f"..." and r'...'.
                if end < count, stringPrefixes.contains(word.lowercased()), let ruleIndex = stringRule(at: end, in: line) {
                    let rule = strings[ruleIndex]
                    let (stringEnd, closed) = scanString(line, contentStart: end + rule.open.count, tokenStart: index, rule: rule, context: &context)
                    if !closed, rule.multiline {
                        return (context.tokens, .openString(rule: ruleIndex))
                    }
                    context.significant(.string, closes: true)
                    index = stringEnd
                    continue
                }
                var kindEnd = end
                let kind = classify(word, line: line, end: end, context: &context, kindEnd: &kindEnd)
                context.emit(kind, index, kindEnd)
                context.significant(kind, word: word, closes: kind != .keyword && kind != .control)
                index = kindEnd
                continue
            }

            if language.regexLiterals, unit == CodeUnit.slash, regexAllowed(context), let end = regexEnd(line, from: index) {
                context.emit(.regex, index, end)
                context.significant(.regex, closes: true)
                index = end
                continue
            }

            if CodeUnit.isOperator(unit) {
                var end = index + 1
                while end < count, CodeUnit.isOperator(line[end]), !startsComment(line, at: end) {
                    end += 1
                }
                let isDot = line[end - 1] == CodeUnit.dot && (end - index == 1 || line[end - 2] != CodeUnit.dot)
                context.emit(.operatorSymbol, index, end)
                context.pendingDeclaration = nil
                context.significant(.operatorSymbol, dot: isDot)
                index = end
                continue
            }

            switch unit {
            case CodeUnit.openParen, CodeUnit.openBracket, CodeUnit.openBrace,
                 CodeUnit.comma, CodeUnit.semicolon:
                context.emit(.punctuation, index, index + 1)
                context.pendingDeclaration = nil
                context.significant(.punctuation)
            case CodeUnit.closeParen, CodeUnit.closeBracket, CodeUnit.closeBrace:
                context.emit(.punctuation, index, index + 1)
                context.pendingDeclaration = nil
                context.significant(.punctuation, closes: true)
            default:
                context.significant(.plain)
            }
            index += 1
        }
        return (context.tokens, .root)
    }

    // MARK: - Identifiers

    private func scanIdentifier(_ line: [UInt16], from start: Int) -> Int {
        var end = start
        while end < line.count, CodeUnit.isIdentifierPart(line[end]) || identifierExtras.contains(line[end]) {
            end += 1
        }
        return max(end, start + 1)
    }

    private func classify(_ word: String, line: [UInt16], end: Int, context: inout Context, kindEnd: inout Int) -> TokenKind {
        let key = language.caseInsensitiveKeywords ? word.lowercased() : word
        if language.functionDeclarators.contains(key) {
            context.pendingDeclaration = .function
            return controlKeywords.contains(key) ? .control : .keyword
        }
        if language.typeDeclarators.contains(key) {
            context.pendingDeclaration = .type
            return controlKeywords.contains(key) ? .control : .keyword
        }
        if controlKeywords.contains(key) { return .control }
        if keywords.contains(key) { return .keyword }
        if constants.contains(key) { return .constant }
        if let pending = context.pendingDeclaration {
            context.pendingDeclaration = nil
            return pending
        }
        if types.contains(key) { return .type }

        let next = line.skippingWhitespace(from: end)
        if language.macroBang, end < line.count, line[end] == CodeUnit.exclamation,
           end + 1 < line.count, [CodeUnit.openParen, CodeUnit.openBracket, CodeUnit.openBrace].contains(line[end + 1]) {
            kindEnd = end + 1
            return .function
        }
        if next < line.count, line[next] == CodeUnit.openParen {
            return .function
        }
        if builtins.contains(key) { return .function }

        let first = word.utf16.first ?? 0
        if word.utf16.count > 1, word.utf16.contains(where: CodeUnit.isUpper), !word.utf16.contains(where: CodeUnit.isLower) {
            return .constant
        }
        if language.capitalizedTypes, CodeUnit.isUpper(first) {
            return .type
        }
        if context.lastWasDot { return .property }
        return language.identifiersAsVariables ? .variable : .plain
    }

    // MARK: - Comments

    private func startsComment(_ line: [UInt16], at index: Int) -> Bool {
        if let open = blockOpen, line.hasPrefix(open, at: index) { return true }
        return lineComments.contains { line.hasPrefix($0, at: index) }
    }

    /// Scans a block comment body from `start` with `depth` comments open.
    /// Returns the offset after the final close (or the line end) and the
    /// number of comments still open.
    private func scanBlockComment(_ line: [UInt16], from start: Int, depth: Int) -> (end: Int, depth: Int) {
        guard let open = blockOpen, let close = blockClose else { return (line.count, 0) }
        var index = start
        var depth = depth
        while index < line.count {
            if line.hasPrefix(close, at: index) {
                index += close.count
                depth -= 1
                if depth == 0 { return (index, 0) }
            } else if language.nestedBlockComments, line.hasPrefix(open, at: index) {
                index += open.count
                depth += 1
            } else {
                index += 1
            }
        }
        return (line.count, depth)
    }

    // MARK: - Strings

    private func stringRule(at index: Int, in line: [UInt16]) -> Int? {
        stringOrder.first { line.hasPrefix(strings[$0].open, at: index) }
    }

    /// Scans string content, emitting string, escape and interpolation tokens.
    /// Returns the offset after the closing delimiter (or the line end) and
    /// whether the string closed on this line.
    private func scanString(_ line: [UInt16], contentStart: Int, tokenStart: Int, rule: CompiledString, context: inout Context) -> (end: Int, closed: Bool) {
        var segmentStart = tokenStart
        var index = contentStart
        let count = line.count
        while index < count {
            if let interpolation = rule.interpolationOpen, line.hasPrefix(interpolation, at: index) {
                context.emit(.string, segmentStart, index)
                let openEnd = index + interpolation.count
                context.emit(.keyword, index, openEnd)
                let nestOpen = interpolation.last!
                let nestClose: UInt16 = nestOpen == CodeUnit.openParen ? CodeUnit.closeParen : CodeUnit.closeBrace
                var depth = 1
                var cursor = openEnd
                while cursor < count {
                    if line[cursor] == nestOpen {
                        depth += 1
                    } else if line[cursor] == nestClose {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    cursor += 1
                }
                context.emit(.variable, openEnd, cursor)
                if cursor < count {
                    context.emit(.keyword, cursor, cursor + 1)
                    cursor += 1
                }
                index = cursor
                segmentStart = index
                continue
            }
            if rule.dollarVariables, line[index] == CodeUnit.dollar, let end = variableEnd(line, at: index) {
                context.emit(.string, segmentStart, index)
                context.emit(.variable, index, end)
                index = end
                segmentStart = index
                continue
            }
            if let escape = rule.escape, line[index] == escape {
                context.emit(.string, segmentStart, index)
                let end = min(count, index + escapeLength(line, at: index))
                context.emit(.escape, index, end)
                index = end
                segmentStart = index
                continue
            }
            if line.hasPrefix(rule.close, at: index) {
                index += rule.close.count
                context.emit(.string, segmentStart, index)
                return (index, true)
            }
            index += 1
        }
        context.emit(.string, segmentStart, count)
        return (count, false)
    }

    private func escapeLength(_ line: [UInt16], at index: Int) -> Int {
        guard index + 1 < line.count else { return 1 }
        let next = line[index + 1]
        if next == 0x75 /* u */ {
            if index + 2 < line.count, line[index + 2] == CodeUnit.openBrace {
                if let close = line[(index + 2)...].firstIndex(of: CodeUnit.closeBrace) { return close - index + 1 }
                return 3
            }
            var length = 2
            while length < 6, index + length < line.count, CodeUnit.isHexDigit(line[index + length]) { length += 1 }
            return length
        }
        if next == 0x78 /* x */ {
            var length = 2
            while length < 4, index + length < line.count, CodeUnit.isHexDigit(line[index + length]) { length += 1 }
            return length
        }
        return 2
    }

    // MARK: - Numbers, variables, lifetimes, regex

    private func scanNumber(_ line: [UInt16], from start: Int) -> Int {
        var index = start
        let count = line.count
        if line[index] == 0x30, index + 1 < count, [0x78, 0x58, 0x62, 0x42, 0x6F, 0x4F].contains(line[index + 1]) {
            index += 2
            while index < count, CodeUnit.isHexDigit(line[index]) || line[index] == CodeUnit.underscore { index += 1 }
        } else {
            while index < count, CodeUnit.isDigit(line[index]) || line[index] == CodeUnit.underscore { index += 1 }
            if index + 1 < count, line[index] == CodeUnit.dot, CodeUnit.isDigit(line[index + 1]) {
                index += 1
                while index < count, CodeUnit.isDigit(line[index]) || line[index] == CodeUnit.underscore { index += 1 }
            }
            if index < count, line[index] == 0x65 || line[index] == 0x45 {
                var exponent = index + 1
                if exponent < count, line[exponent] == CodeUnit.plus || line[exponent] == CodeUnit.minus { exponent += 1 }
                if exponent < count, CodeUnit.isDigit(line[exponent]) {
                    index = exponent
                    while index < count, CodeUnit.isDigit(line[index]) { index += 1 }
                }
            }
        }
        // Type suffixes: 10u, 1.5f, 100n, 5i32.
        while index < count, CodeUnit.isIdentifierPart(line[index]) { index += 1 }
        return index
    }

    private func variableEnd(_ line: [UInt16], at index: Int) -> Int? {
        let count = line.count
        guard index + 1 < count else { return nil }
        let next = line[index + 1]
        if next == CodeUnit.openBrace {
            if let close = line[(index + 1)...].firstIndex(of: CodeUnit.closeBrace) { return close + 1 }
            return count
        }
        if CodeUnit.isIdentifierStart(next) {
            var end = index + 1
            while end < count, CodeUnit.isIdentifierPart(line[end]) { end += 1 }
            return end
        }
        // Shell specials: $1 $? $@ $# $$ $! $*
        if CodeUnit.isDigit(next) || [CodeUnit.question, CodeUnit.at, CodeUnit.hash, CodeUnit.dollar, CodeUnit.exclamation, CodeUnit.asterisk].contains(next) {
            return index + 2
        }
        return nil
    }

    /// Rust lifetime `'a` (an apostrophe and identifier not closed by another apostrophe).
    private func lifetimeEnd(_ line: [UInt16], at index: Int) -> Int? {
        guard index + 1 < line.count, CodeUnit.isIdentifierStart(line[index + 1]) else { return nil }
        var end = index + 1
        while end < line.count, CodeUnit.isIdentifierPart(line[end]) { end += 1 }
        if end < line.count, line[end] == CodeUnit.apostrophe { return nil }
        return end
    }

    private func regexAllowed(_ context: Context) -> Bool {
        guard let last = context.lastKind else { return true }
        switch last {
        case .operatorSymbol, .punctuation:
            return !context.lastClosesExpression
        case .keyword, .control:
            return context.lastWord.map(Self.regexAfterWords.contains) ?? true
        default:
            return false
        }
    }

    private func regexEnd(_ line: [UInt16], from start: Int) -> Int? {
        var index = start + 1
        var inClass = false
        let count = line.count
        guard index < count, line[index] != CodeUnit.slash, line[index] != CodeUnit.asterisk else { return nil }
        while index < count {
            let unit = line[index]
            if unit == CodeUnit.backslash {
                index += 2
                continue
            }
            if unit == CodeUnit.openBracket {
                inClass = true
            } else if unit == CodeUnit.closeBracket {
                inClass = false
            } else if unit == CodeUnit.slash, !inClass {
                index += 1
                while index < count, CodeUnit.isLetter(line[index]) { index += 1 }
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: - Labels and attributes

    /// `target:` at the very start of a line (Makefiles). Excludes `:=` assignments.
    private func lineStartLabelEnd(_ line: [UInt16], at index: Int) -> Int? {
        guard index == 0, CodeUnit.isIdentifierStart(line[0]) || line[0] == CodeUnit.dot else { return nil }
        var end = 0
        while end < line.count, CodeUnit.isIdentifierPart(line[end]) || line[end] == CodeUnit.dot || line[end] == CodeUnit.minus || line[end] == CodeUnit.slash {
            end += 1
        }
        guard end < line.count, line[end] == CodeUnit.colon else { return nil }
        if end + 1 < line.count, line[end + 1] == CodeUnit.equals { return nil }
        return end
    }

    /// End of a bracketed attribute such as `#[derive(Debug)]`, honoring nesting.
    private func matchingBracketEnd(_ line: [UInt16], from start: Int) -> Int {
        var depth = 1
        var index = start
        while index < line.count {
            if line[index] == CodeUnit.openBracket {
                depth += 1
            } else if line[index] == CodeUnit.closeBracket {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return line.count
    }
}
