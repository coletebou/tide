import Foundation

/// Per-line tokens and end states for one document, kept current across edits.
///
/// This is VS Code's tokenization model: line N is tokenized starting from the
/// end state of line N-1. After an edit, the touched lines are re-tokenized and
/// re-tokenizing continues downward only while end states keep changing, so
/// typing inside a function costs a line or two even in a large file, while
/// typing `/*` correctly re-colors everything below it.
public final class TokenizationCache {
    public let tokenizer: any LineTokenizer
    public private(set) var lineTokens: [[Token]] = []
    public private(set) var endStates: [LineState] = []

    public init(tokenizer: any LineTokenizer) {
        self.tokenizer = tokenizer
    }

    public var lineCount: Int { lineTokens.count }

    /// Tokenizes the whole text.
    public func reset(text: NSString, lineIndex: LineIndex) {
        lineTokens = []
        endStates = []
        lineTokens.reserveCapacity(lineIndex.lineCount)
        endStates.reserveCapacity(lineIndex.lineCount)
        var state = LineState.root
        for line in 0..<lineIndex.lineCount {
            let result = tokenizer.tokenize(Self.units(ofLine: line, text: text, lineIndex: lineIndex), state: state)
            lineTokens.append(result.tokens)
            endStates.append(result.endState)
            state = result.endState
        }
    }

    /// Applies a line edit (from `LineIndex.applyEdit`) and re-tokenizes what it
    /// affected. Returns the lines whose tokens were recomputed.
    @discardableResult
    public func apply(_ edit: LineEdit, text: NSString, lineIndex: LineIndex) -> Range<Int> {
        guard lineTokens.count + edit.lineDelta == lineIndex.lineCount, edit.firstLine <= lineTokens.count else {
            reset(text: text, lineIndex: lineIndex)
            return 0..<lineIndex.lineCount
        }
        let removedEnd = edit.firstLine + edit.removedLineCount
        // The state that used to flow into the first unchanged line below the edit.
        let previousTailState = removedEnd > 0 && removedEnd <= endStates.count ? endStates[removedEnd - 1] : LineState.root
        lineTokens.replaceSubrange(edit.firstLine..<removedEnd, with: repeatElement([], count: edit.insertedLineCount))
        endStates.replaceSubrange(edit.firstLine..<removedEnd, with: repeatElement(.root, count: edit.insertedLineCount))

        var state = edit.firstLine > 0 ? endStates[edit.firstLine - 1] : .root
        var line = edit.firstLine
        let insertedEnd = edit.firstLine + edit.insertedLineCount
        while line < lineIndex.lineCount {
            let previousEnd = line >= insertedEnd ? endStates[line] : nil
            let result = tokenizer.tokenize(Self.units(ofLine: line, text: text, lineIndex: lineIndex), state: state)
            lineTokens[line] = result.tokens
            endStates[line] = result.endState
            state = result.endState
            line += 1
            if line == insertedEnd, result.endState == previousTailState { break }
            if let previousEnd, previousEnd == result.endState { break }
        }
        return edit.firstLine..<line
    }

    public func tokens(forLine line: Int) -> [Token] {
        line < lineTokens.count ? lineTokens[line] : []
    }

    /// The token kind at a UTF-16 offset, or `.plain` between tokens.
    public func kind(at offset: Int, lineIndex: LineIndex) -> TokenKind {
        let line = lineIndex.line(containing: offset)
        let column = offset - lineIndex.lineStarts[line]
        for token in tokens(forLine: line) {
            if column < token.start { break }
            if column < token.end { return token.kind }
        }
        return .plain
    }

    static func units(ofLine line: Int, text: NSString, lineIndex: LineIndex) -> [UInt16] {
        let range = lineIndex.contentRange(ofLine: line, in: text)
        guard range.length > 0 else { return [] }
        var units = [UInt16](repeating: 0, count: range.length)
        units.withUnsafeMutableBufferPointer { pointer in
            text.getCharacters(pointer.baseAddress!, range: range)
        }
        return units
    }
}

extension LineTokenizer {
    /// Tokenizes a whole text in one pass. Convenient for tests and previews.
    public func tokenizeAll(_ text: String) -> [[Token]] {
        let nsText = text as NSString
        let index = LineIndex(nsText)
        let cache = TokenizationCache(tokenizer: self)
        cache.reset(text: nsText, lineIndex: index)
        return cache.lineTokens
    }
}
