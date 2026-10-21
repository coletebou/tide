import Foundation

/// Collects tokens in order, merging adjacent tokens of the same kind.
struct TokenSink {
    var tokens: [Token] = []

    mutating func emit(_ kind: TokenKind, _ start: Int, _ end: Int) {
        guard end > start, kind != .plain else { return }
        if let last = tokens.last, last.kind == kind, last.end == start {
            tokens[tokens.count - 1].length += end - start
        } else {
            tokens.append(Token(start: start, length: end - start, kind: kind))
        }
    }

    /// Appends tokens produced for a slice that starts at `offset`.
    mutating func append(_ embedded: [Token], offset: Int) {
        for token in embedded {
            emit(token.kind, token.start + offset, token.end + offset)
        }
    }
}

extension Array where Element == UInt16 {
    func firstIndex(of pattern: [UInt16], from start: Int) -> Int? {
        guard !pattern.isEmpty, start <= count - pattern.count else { return nil }
        var index = Swift.max(start, 0)
        while index <= count - pattern.count {
            if hasPrefix(pattern, at: index) { return index }
            index += 1
        }
        return nil
    }

    func firstIndexIgnoringCase(of pattern: [UInt16], from start: Int) -> Int? {
        guard !pattern.isEmpty, start <= count - pattern.count else { return nil }
        var index = Swift.max(start, 0)
        while index <= count - pattern.count {
            if hasPrefixIgnoringCase(pattern, at: index) { return index }
            index += 1
        }
        return nil
    }
}

/// Resolves a fenced-code info string or script type to a language id.
func embeddedLanguageID(_ name: String) -> String {
    let lower = name.lowercased()
    guard !lower.isEmpty else { return "plaintext" }
    let registry = LanguageRegistry.shared
    if let language = registry.language(id: lower) { return language.id }
    let aliases = ["js": "javascript", "ts": "typescript", "py": "python", "sh": "shellscript", "bash": "shellscript",
                   "zsh": "shellscript", "shell": "shellscript", "console": "shellscript", "yml": "yaml", "md": "markdown",
                   "objc": "objective-c", "c++": "cpp", "cs": "csharp", "rb": "ruby", "rs": "rust", "kt": "kotlin",
                   "jsx": "javascript", "tsx": "typescript", "html": "html", "xml": "xml", "patch": "diff"]
    if let id = aliases[lower] { return id }
    let byExtension = registry.language(forFileName: "file.\(lower)")
    return byExtension.id
}

// MARK: - Markdown

struct MarkdownTokenizer: LineTokenizer {
    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        let count = line.count
        var sink = TokenSink()
        let start = line.skippingWhitespace(from: 0)

        if case let .markdownFence(fence, language, inner) = state {
            let marker = fence.utf16Array
            if start <= 3, start < count, line.hasPrefix(marker, at: start) {
                var end = start
                while end < count, line[end] == marker[0] { end += 1 }
                if end - start >= marker.count, line.skippingWhitespace(from: end) == count {
                    sink.emit(.punctuation, start, end)
                    return (sink.tokens, .root)
                }
            }
            if language != "plaintext", let tokenizer = LanguageRegistry.shared.tokenizer(forID: language) {
                let (tokens, innerEnd) = tokenizer.tokenize(line, state: inner)
                return (tokens, .markdownFence(fence: fence, language: language, inner: innerEnd))
            }
            sink.emit(.code, 0, count)
            return (sink.tokens, state)
        }

        guard start < count else { return ([], .root) }
        let first = line[start]

        // Fenced code block opener: ``` or ~~~ with an optional info string.
        if start <= 3, first == CodeUnit.backtick || first == CodeUnit.tilde {
            var end = start
            while end < count, line[end] == first { end += 1 }
            if end - start >= 3 {
                let info = line.string(end..<count).trimmingCharacters(in: .whitespaces)
                let languageName = info.split(separator: " ").first.map(String.init) ?? ""
                sink.emit(.punctuation, start, end)
                sink.emit(.keyword, end, count)
                let fence = String(repeating: first == CodeUnit.backtick ? "`" : "~", count: end - start)
                return (sink.tokens, .markdownFence(fence: fence, language: embeddedLanguageID(languageName), inner: .root))
            }
        }

