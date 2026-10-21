import Foundation

/// One replacement in a text plus the selection that should follow it. Editing
/// commands return a single covering replacement so the text view can apply
/// it as one undoable step.
public struct TextEdit: Equatable, Sendable {
    /// Range in the text before the edit.
    public var range: NSRange
    public var replacement: String
    /// Selection after the edit, in the edited text.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// Applies the edit to a string (convenient for tests).
    public func apply(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// Indentation settings for editing commands (`editor.tabSize`, `editor.insertSpaces`).
public struct Indentation: Equatable, Sendable {
    public var tabSize: Int
    public var insertSpaces: Bool

    public init(tabSize: Int = 4, insertSpaces: Bool = true) {
        self.tabSize = max(1, tabSize)
        self.insertSpaces = insertSpaces
    }

    public var unit: String { insertSpaces ? String(repeating: " ", count: tabSize) : "\t" }

    /// Visible width of leading whitespace, with tabs expanded.
    public func width(of whitespace: some StringProtocol) -> Int {
        var width = 0
        for character in whitespace {
            width = character == "\t" ? (width / tabSize + 1) * tabSize : width + 1
        }
        return width
    }

    /// Whitespace that renders `width` columns wide.
    public func whitespace(width: Int) -> String {
        if insertSpaces { return String(repeating: " ", count: max(0, width)) }
        return String(repeating: "\t", count: max(0, width) / tabSize) + String(repeating: " ", count: max(0, width) % tabSize)
    }

    /// Guesses indentation from file contents, like VS Code's `editor.detectIndentation`.
    public static func detect(in text: String, default fallback: Indentation = Indentation()) -> Indentation {
        var tabLines = 0
        var spaceLines = 0
        var deltas: [Int: Int] = [:]
        var previous = 0
        var scanned = 0
        text.enumerateLines { line, stop in
            scanned += 1
            if scanned > 10_000 { stop = true }
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            guard leading.count < line.count else { return }
            if leading.hasPrefix("\t") {
                tabLines += 1
            } else if !leading.isEmpty {
                spaceLines += 1
            }
            let spaces = leading.hasPrefix("\t") ? previous : leading.count
            let delta = abs(spaces - previous)
            if delta >= 2 && delta <= 8 { deltas[delta, default: 0] += 1 }
            previous = spaces
        }
        if tabLines > spaceLines { return Indentation(tabSize: fallback.tabSize, insertSpaces: false) }
        guard spaceLines > 0, let best = deltas.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else {
            return fallback
        }
        return Indentation(tabSize: best.key, insertSpaces: true)
    }
}

/// Pure editing operations behind the editor's keyboard behavior.
public enum TextEditing {
    /// Characters before which a bracket may auto-close (VS Code `autoCloseBefore`).
    static let autoCloseBefore: Set<Character> = [";", ":", ".", ",", "=", "}", "]", ")", ">", "`", " ", "\t", "\n", "\r"]

    // MARK: - Typing

    /// Behavior for a typed character: auto-closing pairs, typing over a
    /// closer, surrounding a selection, and re-indenting a lone closing
    /// bracket. Returns nil when the character should be inserted normally.
    public static func typeCharacter(
        _ character: String,
        in text: NSString,
        selection: NSRange,
        language: LanguageDefinition,
        indentation: Indentation = Indentation(),
        isInStringOrComment: Bool = false
    ) -> TextEdit? {
        guard character.utf16.count == 1 else { return nil }
        let pairs = language.autoClosingPairs
        let selectedText = text.substring(with: selection)

        // Surround a selection: "(" around "abc" gives "(abc)".
        if selection.length > 0, let pair = pairs.first(where: { $0.open == character }) {
            let replacement = pair.open + selectedText + pair.close
            let start = selection.location + (pair.open as NSString).length
            return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: start, length: selection.length))
        }
        guard selection.length == 0 else { return nil }
        let location = selection.location
        let next: Character? = location < text.length ? Character(text.substring(with: NSRange(location: location, length: 1))) : nil
        let previous: Character? = location > 0 ? Character(text.substring(with: NSRange(location: location - 1, length: 1))) : nil

        // Type over a closer that is already there.
        if let next, String(next) == character, pairs.contains(where: { $0.close == character }) {
            let isQuote = pairs.contains { $0.open == character && $0.close == character }
            if !isQuote || isInStringOrComment || previous.map({ !$0.isWhitespace }) ?? false {
                return TextEdit(range: NSRange(location: location, length: 0), replacement: "", selection: NSRange(location: location + 1, length: 0))
            }
        }

        // A closing bracket typed on a whitespace-only line snaps to its opener's indentation.
        if let pair = language.brackets.first(where: { $0.close == character }) {
            let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
            if !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }),
               let open = matchingOpen(for: pair, before: lineStart, in: text) {
                let openLine = text.lineRange(for: NSRange(location: open, length: 0))
                let openIndent = String(text.substring(with: openLine).prefix { $0 == " " || $0 == "\t" })
                if openIndent != before {
                    let replacement = openIndent + character
                    let caret = lineStart + (replacement as NSString).length
                    return TextEdit(range: NSRange(location: lineStart, length: location - lineStart), replacement: replacement, selection: NSRange(location: caret, length: 0))
                }
            }
        }

        // Auto-close an opener.
        if let pair = pairs.first(where: { $0.open == character }), !isInStringOrComment {
            let isQuote = pair.open == pair.close
            if let next, !autoCloseBefore.contains(next) { return nil }
            if isQuote, let previous, previous.isLetter || previous.isNumber || previous == "_" || String(previous) == pair.open { return nil }
            let replacement = pair.open + pair.close
            return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: location + (pair.open as NSString).length, length: 0))
        }
        return nil
    }

    /// Enter with auto-indent: keeps the current indentation, indents after an
    /// opening bracket (or a language suffix such as Python's `:`), and splits
    /// `{|}` onto three lines.
    public static func newline(in text: NSString, selection: NSRange, language: LanguageDefinition, indentation: Indentation = Indentation(), lineEnding: String = "\n") -> TextEdit {
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineStart = lineRange.location
        let before = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let afterEnd = NSMaxRange(selection)
        let lineContentEnd = lineContentEnd(of: lineRange, in: text)
        let after = afterEnd <= lineContentEnd ? text.substring(with: NSRange(location: afterEnd, length: lineContentEnd - afterEnd)) : ""
        let baseIndent = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        let trimmedAfter = after.trimmingCharacters(in: .whitespaces)

        var indent = baseIndent
        let opener = language.brackets.first { trimmedBefore.hasSuffix($0.open) }
        if opener != nil || language.indentAfterSuffixes.contains(where: { !$0.isEmpty && trimmedBefore.hasSuffix($0) }) {
            indent += indentation.unit
        } else if language.id == "python", let keyword = trimmedBefore.split(separator: " ").first,
                  ["return", "pass", "break", "continue", "raise"].contains(String(keyword)) {
            let width = max(0, indentation.width(of: baseIndent) - indentation.tabSize)
            indent = indentation.whitespace(width: width)
        }

        if let opener, trimmedAfter.hasPrefix(opener.close) {
            let replacement = lineEnding + indent + lineEnding + baseIndent
            let caret = selection.location + (lineEnding as NSString).length + (indent as NSString).length
            return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: caret, length: 0))
        }
        let replacement = lineEnding + indent
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
    }

    /// Backspace: deletes an empty auto-closed pair `(|)` together, and in
    /// leading spaces deletes back to the previous tab stop.
    public static func deleteBackward(in text: NSString, selection: NSRange, language: LanguageDefinition, indentation: Indentation = Indentation()) -> TextEdit? {
        guard selection.length == 0, selection.location > 0 else { return nil }
        let location = selection.location
        if location < text.length {
            let pairText = text.substring(with: NSRange(location: location - 1, length: 2))
            if language.autoClosingPairs.contains(where: { $0.open + $0.close == pairText }) {
                return TextEdit(range: NSRange(location: location - 1, length: 2), replacement: "", selection: NSRange(location: location - 1, length: 0))
            }
        }
        guard indentation.insertSpaces else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
        guard before.count >= 2, before.allSatisfy({ $0 == " " }) else { return nil }
        let remove = before.count % indentation.tabSize == 0 ? indentation.tabSize : before.count % indentation.tabSize
        return TextEdit(range: NSRange(location: location - remove, length: remove), replacement: "", selection: NSRange(location: location - remove, length: 0))
    }

    /// Tab: inserts spaces to the next tab stop (or a tab), or indents the
    /// selected lines when the selection spans lines.
    public static func insertTab(in text: NSString, selection: NSRange, indentation: Indentation = Indentation()) -> TextEdit {
        let selectedLines = lineBlock(for: selection, in: text)
        if selection.length > 0, text.substring(with: selection).contains(where: \.isNewline) || selection.length == selectedLines.contentLength {
            return indentLines(in: text, selection: selection, indentation: indentation)
        }
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = indentation.width(of: text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart)))
        let insert = indentation.insertSpaces ? String(repeating: " ", count: indentation.tabSize - column % indentation.tabSize) : "\t"
        return TextEdit(range: selection, replacement: insert, selection: NSRange(location: selection.location + (insert as NSString).length, length: 0))
    }

    // MARK: - Line commands

    /// Toggles line comments on the selected lines (⌘/). Languages without line
    /// comments toggle a block comment around the lines instead.
    public static func toggleLineComment(in text: NSString, selection: NSRange, language: LanguageDefinition) -> TextEdit? {
        let block = lineBlock(for: selection, in: text)
        let lines = block.lines
        if let token = language.lineComment {
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonEmpty.isEmpty else { return nil }
            let allCommented = nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(token) }
            let minIndent = nonEmpty.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            var delta = 0
            var firstLineDelta = 0
            let newLines = lines.enumerated().map { index, line -> String in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                var result: String
                if allCommented {
                    let indentCount = line.prefix { $0 == " " || $0 == "\t" }.count
                    var rest = String(line.dropFirst(indentCount).dropFirst(token.count))
                    if rest.hasPrefix(" ") { rest.removeFirst() }
                    result = String(line.prefix(indentCount)) + rest
                } else {
                    result = String(line.prefix(minIndent)) + token + " " + String(line.dropFirst(minIndent))
                }
                let change = (result as NSString).length - (line as NSString).length
                if index == 0 { firstLineDelta = change }
                delta += change
                return result
            }
            let replacement = block.joined(newLines)
            return TextEdit(range: block.range, replacement: replacement, selection: adjustedSelection(selection, block: block, firstLineDelta: firstLineDelta, totalDelta: delta, editColumn: minIndent))
        }
        guard let comment = language.blockComment else { return nil }
        let content = text.substring(with: block.range)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(comment.open), trimmed.hasSuffix(comment.close), trimmed.count >= comment.open.count + comment.close.count {
            var inner = String(trimmed.dropFirst(comment.open.count).dropLast(comment.close.count))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            let leading = String(content.prefix { $0 == " " || $0 == "\t" })
            let replacement = leading + inner
            return TextEdit(range: block.range, replacement: replacement, selection: NSRange(location: block.range.location, length: (replacement as NSString).length))
        }
        let leading = String(content.prefix { $0 == " " || $0 == "\t" })
        let replacement = leading + comment.open + " " + content.dropFirst(leading.count) + " " + comment.close
        return TextEdit(range: block.range, replacement: replacement, selection: NSRange(location: block.range.location, length: (replacement as NSString).length))
    }

    /// Indents the selected lines by one unit (⌘]).
    public static func indentLines(in text: NSString, selection: NSRange, indentation: Indentation = Indentation()) -> TextEdit {
        let block = lineBlock(for: selection, in: text)
        var firstLineDelta = 0
        var delta = 0
        let newLines = block.lines.enumerated().map { index, line -> String in
            guard !line.isEmpty else { return line }
            let change = (indentation.unit as NSString).length
            if index == 0 { firstLineDelta = change }
            delta += change
            return indentation.unit + line
        }
        return TextEdit(range: block.range, replacement: block.joined(newLines), selection: adjustedSelection(selection, block: block, firstLineDelta: firstLineDelta, totalDelta: delta))
    }

    /// Removes one unit of indentation from the selected lines (⌘[ or ⇧Tab).
    public static func outdentLines(in text: NSString, selection: NSRange, indentation: Indentation = Indentation()) -> TextEdit {
        let block = lineBlock(for: selection, in: text)
        var firstLineDelta = 0
        var delta = 0
        let newLines = block.lines.enumerated().map { index, line -> String in
            var removed = 0
            if line.hasPrefix("\t") {
                removed = 1
            } else {
                removed = min(indentation.tabSize, line.prefix { $0 == " " }.count)
            }
            if index == 0 { firstLineDelta = -removed }
            delta -= removed
            return String(line.dropFirst(removed))
        }
        return TextEdit(range: block.range, replacement: block.joined(newLines), selection: adjustedSelection(selection, block: block, firstLineDelta: firstLineDelta, totalDelta: delta))
    }

    /// Moves the selected lines up or down by one line (⌥↑ / ⌥↓). The line
    /// contents trade places and every line break stays where it was, so
    /// CRLF text keeps its line endings.
    public static func moveLines(up: Bool, in text: NSString, selection: NSRange) -> TextEdit? {
        let block = lineBlock(for: selection, in: text)
        let upper: NSRange
        let lower: NSRange
        if up {
            guard block.range.location > 0 else { return nil }
            let line = text.lineRange(for: NSRange(location: block.range.location - 1, length: 0))
            upper = NSRange(location: line.location, length: lineBreak(of: line, in: text).location - line.location)
            lower = block.range
        } else {
            // A block without a line break after it is already the last line.
            guard block.lineBreakAfter.length > 0 else { return nil }
            let line = text.lineRange(for: NSRange(location: NSMaxRange(block.lineBreakAfter), length: 0))
            upper = block.range
            lower = NSRange(location: line.location, length: lineBreak(of: line, in: text).location - line.location)
        }
        let separator = text.substring(with: NSRange(location: NSMaxRange(upper), length: lower.location - NSMaxRange(upper)))
        let distance = (up ? upper.length : lower.length) + (separator as NSString).length
        // A move keeps the text's length. A selection that ran on to the start
        // of the next line, moved down onto the last line, stops at the end.
        let location = min(max(0, selection.location + (up ? -distance : distance)), text.length)
        return TextEdit(
            range: NSRange(location: upper.location, length: NSMaxRange(lower) - upper.location),
            replacement: text.substring(with: lower) + separator + text.substring(with: upper),
            selection: NSRange(location: location, length: min(selection.length, text.length - location))
        )
    }

    /// Duplicates the selected lines below (⇧⌥↓) and selects the copy.
    public static func duplicateLines(in text: NSString, selection: NSRange) -> TextEdit {
        let block = lineBlock(for: selection, in: text)
        // Reuse the block's own line break, or on the last line the one before it.
        var separator = block.lineBreakAfter
        if separator.length == 0, block.range.location > 0 {
            separator = lineBreak(of: text.lineRange(for: NSRange(location: block.range.location - 1, length: 0)), in: text)
        }
        let insertion = (separator.length > 0 ? text.substring(with: separator) : "\n") + text.substring(with: block.range)
        return TextEdit(
            range: NSRange(location: NSMaxRange(block.range), length: 0),
            replacement: insertion,
            selection: NSRange(location: selection.location + (insertion as NSString).length, length: selection.length)
        )
    }

    /// Deletes the selected lines (⇧⌘K).
    public static func deleteLines(in text: NSString, selection: NSRange) -> TextEdit {
        let block = lineBlock(for: selection, in: text)
        var range = NSRange(location: block.range.location, length: NSMaxRange(block.lineBreakAfter) - block.range.location)
        if block.lineBreakAfter.length == 0, range.location > 0 {
            // The last line has no line break of its own, so the one before it goes.
            let previous = lineBreak(of: text.lineRange(for: NSRange(location: range.location - 1, length: 0)), in: text)
            range = NSRange(location: previous.location, length: NSMaxRange(range) - previous.location)
        }
        let caret = min(range.location, max(0, text.length - range.length))
        return TextEdit(range: range, replacement: "", selection: NSRange(location: caret, length: 0))
    }

    // MARK: - Brackets

    /// The matching bracket pair around or next to `offset`, as the offsets of
    /// the opening and closing bracket. `isCode` lets callers skip brackets in
    /// strings and comments.
    public static func matchingBracket(at offset: Int, in text: NSString, language: LanguageDefinition, isCode: (Int) -> Bool = { _ in true }) -> (open: Int, close: Int)? {
        let candidates = [offset, offset - 1].filter { $0 >= 0 && $0 < text.length }
        for position in candidates where isCode(position) {
            let character = text.substring(with: NSRange(location: position, length: 1))
            if let pair = language.brackets.first(where: { $0.open == character }) {
                if let close = scan(for: pair, from: position + 1, forward: true, in: text, isCode: isCode) { return (position, close) }
            } else if let pair = language.brackets.first(where: { $0.close == character }) {
                if let open = scan(for: pair, from: position - 1, forward: false, in: text, isCode: isCode) { return (open, position) }
            }
        }
        return nil
    }

    static func matchingOpen(for pair: BracketPair, before offset: Int, in text: NSString) -> Int? {
        scan(for: pair, from: offset - 1, forward: false, in: text, isCode: { _ in true })
    }

    private static func scan(for pair: BracketPair, from start: Int, forward: Bool, in text: NSString, isCode: (Int) -> Bool) -> Int? {
        guard let open = pair.open.utf16.first, let close = pair.close.utf16.first else { return nil }
        var depth = 0
        var position = start
        var steps = 0
        while position >= 0, position < text.length, steps < 200_000 {
            let unit = text.character(at: position)
            if unit == open || unit == close, isCode(position) {
                if unit == (forward ? open : close) {
                    depth += 1
                } else {
                    if depth == 0 { return position }
                    depth -= 1
                }
            }
            position += forward ? 1 : -1
            steps += 1
        }
        return nil
    }

    // MARK: - Helpers

    /// The full lines a selection touches. A selection ending at column 0 of a
    /// line does not include that line, matching VS Code.
    struct LineBlock {
        /// From the start of the first line to the end of the last line's content.
        var range: NSRange
        /// The line break after the last line, empty when that is the document's
        /// last line. Taken from the last line itself: when that line is blank,
        /// `range` ends where it starts, and the lines around `range` would
        /// leave it out.
        var lineBreakAfter: NSRange
        /// The lines' contents, without line breaks.
        var lines: [String]
        /// The line break after each line but the last: `\n`, `\r\n` or `\r`.
        var lineBreaks: [String]
        var contentLength: Int { range.length }

        /// Edited lines joined with the line breaks the block had.
        func joined(_ lines: [String]) -> String {
            var result = lines.first ?? ""
            for (line, lineBreak) in zip(lines.dropFirst(), lineBreaks) { result += lineBreak + line }
            return result
        }
    }

    static func lineBlock(for selection: NSRange, in text: NSString) -> LineBlock {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > 0, end <= text.length, text.character(at: end - 1) == 0x0A {
            end -= 1
        }
        let startLine = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let endLine = text.lineRange(for: NSRange(location: max(end, selection.location), length: 0))
        let start = startLine.location
        let contentEnd = lineContentEnd(of: endLine, in: text)
        let range = NSRange(location: start, length: max(0, contentEnd - start))
        // Split at the line breaks LineIndex knows: LF, CRLF and a lone CR.
        var lines: [String] = []
        var lineBreaks: [String] = []
        var lineStart = start
        var position = start
        while position < NSMaxRange(range) {
            let unit = text.character(at: position)
            guard unit == 0x0A || unit == 0x0D else {
                position += 1
                continue
            }
            let isCRLF = unit == 0x0D && position + 1 < NSMaxRange(range) && text.character(at: position + 1) == 0x0A
            lines.append(text.substring(with: NSRange(location: lineStart, length: position - lineStart)))
            lineBreaks.append(isCRLF ? "\r\n" : unit == 0x0D ? "\r" : "\n")
            position += isCRLF ? 2 : 1
            lineStart = position
        }
        lines.append(text.substring(with: NSRange(location: lineStart, length: NSMaxRange(range) - lineStart)))
        return LineBlock(range: range, lineBreakAfter: lineBreak(of: endLine, in: text), lines: lines, lineBreaks: lineBreaks)
    }

    static func lineContentEnd(of lineRange: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        if end > lineRange.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        if end > lineRange.location, text.character(at: end - 1) == 0x0D { end -= 1 }
        return end
    }

    /// The line break that ends `lineRange`, empty for the last line.
    static func lineBreak(of lineRange: NSRange, in text: NSString) -> NSRange {
        let contentEnd = lineContentEnd(of: lineRange, in: text)
        return NSRange(location: contentEnd, length: NSMaxRange(lineRange) - contentEnd)
    }

    /// Moves a selection with an edit to its lines. A non-empty selection that
    /// starts at or before the first line's edit column stays put, so it grows
    /// to cover inserted indentation or comment markers (VS Code's
    /// `_selectionStartColumnStaysPut`).
    private static func adjustedSelection(_ selection: NSRange, block: LineBlock, firstLineDelta: Int, totalDelta: Int, editColumn: Int = 0) -> NSRange {
        if selection.length == 0 {
            return NSRange(location: max(block.range.location, selection.location + firstLineDelta), length: 0)
        }
        let staysPut = firstLineDelta > 0 && selection.location - block.range.location <= editColumn
        let start = staysPut ? selection.location : max(block.range.location, selection.location + firstLineDelta)
        let end = max(start, NSMaxRange(selection) + totalDelta)
        return NSRange(location: start, length: end - start)
    }
}
