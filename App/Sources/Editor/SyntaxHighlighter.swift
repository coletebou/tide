import TideCore
import UIKit

/// Keeps a text storage's attributes in sync with its tokens.
///
/// On every character edit it updates the `LineIndex`, lets the
/// `TokenizationCache` re-tokenize only what changed, and repaints those
/// lines, plus any lines whose bracket nesting depth moved (bracket pair
/// colorization, `editor.bracketPairColorization.enabled`).
final class SyntaxHighlighter: NSObject, NSTextStorageDelegate {
    private(set) var lineIndex: LineIndex
    private(set) var cache: TokenizationCache
    private(set) var language: LanguageDefinition
    private(set) var theme: Theme
    private(set) var fonts: EditorFonts
    private(set) var tabSize: Int
    var bracketPairColorization = true

    /// Called after each character edit with the line edit and the re-tokenized lines.
    var onEdit: ((LineEdit, Range<Int>) -> Void)?

    private weak var storage: NSTextStorage?
    private var bracketDepthAtLineStart: [Int] = [0]
    private var isApplying = false
    private var paragraphStyle = NSParagraphStyle()

    init(storage: NSTextStorage, language: LanguageDefinition, theme: Theme, fonts: EditorFonts, tabSize: Int) {
        self.storage = storage
        self.language = language
        self.theme = theme
        self.fonts = fonts
        self.tabSize = tabSize
        lineIndex = LineIndex(storage.mutableString)
        cache = TokenizationCache(tokenizer: LanguageRegistry.shared.tokenizer(for: language))
        super.init()
        paragraphStyle = makeParagraphStyle()
        storage.delegate = self
        rehighlightAll()
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: fonts.regular, .foregroundColor: theme.uiColor("editor.foreground"), .paragraphStyle: paragraphStyle]
    }

    func update(language: LanguageDefinition? = nil, theme: Theme? = nil, fonts: EditorFonts? = nil, tabSize: Int? = nil) {
        if let language { self.language = language; cache = TokenizationCache(tokenizer: LanguageRegistry.shared.tokenizer(for: language)) }
        if let theme { self.theme = theme }
        if let fonts { self.fonts = fonts }
        if let tabSize { self.tabSize = tabSize }
        paragraphStyle = makeParagraphStyle()
        rehighlightAll()
    }

    private func makeParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: fonts.regular]).width
        style.defaultTabInterval = spaceWidth * CGFloat(tabSize)
        style.tabStops = []
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Re-tokenizes and repaints the whole document.
    func rehighlightAll() {
        guard let storage else { return }
        let text = storage.mutableString as NSString
        lineIndex = LineIndex(text)
        cache.reset(text: text, lineIndex: lineIndex)
        // Stored depths may belong to another language's tokens; start clean.
        bracketDepthAtLineStart = [0] + Array(repeating: -1, count: lineIndex.lineCount)
        recomputeBracketDepths(from: 0)
        apply(lines: 0..<lineIndex.lineCount)
    }

    // MARK: - NSTextStorageDelegate

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            handleEdit(range: editedRange, delta: delta)
        }
    }

    private func handleEdit(range: NSRange, delta: Int) {
        guard let storage, !isApplying else { return }
        let text = storage.mutableString as NSString
        let oldRange = NSRange(location: range.location, length: max(0, range.length - delta))
        let edit = lineIndex.applyEdit(oldRange: oldRange, replacementLength: range.length, newText: text)
        var changed = cache.apply(edit, text: text, lineIndex: lineIndex)
        let insertedEnd = edit.firstLine + edit.insertedLineCount
        changed = min(changed.lowerBound, edit.firstLine)..<max(changed.upperBound, min(insertedEnd, lineIndex.lineCount))
        // Bracket depths below the edit shift when brackets are added or removed.
        bracketDepthAtLineStart.replaceSubrange(
            min(edit.firstLine + 1, bracketDepthAtLineStart.count)..<min(edit.firstLine + 1 + edit.removedLineCount, bracketDepthAtLineStart.count),
            with: repeatElement(-1, count: edit.insertedLineCount)
        )
        let depthChangedThrough = recomputeBracketDepths(from: edit.firstLine, stopAfter: changed.upperBound)
        let end = max(changed.upperBound, depthChangedThrough)
        apply(lines: changed.lowerBound..<min(end, lineIndex.lineCount))
        onEdit?(edit, changed)
    }

    // MARK: - Painting

    private func apply(lines: Range<Int>) {
        guard let storage, !lines.isEmpty else { return }
        isApplying = true
        storage.beginEditing()
        let base = baseAttributes
        let bracketColors = [1, 2, 3].map { theme.uiColor("editorBracketHighlight.foreground\($0)") }
        let unexpected = theme.uiColor("editorBracketHighlight.unexpectedBracket.foreground")
        let text = storage.mutableString as NSString
        for line in lines {
            let lineRange = lineIndex.range(ofLine: line)
            guard lineRange.length > 0 || line == lineIndex.lineCount - 1 else { continue }
            if lineRange.length > 0 { storage.setAttributes(base, range: lineRange) }
            var depth = bracketDepthAtLineStart.indices.contains(line) ? max(0, bracketDepthAtLineStart[line]) : 0
            for token in cache.tokens(forLine: line) {
                let range = NSRange(location: lineRange.location + token.start, length: token.length)
                guard NSMaxRange(range) <= text.length else { continue }
                let style = theme.style(for: token.kind)
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.color?.uiColor ?? theme.uiColor("editor.foreground")]
                if style.bold || style.italic { attributes[.font] = fonts.font(bold: style.bold, italic: style.italic) }
                if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                storage.addAttributes(attributes, range: range)

                guard bracketPairColorization, token.kind == .punctuation else { continue }
                for offset in 0..<token.length {
                    let unit = text.character(at: range.location + offset)
                    let position = NSRange(location: range.location + offset, length: 1)
                    if Self.openers.contains(unit) {
                        storage.addAttribute(.foregroundColor, value: bracketColors[depth % 3], range: position)
                        depth += 1
                    } else if Self.closers.contains(unit) {
                        if depth == 0 {
                            storage.addAttribute(.foregroundColor, value: unexpected, range: position)
                        } else {
                            depth -= 1
                            storage.addAttribute(.foregroundColor, value: bracketColors[depth % 3], range: position)
                        }
                    }
                }
            }
        }
        storage.endEditing()
        isApplying = false
    }

    private static let openers: Set<UInt16> = [0x28, 0x5B, 0x7B]
    private static let closers: Set<UInt16> = [0x29, 0x5D, 0x7D]

    /// Recomputes nesting depth at the start of each line from `line`
    /// downward, stopping once a line past `stopAfter` keeps its old depth.
    /// Returns the line after the last one whose depth changed.
    @discardableResult
    private func recomputeBracketDepths(from line: Int, stopAfter: Int = 0) -> Int {
        guard let storage else { return line }
        let text = storage.mutableString as NSString
        let count = lineIndex.lineCount
        if bracketDepthAtLineStart.count != count + 1 {
            if bracketDepthAtLineStart.count < count + 1 {
                bracketDepthAtLineStart += Array(repeating: -1, count: count + 1 - bracketDepthAtLineStart.count)
            } else {
                bracketDepthAtLineStart.removeLast(bracketDepthAtLineStart.count - count - 1)
            }
        }
        var depth = line == 0 ? 0 : max(0, bracketDepthAtLineStart[line])
        var current = line
        var lastChanged = line
        while current < count {
            if bracketDepthAtLineStart[current] != depth { lastChanged = current + 1 }
            bracketDepthAtLineStart[current] = depth
            let start = lineIndex.lineStarts[current]
            for token in cache.tokens(forLine: current) where token.kind == .punctuation {
                for offset in token.start..<token.end {
                    let unit = text.character(at: start + offset)
                    if Self.openers.contains(unit) { depth += 1 } else if Self.closers.contains(unit), depth > 0 { depth -= 1 }
                }
            }
            current += 1
            if current > stopAfter, current < count, bracketDepthAtLineStart[current] == depth { break }
        }
        if current == count { bracketDepthAtLineStart[count] = depth }
        return max(lastChanged, min(current, count))
    }

    /// Token kind at an offset, for string/comment-aware editing behaviors.
    func kind(at offset: Int) -> TokenKind {
        cache.kind(at: offset, lineIndex: lineIndex)
    }

    func isCode(at offset: Int) -> Bool {
        let kind = kind(at: offset)
        return kind != .string && kind != .comment && kind != .regex && kind != .escape
    }
}