        if start <= 3, first == CodeUnit.hash {
            var end = start
            while end < count, line[end] == CodeUnit.hash { end += 1 }
            if end - start <= 6, end == count || CodeUnit.isWhitespace(line[end]) {
                sink.emit(.heading, start, count)
                return (sink.tokens, .root)
            }
        }

        if start <= 3, first == CodeUnit.greaterThan {
            sink.emit(.quote, start, count)
            return (sink.tokens, .root)
        }

        if isThematicBreak(line, from: start) {
            sink.emit(.listMarker, start, count)
            return (sink.tokens, .root)
        }

        var index = start
        if let markerEnd = listMarkerEnd(line, at: start) {
            sink.emit(.listMarker, start, markerEnd)
            index = markerEnd
            // Task list checkbox: - [ ] or - [x]
            let box = line.skippingWhitespace(from: index)
            if box + 2 < count, line[box] == CodeUnit.openBracket, line[box + 2] == CodeUnit.closeBracket {
                sink.emit(.keyword, box, box + 3)
                index = box + 3
            }
        }
        scanInline(line, from: index, into: &sink)
        return (sink.tokens, .root)
    }

    private func isThematicBreak(_ line: [UInt16], from start: Int) -> Bool {
        guard start <= 3, start < line.count else { return false }
        let marker = line[start]
        guard marker == CodeUnit.minus || marker == CodeUnit.asterisk || marker == CodeUnit.underscore else { return false }
        var markers = 0
        for unit in line[start...] {
            if unit == marker {
                markers += 1
            } else if !CodeUnit.isWhitespace(unit) {
                return false
            }
        }
        return markers >= 3
    }

    private func listMarkerEnd(_ line: [UInt16], at start: Int) -> Int? {
        let count = line.count
        let first = line[start]
        if first == CodeUnit.minus || first == CodeUnit.asterisk || first == CodeUnit.plus {
            if start + 1 == count || CodeUnit.isWhitespace(line[start + 1]) { return start + 1 }
            return nil
        }
        var end = start
        while end < count, CodeUnit.isDigit(line[end]), end - start < 9 { end += 1 }
        if end > start, end < count, line[end] == CodeUnit.dot || line[end] == CodeUnit.closeParen,
           end + 1 == count || CodeUnit.isWhitespace(line[end + 1]) {
            return end + 1
        }
        return nil
    }

    private func scanInline(_ line: [UInt16], from start: Int, into sink: inout TokenSink) {
        let count = line.count
        var index = start
        while index < count {
            let unit = line[index]
            if unit == CodeUnit.backslash {
                index += 2
                continue
            }
            if unit == CodeUnit.backtick {
                var runEnd = index
                while runEnd < count, line[runEnd] == CodeUnit.backtick { runEnd += 1 }
                let run = runEnd - index
                var cursor = runEnd
                var closeEnd: Int?
                while cursor < count {
                    if line[cursor] == CodeUnit.backtick {
                        var end = cursor
                        while end < count, line[end] == CodeUnit.backtick { end += 1 }
                        if end - cursor == run {
                            closeEnd = end
                            break
                        }
                        cursor = end
                    } else {
                        cursor += 1
                    }
                }
                if let closeEnd {
                    sink.emit(.code, index, closeEnd)
                    index = closeEnd
                } else {
                    index = runEnd
                }
                continue
            }
            if unit == CodeUnit.asterisk || unit == CodeUnit.underscore {
                if index + 1 < count, line[index + 1] == unit {
                    let marker = [unit, unit]
                    if let close = line.firstIndex(of: marker, from: index + 2), close > index + 2 {
                        sink.emit(.strong, index, close + 2)
                        index = close + 2
                        continue
                    }
                } else if index + 1 < count, !CodeUnit.isWhitespace(line[index + 1]),
                          !(unit == CodeUnit.underscore && index > 0 && CodeUnit.isIdentifierPart(line[index - 1])) {
                    var close = index + 1
                    while close < count, !(line[close] == unit && !CodeUnit.isWhitespace(line[close - 1])) { close += 1 }
                    if close < count, close > index + 1 {
                        sink.emit(.emphasis, index, close + 1)
                        index = close + 1
                        continue
                    }
                }
            }
            if unit == CodeUnit.openBracket || (unit == CodeUnit.exclamation && index + 1 < count && line[index + 1] == CodeUnit.openBracket) {
                let textStart = unit == CodeUnit.exclamation ? index + 1 : index
                if let closeBracket = line[textStart...].firstIndex(of: CodeUnit.closeBracket),
                   closeBracket + 1 < count, line[closeBracket + 1] == CodeUnit.openParen,
                   let closeParen = line[(closeBracket + 1)...].firstIndex(of: CodeUnit.closeParen) {
                    sink.emit(.link, index, closeBracket + 1)
                    sink.emit(.string, closeBracket + 1, closeParen + 1)
                    index = closeParen + 1
                    continue
                }
            }
            if unit == CodeUnit.lessThan, index + 1 < count {
                if line.hasPrefix("<!--".utf16Array, at: index) {
                    let close = line.firstIndex(of: "-->".utf16Array, from: index + 4).map { $0 + 3 } ?? count
                    sink.emit(.comment, index, close)
                    index = close
                    continue
                }
                let next = line[index + 1]
                if CodeUnit.isLetter(next) || next == CodeUnit.slash,
                   let close = line[(index + 1)...].firstIndex(of: CodeUnit.greaterThan) {
                    sink.emit(.tag, index, close + 1)
                    index = close + 1
                    continue
                }
            }
            index += 1
        }
    }
}

// MARK: - HTML and XML

struct MarkupTokenizer: LineTokenizer {
    let html: Bool

    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        var sink = TokenSink()
        var index = 0
        var state = state
        let count = line.count

        while true {
            switch state {
            case .markupComment:
                if let close = line.firstIndex(of: "-->".utf16Array, from: index) {
                    sink.emit(.comment, index, close + 3)
                    index = close + 3
                    state = .root
                } else {
                    sink.emit(.comment, index, count)
                    return (sink.tokens, .markupComment)
                }

            case .markupTag(let quote):
                let result = scanTagBody(line, from: index, quote: quote, sink: &sink)
                index = result.end
                if let open = result.openQuote {
                    return (sink.tokens, .markupTag(quote: open))
                }
                if !result.closed { return (sink.tokens, .markupTag(quote: 0)) }
                state = .root

            case let .markupEmbedded(tag, language, inner):
                let close = line.firstIndexIgnoringCase(of: "</\(tag)".utf16Array, from: index)
                let end = close ?? count
                var innerEnd = inner
                if end > index, let tokenizer = LanguageRegistry.shared.tokenizer(forID: language) {
                    let result = tokenizer.tokenize(Array(line[index..<end]), state: inner)
                    sink.append(result.tokens, offset: index)
                    innerEnd = result.endState
                }
                guard close != nil else {
                    return (sink.tokens, .markupEmbedded(tag: tag, language: language, inner: innerEnd))
                }
                index = end
                state = .root

            default:
                guard index < count else { return (sink.tokens, .root) }
                let unit = line[index]
                if unit == CodeUnit.lessThan {
                    if line.hasPrefix("<!--".utf16Array, at: index) {
                        sink.emit(.comment, index, index + 4)
                        index += 4
                        state = .markupComment
                        continue
                    }
                    if line.hasPrefix("<![CDATA[".utf16Array, at: index) {
                        let close = line.firstIndex(of: "]]>".utf16Array, from: index).map { $0 + 3 } ?? count
                        sink.emit(.string, index, close)
                        index = close
                        continue
                    }
                    if index + 1 < count, line[index + 1] == CodeUnit.exclamation || line[index + 1] == CodeUnit.question {
                        let close = line[index...].firstIndex(of: CodeUnit.greaterThan).map { $0 + 1 } ?? count
                        sink.emit(.keyword, index, close)
                        index = close
                        continue
                    }
                    if index + 1 < count, line[index + 1] == CodeUnit.slash {
                        sink.emit(.punctuation, index, index + 2)
                        let nameEnd = tagNameEnd(line, from: index + 2)
                        sink.emit(.tag, index + 2, nameEnd)
                        index = line.skippingWhitespace(from: nameEnd)
                        if index < count, line[index] == CodeUnit.greaterThan {
                            sink.emit(.punctuation, index, index + 1)
                            index += 1
                        }
                        continue
                    }
                    if index + 1 < count, CodeUnit.isLetter(line[index + 1]) {
                        sink.emit(.punctuation, index, index + 1)
                        let nameEnd = tagNameEnd(line, from: index + 1)
                        let name = line.string((index + 1)..<nameEnd).lowercased()
                        sink.emit(.tag, index + 1, nameEnd)
                        let result = scanTagBody(line, from: nameEnd, quote: 0, sink: &sink)
                        index = result.end
                        if let open = result.openQuote { return (sink.tokens, .markupTag(quote: open)) }
                        if !result.closed { return (sink.tokens, .markupTag(quote: 0)) }
                        if html, !result.selfClosing, name == "script" || name == "style" {
                            state = .markupEmbedded(tag: name, language: name == "script" ? "javascript" : "css", inner: .root)
                        }
                        continue
                    }
                    index += 1
                } else if unit == CodeUnit.ampersand {
                    var end = index + 1
                    while end < count, end - index < 12, CodeUnit.isIdentifierPart(line[end]) || line[end] == CodeUnit.hash { end += 1 }
                    if end < count, line[end] == CodeUnit.semicolon, end > index + 1 {
                        sink.emit(.constant, index, end + 1)
                        index = end + 1
                    } else {
                        index += 1
                    }
                } else {
                    index += 1
                }
            }
        }
    }

    private func tagNameEnd(_ line: [UInt16], from start: Int) -> Int {
        var end = start
        while end < line.count, CodeUnit.isIdentifierPart(line[end]) || line[end] == CodeUnit.minus || line[end] == CodeUnit.colon || line[end] == CodeUnit.dot {
            end += 1
        }
        return end
    }

    private struct TagScan {
        var end: Int
        var closed: Bool
        var selfClosing: Bool
        var openQuote: UInt16?
    }

    /// Scans attributes until `>` or `/>`.
    private func scanTagBody(_ line: [UInt16], from start: Int, quote: UInt16, sink: inout TokenSink) -> TagScan {
        let count = line.count
        var index = start
        if quote != 0 {
            guard let close = line[index...].firstIndex(of: quote) else {
                sink.emit(.string, index, count)
                return TagScan(end: count, closed: false, selfClosing: false, openQuote: quote)
            }
            sink.emit(.string, index, close + 1)
            index = close + 1
        }
        while index < count {
            let unit = line[index]
            if CodeUnit.isWhitespace(unit) {
                index += 1
            } else if unit == CodeUnit.greaterThan {
                sink.emit(.punctuation, index, index + 1)
                return TagScan(end: index + 1, closed: true, selfClosing: false, openQuote: nil)
            } else if unit == CodeUnit.slash, index + 1 < count, line[index + 1] == CodeUnit.greaterThan {
                sink.emit(.punctuation, index, index + 2)
                return TagScan(end: index + 2, closed: true, selfClosing: true, openQuote: nil)
            } else if unit == CodeUnit.quote || unit == CodeUnit.apostrophe {
                guard let close = line[(index + 1)...].firstIndex(of: unit) else {
                    sink.emit(.string, index, count)
                    return TagScan(end: count, closed: false, selfClosing: false, openQuote: unit)
                }
                sink.emit(.string, index, close + 1)
                index = close + 1
            } else if unit == CodeUnit.equals {
                sink.emit(.operatorSymbol, index, index + 1)
                index += 1
            } else {
                var end = index
                while end < count, !CodeUnit.isWhitespace(line[end]), ![CodeUnit.equals, CodeUnit.greaterThan, CodeUnit.quote, CodeUnit.apostrophe].contains(line[end]),
                      !(line[end] == CodeUnit.slash && end + 1 < count && line[end + 1] == CodeUnit.greaterThan) {
                    end += 1
                }
                end = max(end, index + 1)
                sink.emit(.attributeName, index, end)
                index = end
            }
        }
        return TagScan(end: count, closed: false, selfClosing: false, openQuote: nil)
    }
}

// MARK: - CSS, SCSS, Less

struct CSSTokenizer: LineTokenizer {
    /// Whether `//` starts a comment (SCSS and Less).
    let lineComments: Bool

    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        var sink = TokenSink()
        var depth = 0
        var index = 0
        let count = line.count
        if case let .css(savedDepth, inComment) = state {
            depth = savedDepth
            if inComment {
                guard let close = line.firstIndex(of: "*/".utf16Array, from: 0) else {
                    sink.emit(.comment, 0, count)
                    return (sink.tokens, state)
                }
                sink.emit(.comment, 0, close + 2)
                index = close + 2
            }
        }
        var expectingValue = false
        while index < count {
            let unit = line[index]
            if CodeUnit.isWhitespace(unit) {
                index += 1
                continue
            }
            if line.hasPrefix("/*".utf16Array, at: index) {
                guard let close = line.firstIndex(of: "*/".utf16Array, from: index + 2) else {
                    sink.emit(.comment, index, count)
                    return (sink.tokens, .css(depth: depth, inComment: true))
                }
                sink.emit(.comment, index, close + 2)
                index = close + 2
                continue
            }
            if lineComments, line.hasPrefix("//".utf16Array, at: index) {
                sink.emit(.comment, index, count)
                break
            }
            switch unit {
            case CodeUnit.openBrace:
                depth += 1
                expectingValue = false
                sink.emit(.punctuation, index, index + 1)
                index += 1
                continue
            case CodeUnit.closeBrace:
                depth = max(0, depth - 1)
                expectingValue = false
                sink.emit(.punctuation, index, index + 1)
                index += 1
                continue
            case CodeUnit.semicolon:
                expectingValue = false
                sink.emit(.punctuation, index, index + 1)
                index += 1
                continue
            case CodeUnit.quote, CodeUnit.apostrophe:
                let close = line[(index + 1)...].firstIndex(of: unit).map { $0 + 1 } ?? count
                sink.emit(.string, index, close)
                index = close
                continue
            case CodeUnit.at:
                let end = wordEnd(line, from: index + 1)
                sink.emit(.control, index, end)
                index = end
                continue
            case CodeUnit.dollar:
                let end = wordEnd(line, from: index + 1)
                sink.emit(.variable, index, end)
                index = end
                continue
            default:
                break
            }

            if depth == 0 || (!expectingValue && !isPropertyStart(line, at: index)) {
                // Selector context.
                if unit == CodeUnit.openBracket {
                    let close = line[index...].firstIndex(of: CodeUnit.closeBracket).map { $0 + 1 } ?? count
                    sink.emit(.attributeName, index, close)
                    index = close
                } else if unit == CodeUnit.comma || unit == CodeUnit.greaterThan || unit == CodeUnit.plus || unit == CodeUnit.tilde {
                    sink.emit(.operatorSymbol, index, index + 1)
                    index += 1
                } else {
                    var end = index
                    while end < count, !CodeUnit.isWhitespace(line[end]), ![CodeUnit.openBrace, CodeUnit.comma, CodeUnit.openBracket, CodeUnit.semicolon, CodeUnit.closeBrace].contains(line[end]) {
                        end += 1
                    }
                    end = max(end, index + 1)
                    sink.emit(.selector, index, end)
                    index = end
                }
                continue
            }

            if !expectingValue {
                let end = wordEnd(line, from: index)
                sink.emit(.property, index, end)
                index = line.skippingWhitespace(from: end)
                if index < count, line[index] == CodeUnit.colon {
                    sink.emit(.punctuation, index, index + 1)
                    index += 1
                    expectingValue = true
                }
                continue
            }

            // Value context.
            if CodeUnit.isDigit(unit) || ((unit == CodeUnit.dot || unit == CodeUnit.minus) && index + 1 < count && CodeUnit.isDigit(line[index + 1])) {
                var end = index + 1
                while end < count, CodeUnit.isDigit(line[end]) || line[end] == CodeUnit.dot { end += 1 }
                while end < count, CodeUnit.isLetter(line[end]) || line[end] == 0x25 /* % */ { end += 1 }
                sink.emit(.number, index, end)
                index = end
            } else if unit == CodeUnit.hash {
                let end = wordEnd(line, from: index + 1)
                sink.emit(.number, index, end)
                index = end
            } else if unit == CodeUnit.exclamation {
                let end = wordEnd(line, from: index + 1)
                sink.emit(.keyword, index, end)
                index = end
            } else if CodeUnit.isIdentifierStart(unit) || unit == CodeUnit.minus {
                let end = wordEnd(line, from: index)
                let isFunction = end < count && line[end] == CodeUnit.openParen
                sink.emit(isFunction ? .function : .string, index, end)
                index = end
            } else {
                sink.emit(.punctuation, index, index + 1)
                index += 1
            }
        }
        return (sink.tokens, .css(depth: depth, inComment: false))
    }

    /// The end of the word at `start`, taking at least one unit but never
    /// going past the line: after a sigil that ends the line, that is `start`.
    private func wordEnd(_ line: [UInt16], from start: Int) -> Int {
        var end = start
        while end < line.count, CodeUnit.isIdentifierPart(line[end]) || line[end] == CodeUnit.minus { end += 1 }
        return min(max(end, start + 1), line.count)
    }

    /// Inside a block, `name:` followed by a value (not a nested selector like `&:hover {`).
    private func isPropertyStart(_ line: [UInt16], at index: Int) -> Bool {
        guard CodeUnit.isIdentifierStart(line[index]) || line[index] == CodeUnit.minus else { return false }
        let end = wordEnd(line, from: index)
        let colon = line.skippingWhitespace(from: end)
        guard colon < line.count, line[colon] == CodeUnit.colon else { return false }
        return !line[colon...].contains(CodeUnit.openBrace)
    }
}

// MARK: - YAML

struct YAMLTokenizer: LineTokenizer {
    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        var sink = TokenSink()
        let count = line.count
        var index = line.skippingWhitespace(from: 0)
        guard index < count else { return ([], .root) }

        if line[index] == CodeUnit.hash {
            sink.emit(.comment, index, count)
            return (sink.tokens, .root)
        }
        if index == 0, line.hasPrefix("---".utf16Array, at: 0) || line.hasPrefix("...".utf16Array, at: 0),
           count == 3 || CodeUnit.isWhitespace(line[3]) {
            sink.emit(.punctuation, 0, 3)
            index = 3
        }
        while index < count, line[index] == CodeUnit.minus, index + 1 == count || CodeUnit.isWhitespace(line[index + 1]) {
            sink.emit(.listMarker, index, index + 1)
            index = line.skippingWhitespace(from: index + 1)
        }
        if let colon = keyColon(line, from: index) {
            var keyEnd = colon
            while keyEnd > index, CodeUnit.isWhitespace(line[keyEnd - 1]) { keyEnd -= 1 }
            sink.emit(.tag, index, keyEnd)
            sink.emit(.punctuation, colon, colon + 1)
            index = colon + 1
        }
        scanValue(line, from: index, into: &sink)
        return (sink.tokens, .root)
    }

    /// The `:` ending a mapping key, outside quotes and before any comment.
    private func keyColon(_ line: [UInt16], from start: Int) -> Int? {
        var index = start
        var quote: UInt16 = 0
        while index < line.count {
            let unit = line[index]
            if quote != 0 {
                if unit == quote { quote = 0 }
            } else if unit == CodeUnit.quote || unit == CodeUnit.apostrophe {
                if index == start { quote = unit } else { return nil }
            } else if unit == CodeUnit.hash, index > start, CodeUnit.isWhitespace(line[index - 1]) {
                return nil
            } else if unit == CodeUnit.colon, index + 1 == line.count || CodeUnit.isWhitespace(line[index + 1]) {
                return index > start ? index : nil
            } else if index == start, [CodeUnit.openBracket, CodeUnit.openBrace, CodeUnit.ampersand, CodeUnit.asterisk, CodeUnit.exclamation, CodeUnit.pipe, CodeUnit.greaterThan].contains(unit) {
                return nil
            }
            index += 1
        }
        return nil
    }

    private static let constants: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~", "True", "False", "TRUE", "FALSE", "Null", "NULL"]

    private func scanValue(_ line: [UInt16], from start: Int, into sink: inout TokenSink) {
        let count = line.count
        var index = line.skippingWhitespace(from: start)
        while index < count {
            let unit = line[index]
            if CodeUnit.isWhitespace(unit) {
                index += 1
                continue
            }
            if unit == CodeUnit.hash, index == 0 || CodeUnit.isWhitespace(line[index - 1]) {
                sink.emit(.comment, index, count)
                return
            }
            if unit == CodeUnit.quote || unit == CodeUnit.apostrophe {
                var close = index + 1
                while close < count, line[close] != unit || (unit == CodeUnit.quote && line[close - 1] == CodeUnit.backslash) { close += 1 }
                let end = min(count, close + 1)
                sink.emit(.string, index, end)
                index = end
                continue
            }
            if unit == CodeUnit.ampersand || unit == CodeUnit.asterisk {
                let end = scalarEnd(line, from: index, flow: false)
                sink.emit(.type, index, end)
                index = end
                continue
            }
            if unit == CodeUnit.exclamation || ((unit == CodeUnit.pipe || unit == CodeUnit.greaterThan) && index == line.skippingWhitespace(from: start)) {
                let end = scalarEnd(line, from: index, flow: false)
                sink.emit(.keyword, index, end)
                index = end
                continue
            }
            if [CodeUnit.openBracket, CodeUnit.closeBracket, CodeUnit.openBrace, CodeUnit.closeBrace, CodeUnit.comma, CodeUnit.colon].contains(unit) {
                sink.emit(.punctuation, index, index + 1)
                index += 1
                continue
            }
            let flow = line[..<index].contains(CodeUnit.openBracket) || line[..<index].contains(CodeUnit.openBrace)
            let end = scalarEnd(line, from: index, flow: flow)
            let word = line.string(index..<end).trimmingCharacters(in: .whitespaces)
            let kind: TokenKind
            if Self.constants.contains(word) {
                kind = .constant
            } else if Double(word.replacingOccurrences(of: "_", with: "")) != nil || word.hasPrefix("0x") {
                kind = .number
            } else {
                kind = .string
            }
            sink.emit(kind, index, end)
            index = end
        }
    }

    /// End of a plain scalar: up to ` #`, or `,`/`]`/`}` inside flow collections.
    private func scalarEnd(_ line: [UInt16], from start: Int, flow: Bool) -> Int {
        var end = start
        while end < line.count {
            let unit = line[end]
            if unit == CodeUnit.hash, end > start, CodeUnit.isWhitespace(line[end - 1]) { break }
            if flow, [CodeUnit.comma, CodeUnit.closeBracket, CodeUnit.closeBrace].contains(unit) { break }
            if flow, unit == CodeUnit.colon, end + 1 < line.count, CodeUnit.isWhitespace(line[end + 1]) { break }
            end += 1
        }
        while end > start + 1, CodeUnit.isWhitespace(line[end - 1]) { end -= 1 }
        return max(end, start + 1)
    }
}

// MARK: - INI, TOML, .env, properties

struct INITokenizer: LineTokenizer {
    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        var sink = TokenSink()
        let count = line.count
        var index = line.skippingWhitespace(from: 0)
        guard index < count else { return ([], .root) }
        let first = line[index]
        if first == CodeUnit.hash || first == CodeUnit.semicolon {
            sink.emit(.comment, index, count)
            return (sink.tokens, .root)
        }
        if first == CodeUnit.openBracket {
            let close = line.lastIndex(of: CodeUnit.closeBracket).map { $0 + 1 } ?? count
            sink.emit(.type, index, close)
            index = close
            scanValue(line, from: index, into: &sink)
            return (sink.tokens, .root)
        }
        if line.hasPrefix("export ".utf16Array, at: index) {
            sink.emit(.keyword, index, index + 6)
            index = line.skippingWhitespace(from: index + 6)
        }
        guard let separator = line[index...].firstIndex(where: { $0 == CodeUnit.equals || $0 == CodeUnit.colon }) else {
            sink.emit(.property, index, count)
            return (sink.tokens, .root)
        }
        var keyEnd = separator
        while keyEnd > index, CodeUnit.isWhitespace(line[keyEnd - 1]) { keyEnd -= 1 }
        sink.emit(.property, index, keyEnd)
        sink.emit(.operatorSymbol, separator, separator + 1)
        scanValue(line, from: separator + 1, into: &sink)
        return (sink.tokens, .root)
    }

    private func scanValue(_ line: [UInt16], from start: Int, into sink: inout TokenSink) {
        let count = line.count
        var index = line.skippingWhitespace(from: start)
        while index < count {
            let unit = line[index]
            if CodeUnit.isWhitespace(unit) {
                index += 1
            } else if unit == CodeUnit.hash || unit == CodeUnit.semicolon {
                sink.emit(.comment, index, count)
                return
            } else if unit == CodeUnit.quote || unit == CodeUnit.apostrophe {
                var close = index + 1
                while close < count, line[close] != unit || (unit == CodeUnit.quote && line[close - 1] == CodeUnit.backslash) { close += 1 }
                let end = min(count, close + 1)
                sink.emit(.string, index, end)
                index = end
            } else if [CodeUnit.openBracket, CodeUnit.closeBracket, CodeUnit.openBrace, CodeUnit.closeBrace, CodeUnit.comma, CodeUnit.equals].contains(unit) {
                sink.emit(.punctuation, index, index + 1)
                index += 1
            } else {
                var end = index
                while end < count, !CodeUnit.isWhitespace(line[end]), ![CodeUnit.comma, CodeUnit.closeBracket, CodeUnit.closeBrace].contains(line[end]) { end += 1 }
                let word = line.string(index..<end)
                let kind: TokenKind
                if word == "true" || word == "false" {
                    kind = .constant
                } else if Double(word.replacingOccurrences(of: "_", with: "")) != nil || (word.first?.isNumber ?? false) {
                    kind = .number
                } else {
                    kind = .string
                }
                sink.emit(kind, index, end)
                index = end
            }
        }
    }
}

// MARK: - Diff

struct DiffTokenizer: LineTokenizer {
    func tokenize(_ line: [UInt16], state: LineState) -> (tokens: [Token], endState: LineState) {
        guard let first = line.first else { return ([], .root) }
        let kind: TokenKind
        if line.hasPrefix("+++".utf16Array, at: 0) || line.hasPrefix("---".utf16Array, at: 0)
            || line.hasPrefix("diff ".utf16Array, at: 0) || line.hasPrefix("index ".utf16Array, at: 0) {
            kind = .keyword
        } else if line.hasPrefix("@@".utf16Array, at: 0) {
            kind = .control
        } else if first == CodeUnit.plus {
            kind = .inserted
        } else if first == CodeUnit.minus {
            kind = .deleted
        } else {
            return ([], .root)
        }
        return ([Token(start: 0, length: line.count, kind: kind)], .root)
    }
}
