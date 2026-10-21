import Observation
import TideCore
import UIKit

/// Settings that shape one editor view, resolved from the user's settings.
struct EditorConfiguration: Equatable {
    var fontFamily = "SF Mono"
    var fontSize: Double = 14
    var lineHeight: Double = 0
    var wordWrap = true
    var lineNumbers = "on"
    var minimap = true
    var renderWhitespace = "selection"
    var renderLineHighlight = true
    var indentGuides = true
    var stickyScroll = true
    var autoClosing = true
    var matchBrackets = true
    var bracketPairColorization = true
    var keyboardBar = true

    init() {}

    init(settings: SettingsStore) {
        fontFamily = settings.string("editor.fontFamily")
        fontSize = settings.number("editor.fontSize")
        lineHeight = settings.number("editor.lineHeight")
        wordWrap = settings.string("editor.wordWrap") != "off"
        lineNumbers = settings.string("editor.lineNumbers")
        minimap = settings.bool("editor.minimap.enabled")
        renderWhitespace = settings.string("editor.renderWhitespace")
        renderLineHighlight = settings.string("editor.renderLineHighlight") != "none"
        indentGuides = settings.bool("editor.guides.indentation")
        stickyScroll = settings.bool("editor.stickyScroll.enabled")
        autoClosing = settings.string("editor.autoClosingBrackets") != "never"
        matchBrackets = settings.string("editor.matchBrackets") != "never"
        bracketPairColorization = settings.bool("editor.bracketPairColorization.enabled")
        keyboardBar = settings.bool("tide.keyboardBar.enabled")
    }

    var fonts: EditorFonts { EditorFonts(family: fontFamily, size: fontSize, lineHeightSetting: lineHeight) }
}

/// Find widget state for one editor (⌘F).
@Observable
final class FindModel {
    var isVisible = false
    var showReplace = false
    var query = "" { didSet { if query != oldValue { recompute(fromCaret: true) } } }
    var replacement = ""
    var isRegex = false { didSet { recompute(fromCaret: false) } }
    var matchCase = false { didSet { recompute(fromCaret: false) } }
    var wholeWord = false { didSet { recompute(fromCaret: false) } }
    private(set) var matches: [NSRange] = []
    private(set) var currentIndex: Int?
    private(set) var error: String?
    /// Bumped to move keyboard focus into the find field.
    var focusRequest = 0

    @ObservationIgnored weak var controller: EditorController?

    var summary: String {
        if let error { return error }
        if query.isEmpty { return "No results" }
        if matches.isEmpty { return "No results" }
        if let currentIndex { return "\(currentIndex + 1) of \(matches.count)" }
        return "\(matches.count) results"
    }

    func recompute(fromCaret: Bool) {
        guard let controller else { return }
        guard !query.isEmpty else {
            matches = []
            currentIndex = nil
            error = nil
            controller.updateFindDecorations()
            return
        }
        do {
            let regex = try WorkspaceSearch.regex(for: SearchQuery(pattern: query, isRegex: isRegex, matchCase: matchCase, wholeWord: wholeWord))
            let text = controller.document.storage.string
            var found: [NSRange] = []
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
                if let match, match.range.length > 0 { found.append(match.range) }
                if found.count >= 20_000 { stop.pointee = true }
            }
            matches = found
            error = nil
        } catch {
            matches = []
            self.error = "Invalid regex"
        }
        if fromCaret || currentIndex == nil || currentIndex! >= matches.count {
            let caret = controller.textView.selectedRange.location
            currentIndex = matches.isEmpty ? nil : (matches.firstIndex { $0.location >= caret } ?? 0)
        }
        controller.updateFindDecorations()
        if fromCaret, let currentIndex { controller.reveal(matches[currentIndex], select: false) }
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    private func step(by delta: Int) {
        guard !matches.isEmpty, let controller else { return }
        let current = currentIndex ?? -1
        currentIndex = (current + delta + matches.count) % matches.count
        controller.updateFindDecorations()
        controller.reveal(matches[currentIndex!], select: true)
    }

    func replaceCurrent() {
        guard let controller, let currentIndex, matches.indices.contains(currentIndex) else { return }
        let range = matches[currentIndex]
        var replacement = self.replacement
        if isRegex, let regex = try? WorkspaceSearch.regex(for: SearchQuery(pattern: query, isRegex: true, matchCase: matchCase, wholeWord: wholeWord)),
           let match = regex.firstMatch(in: controller.document.storage.string, range: range) {
            replacement = regex.replacementString(for: match, in: controller.document.storage.string, offset: 0, template: self.replacement)
        }
        controller.apply(TextEdit(range: range, replacement: replacement, selection: NSRange(location: range.location + (replacement as NSString).length, length: 0)))
        recompute(fromCaret: true)
    }

    func replaceAll() {
        guard let controller, !matches.isEmpty,
              let regex = try? WorkspaceSearch.regex(for: SearchQuery(pattern: query, isRegex: isRegex, matchCase: matchCase, wholeWord: wholeWord)) else { return }
        let text = controller.document.storage.string
        let (result, count) = WorkspaceSearch.replaceAll(in: text, regex: regex, replacement: replacement, isRegex: isRegex)
        guard count > 0 else { return }
        controller.apply(TextEdit(range: NSRange(location: 0, length: (text as NSString).length), replacement: result, selection: NSRange(location: 0, length: 0)))
        recompute(fromCaret: false)
    }
}

/// The text view: TextKit 1 for predictable layout and gutter math, with the
/// iOS text system's input handling (IME, dictation, autocorrect off).
final class CodeTextView: UITextView {
    weak var controller: EditorController?

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (controller?.keyCommands ?? [])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Formatting actions make no sense in a code editor.
        if action == #selector(toggleBoldface(_:)) || action == #selector(toggleItalics(_:)) || action == #selector(toggleUnderline(_:)) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.onFocus?() }
        return became
    }
}

/// Hosts the gutter, text view, minimap and sticky scroll header.
final class EditorContainerView: UIView {
    weak var controller: EditorController?

    override func layoutSubviews() {
        super.layoutSubviews()
        controller?.layout(in: bounds)
    }
}

/// Owns one editor view of a document and implements the editing behaviors.
final class EditorController: NSObject, UITextViewDelegate {
    let document: TextDocument
    let container = EditorContainerView()
    let textView: CodeTextView
    let gutter = GutterView()
    let minimap = MinimapView()
    let stickyHeader = UIStackView()
    let find = FindModel()
    private let layoutManager = CodeLayoutManager()
    private var lineHeightDelegate: LineHeightLayoutDelegate?
    private(set) var configuration: EditorConfiguration
    private(set) var theme: Theme
    private var fonts: EditorFonts
    private var isApplyingEdit = false
    private var keyboardBar: KeyboardBar?

    var onFocus: (() -> Void)?
    var onCursorChange: ((_ line: Int, _ column: Int, _ selected: Int) -> Void)?
    var onCommand: ((String) -> Void)?

    init(document: TextDocument, theme: Theme, configuration: EditorConfiguration) {
        self.document = document
        self.theme = theme
        self.configuration = configuration
        fonts = configuration.fonts
        document.storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 6
        layoutManager.addTextContainer(textContainer)
        layoutManager.allowsNonContiguousLayout = true
        textView = CodeTextView(frame: .zero, textContainer: textContainer)
        super.init()
        find.controller = self
        textView.controller = self
        container.controller = self
        configureTextView()
        container.addSubview(textView)
        container.addSubview(gutter)
        container.addSubview(minimap)
        container.addSubview(stickyHeader)
        gutter.textView = textView
        gutter.lineIndex = { [weak document] in document?.lineIndex ?? LineIndex("") }
        gutter.onTapLine = { [weak self] line in self?.selectLine(line) }
        minimap.textView = textView
        minimap.onScrollToFraction = { [weak self] fraction in self?.scroll(toFraction: fraction) }
        stickyHeader.axis = .vertical
        stickyHeader.isHidden = true
        apply(theme: theme, configuration: configuration, restyleDocument: false)
        minimap.render(document: document, theme: theme)
        updateDecorations()
    }

    /// Detaches from the shared text storage when the editor closes.
    func detach() {
        document.storage.removeLayoutManager(layoutManager)
    }

    private func configureTextView() {
        textView.delegate = self
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.dataDetectorTypes = []
        textView.allowsEditingTextAttributes = false
        textView.isFindInteractionEnabled = false
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.contentInsetAdjustmentBehavior = .never
        textView.accessibilityIdentifier = "code-editor"
        if #available(iOS 18.0, *) {
            textView.writingToolsBehavior = .none
        }
    }

    // MARK: - Appearance

    func apply(theme: Theme, configuration: EditorConfiguration, restyleDocument: Bool = true) {
        let fontsChanged = configuration.fontFamily != self.configuration.fontFamily || configuration.fontSize != self.configuration.fontSize || configuration.lineHeight != self.configuration.lineHeight
        self.theme = theme
        self.configuration = configuration
        fonts = configuration.fonts
        if restyleDocument {
            document.restyle(theme: theme, fonts: fonts, bracketPairColorization: configuration.bracketPairColorization)
        }
        lineHeightDelegate = LineHeightLayoutDelegate(lineHeight: fonts.lineHeight, font: fonts.regular)
        layoutManager.delegate = lineHeightDelegate
        let background = theme.uiColor("editor.background")
        textView.backgroundColor = background
        container.backgroundColor = background
        textView.tintColor = theme.uiColor("editorCursor.foreground")
        textView.keyboardAppearance = theme.kind.isDark ? .dark : .light
        textView.typingAttributes = document.highlighter.baseAttributes
        textView.font = fonts.regular
        textView.textContainer.widthTracksTextView = configuration.wordWrap
        if !configuration.wordWrap {
            textView.textContainer.size = CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        }
        gutter.font = UIFont.monospacedDigitSystemFont(ofSize: max(10, configuration.fontSize - 1), weight: .regular)
        gutter.numberColor = theme.uiColor("editorLineNumber.foreground")
        gutter.activeNumberColor = theme.uiColor("editorLineNumber.activeForeground")
        gutter.background = theme.uiColor("editorGutter.background").alpha(orFallback: background)
        gutter.mode = configuration.lineNumbers
        gutter.changeColors = [
            .added: theme.uiColor("editorGutter.addedBackground"),
            .modified: theme.uiColor("editorGutter.modifiedBackground"),
            .deleted: theme.uiColor("editorGutter.deletedBackground"),
        ]
        minimap.background = background
        minimap.sliderColor = theme.uiColor("minimapSlider.background").withAlphaComponent(0.35)
        minimap.isHidden = !configuration.minimap
        installKeyboardBar(enabled: configuration.keyboardBar)

        var decorations = layoutManager.decorations
        decorations.lineHighlight = configuration.renderLineHighlight ? theme.colors["editor.lineHighlightBackground"]?.uiColor : nil
        decorations.lineHighlightBorder = configuration.renderLineHighlight ? theme.uiColor("editor.lineHighlightBorder") : nil
        decorations.findMatchColor = theme.uiColor("editor.findMatchHighlightBackground")
        decorations.currentFindMatchColor = theme.uiColor("editor.findMatchBackground")
        decorations.bracketMatchFill = theme.uiColor("editorBracketMatch.background")
        decorations.bracketMatchBorder = theme.uiColor("editorBracketMatch.border")
        decorations.indentGuides = configuration.indentGuides
        decorations.indentGuideColor = theme.uiColor("editorIndentGuide.background1")
        decorations.activeIndentGuideColor = theme.uiColor("editorIndentGuide.activeBackground1")
        decorations.tabSize = document.indentation.tabSize
        decorations.spaceWidth = (" " as NSString).size(withAttributes: [.font: fonts.regular]).width
        decorations.renderWhitespace = configuration.renderWhitespace
        decorations.whitespaceColor = theme.uiColor("editorWhitespace.foreground")
        layoutManager.decorations = decorations
        if fontsChanged || restyleDocument {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: document.storage.length), actualCharacterRange: nil)
        }
        container.setNeedsLayout()
        gutter.setNeedsDisplay()
        if restyleDocument { minimap.scheduleRender(document: document, theme: theme, delay: 0) }
        updateDecorations()
    }

    private func installKeyboardBar(enabled: Bool) {
        guard enabled else {
            textView.inputAccessoryView = nil
            keyboardBar = nil
            return
        }
        if keyboardBar == nil {
            let bar = KeyboardBar(tint: .label)
            bar.onKey = { [weak self] key in self?.handleKeyboardBar(key) }
            keyboardBar = bar
            textView.inputAccessoryView = bar
        }
    }

    // MARK: - Layout

    func layout(in bounds: CGRect) {
        let gutterWidth = gutter.preferredWidth(lineCount: document.lineIndex.lineCount)
        let minimapWidth: CGFloat = configuration.minimap && bounds.width > 500 ? 84 : 0
        minimap.isHidden = minimapWidth == 0
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        minimap.frame = CGRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: bounds.height)
        textView.frame = CGRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth - minimapWidth, height: bounds.height)
        // Scroll past the last line, like VS Code's editor.scrollBeyondLastLine.
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: max(60, bounds.height * 0.5), right: 8)
        updateStickyScroll()
        gutter.setNeedsDisplay()
        minimap.setNeedsDisplay()
    }

    private func scroll(toFraction fraction: CGFloat) {
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
        textView.setContentOffset(CGPoint(x: 0, y: maxOffset * fraction), animated: false)
    }

    // MARK: - UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isApplyingEdit else { return true }
        let storage = document.storage.mutableString as NSString
        let language = document.language
        if text == "\n" {
            apply(TextEdit.newline(in: storage, selection: range, language: language, indentation: document.indentation, lineEnding: document.format.lineEnding.rawValue))
            return false
        }
        if text == "\t" {
            apply(TextEditing.insertTab(in: storage, selection: range, indentation: document.indentation))
            return false
        }
        if text.isEmpty, range.length == 1, range == NSRange(location: textView.selectedRange.location - 1, length: 1), textView.selectedRange.length == 0,
           let edit = TextEditing.deleteBackward(in: storage, selection: textView.selectedRange, language: language, indentation: document.indentation) {
            apply(edit)
            return false
        }
        if configuration.autoClosing, text.utf16.count == 1 {
            let inString = range.location > 0 && !document.highlighter.isCode(at: range.location - 1)
            if let edit = TextEditing.typeCharacter(text, in: storage, selection: range, language: language, indentation: document.indentation, isInStringOrComment: inString) {
                apply(edit)
                return false
            }
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        if find.isVisible, !find.query.isEmpty { find.recompute(fromCaret: false) }
        minimap.scheduleRender(document: document, theme: theme)
        container.setNeedsLayout()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        updateDecorations()
        let selection = textView.selectedRange
        let (line, column) = document.lineIndex.position(of: selection.location)
        let lineStart = document.lineIndex.lineStarts[line]
        let prefix = (document.storage.mutableString as NSString).substring(with: NSRange(location: lineStart, length: column))
        onCursorChange?(line, document.indentation.width(of: prefix), selection.length)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        gutter.setNeedsDisplay()
        minimap.setNeedsDisplay()
        updateStickyScroll()
    }

    // MARK: - Decorations

    func updateDecorations() {
        let selection = textView.selectedRange
        let text = document.storage.mutableString as NSString
        var decorations = layoutManager.decorations
        decorations.selection = selection
        decorations.tabSize = document.indentation.tabSize
        let line = document.lineIndex.line(containing: selection.location)
        decorations.currentLine = document.lineIndex.contentRange(ofLine: line, in: text)
        decorations.bracketMatches = []
        if configuration.matchBrackets, selection.length == 0,
           let pair = TextEditing.matchingBracket(at: selection.location, in: text, language: document.language, isCode: { [document] in document.highlighter.isCode(at: $0) }) {
            decorations.bracketMatches = [NSRange(location: pair.open, length: 1), NSRange(location: pair.close, length: 1)]
        }
        let errorColor = theme.uiColor("editorError.foreground")
        let warningColor = theme.uiColor("editorWarning.foreground")
        let infoColor = theme.uiColor("editorInfo.foreground")
        let index = document.lineIndex
        decorations.squiggles = document.diagnostics.prefix(500).compactMap { diagnostic in
            guard diagnostic.line < index.lineCount else { return nil }
            let lineRange = index.contentRange(ofLine: diagnostic.line, in: text)
            let start = lineRange.location + min(diagnostic.column, lineRange.length)
            let length = max(1, min(diagnostic.length, NSMaxRange(lineRange) - start))
            guard start + length <= text.length else { return nil }
            let color = diagnostic.severity == .error ? errorColor : diagnostic.severity == .warning ? warningColor : infoColor
            return (NSRange(location: start, length: length), color)
        }
        var diagnosticLines: [Int: UIColor] = [:]
        for diagnostic in document.diagnostics where diagnosticLines[diagnostic.line] == nil || diagnostic.severity == .error {
            diagnosticLines[diagnostic.line] = diagnostic.severity == .error ? errorColor : warningColor
        }
        gutter.diagnosticLines = diagnosticLines
        let previous = layoutManager.decorations
        layoutManager.decorations = decorations
        gutter.activeLine = line
        // Redraw the lines whose decorations changed.
        invalidateDisplay(for: previous.currentLine)
        invalidateDisplay(for: decorations.currentLine)
        for range in previous.bracketMatches + decorations.bracketMatches { invalidateDisplay(for: range) }
        if previous.squiggles.count != decorations.squiggles.count || previous.renderWhitespace != "none" {
            textView.setNeedsDisplay()
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: text.length))
        }
        gutter.setNeedsDisplay()
    }

    func updateFindDecorations() {
        var decorations = layoutManager.decorations
        decorations.findMatches = find.isVisible ? find.matches : []
        decorations.currentFindMatch = find.isVisible ? find.currentIndex.map { find.matches[$0] } : nil
        layoutManager.decorations = decorations
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: document.storage.length))
    }

    /// Refreshes squiggles and gutter markers after diagnostics or git changes.
    func refreshDiagnostics(changes: [Int: GutterView.ChangeKind]? = nil) {
        if let changes { gutter.changes = changes }
        updateDecorations()
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: document.storage.length))
    }

    private func invalidateDisplay(for range: NSRange?) {
        guard let range, NSMaxRange(range) <= document.storage.length else { return }
        let paragraph = (document.storage.mutableString as NSString).paragraphRange(for: range)
        layoutManager.invalidateDisplay(forCharacterRange: paragraph)
    }

    // MARK: - Sticky scroll

    private func updateStickyScroll() {
        guard configuration.stickyScroll, !document.symbols.isEmpty else {
            stickyHeader.isHidden = true
            return
        }
        let firstVisibleCharacter = layoutManager.characterIndex(
            for: CGPoint(x: 1, y: textView.contentOffset.y - textView.textContainerInset.top + 1),
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        let firstLine = document.lineIndex.line(containing: firstVisibleCharacter)
        var chain: [DocumentSymbol] = []
        var level = document.symbols
        while let enclosing = level.first(where: { $0.line < firstLine && $0.endLine >= firstLine }) {
            chain.append(enclosing)
            level = enclosing.children
            if chain.count == 5 { break }
        }
        let lines = chain.map(\.line).filter { $0 < firstLine + chain.count }
        guard !lines.isEmpty, textView.contentOffset.y > 4 else {
            stickyHeader.isHidden = true
            return
        }
        stickyHeader.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let text = document.storage
        for line in lines {
            let range = document.lineIndex.contentRange(ofLine: line, in: text.mutableString)
            let label = UILabel()
            label.attributedText = text.attributedSubstring(from: range)
            label.lineBreakMode = .byTruncatingTail
            label.isUserInteractionEnabled = true
            label.backgroundColor = theme.uiColor("editorStickyScroll.background").alpha(orFallback: theme.uiColor("editor.background"))
            label.heightAnchor.constraint(equalToConstant: fonts.lineHeight).isActive = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stickyTapped(_:))))
            label.tag = line
            stickyHeader.addArrangedSubview(label)
        }
        stickyHeader.isHidden = false
        let x = textView.frame.minX + textView.textContainer.lineFragmentPadding
        stickyHeader.frame = CGRect(x: x, y: 0, width: textView.frame.width - textView.textContainer.lineFragmentPadding, height: CGFloat(lines.count) * fonts.lineHeight)
        stickyHeader.backgroundColor = theme.uiColor("editor.background")
        stickyHeader.layer.shadowColor = UIColor.black.cgColor
        stickyHeader.layer.shadowOpacity = 0.35
        stickyHeader.layer.shadowRadius = 3
        stickyHeader.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    @objc private func stickyTapped(_ gesture: UITapGestureRecognizer) {
        guard let line = gesture.view?.tag else { return }
        goTo(line: line, column: 0)
    }

    // MARK: - Editing API

    /// Applies an edit as one undoable step and sets the resulting selection.
    func apply(_ edit: TextEdit) {
        let storage = document.storage
        guard NSMaxRange(edit.range) <= storage.length else { return }
        if edit.range.length > 0 || !edit.replacement.isEmpty,
           let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
           let end = textView.position(from: start, offset: edit.range.length),
           let range = textView.textRange(from: start, to: end) {
            isApplyingEdit = true
            textView.replace(range, withText: edit.replacement)
            isApplyingEdit = false
        }
        let length = storage.length
        let location = min(max(0, edit.selection.location), length)
        textView.selectedRange = NSRange(location: location, length: min(edit.selection.length, length - location))
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    private var text: NSString { document.storage.mutableString }

    func toggleComment() {
        if let edit = TextEditing.toggleLineComment(in: text, selection: textView.selectedRange, language: document.language) { apply(edit) }
    }

    func indentLines() { apply(TextEditing.indentLines(in: text, selection: textView.selectedRange, indentation: document.indentation)) }
    func outdentLines() { apply(TextEditing.outdentLines(in: text, selection: textView.selectedRange, indentation: document.indentation)) }

    func moveLines(up: Bool) {
        if let edit = TextEditing.moveLines(up: up, in: text, selection: textView.selectedRange) { apply(edit) }
    }

    func duplicateLines() { apply(TextEditing.duplicateLines(in: text, selection: textView.selectedRange)) }
    func deleteLines() { apply(TextEditing.deleteLines(in: text, selection: textView.selectedRange)) }

    func insertLine(above: Bool) {
        let index = document.lineIndex
        let line = index.line(containing: textView.selectedRange.location)
        let content = index.contentRange(ofLine: line, in: text)
        let indent = String(text.substring(with: content).prefix { $0 == " " || $0 == "\t" })
        let eol = document.format.lineEnding.rawValue
        if above {
            apply(TextEdit(range: NSRange(location: content.location, length: 0), replacement: indent + eol, selection: NSRange(location: content.location + (indent as NSString).length, length: 0)))
        } else {
            let end = NSMaxRange(content)
            apply(TextEdit(range: NSRange(location: end, length: 0), replacement: eol + indent, selection: NSRange(location: end + (eol as NSString).length + (indent as NSString).length, length: 0)))
        }
    }

    func jumpToBracket() {
        let caret = textView.selectedRange.location
        guard let pair = TextEditing.matchingBracket(at: caret, in: text, language: document.language, isCode: { [document] in document.highlighter.isCode(at: $0) }) else { return }
        let target = caret == pair.open || caret == pair.open + 1 ? pair.close : pair.open
        textView.selectedRange = NSRange(location: target, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    func selectLine(_ line: Int? = nil) {
        let index = document.lineIndex
        let target = line ?? index.line(containing: textView.selectedRange.location)
        textView.selectedRange = index.range(ofLine: min(target, index.lineCount - 1))
        textView.scrollRangeToVisible(textView.selectedRange)
        _ = textView.becomeFirstResponder()
    }

    /// Selects the next occurrence of the selected text or the word at the caret (⌘D).
    func selectNextOccurrence() {
        var selection = textView.selectedRange
        if selection.length == 0 {
            selection = wordRange(at: selection.location)
            guard selection.length > 0 else { return }
            textView.selectedRange = selection
            return
        }
        let needle = text.substring(with: selection)
        var found = text.range(of: needle, options: [], range: NSRange(location: NSMaxRange(selection), length: text.length - NSMaxRange(selection)))
        if found.location == NSNotFound { found = text.range(of: needle, options: [], range: NSRange(location: 0, length: selection.location)) }
        if found.location != NSNotFound {
            textView.selectedRange = found
            textView.scrollRangeToVisible(found)
        }
    }

    func wordRange(at location: Int) -> NSRange {
        var start = location
        var end = location
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            let unit = text.character(at: index)
            return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit >= 0x80
        }
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    func goTo(line: Int, column: Int) {
        let offset = document.lineIndex.offset(line: line, column: column, in: text)
        textView.selectedRange = NSRange(location: offset, length: 0)
        reveal(NSRange(location: offset, length: 0), select: false)
        _ = textView.becomeFirstResponder()
    }

    /// Scrolls a range into the middle of the view, optionally selecting it.
    func reveal(_ range: NSRange, select: Bool) {
        guard NSMaxRange(range) <= document.storage.length else { return }
        if select { textView.selectedRange = range }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        rect.origin.y += textView.textContainerInset.top
        let target = max(0, min(rect.midY - textView.bounds.height / 2, textView.contentSize.height - textView.bounds.height + textView.textContainerInset.bottom))
        textView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    func showFind(replace: Bool) {
        find.isVisible = true
        find.showReplace = replace
        let selection = textView.selectedRange
        if selection.length > 0, selection.length < 200 {
            find.query = text.substring(with: selection)
        }
        find.focusRequest += 1
        find.recompute(fromCaret: true)
    }

    func hideFind() {
        find.isVisible = false
        updateFindDecorations()
        _ = textView.becomeFirstResponder()
    }

    // MARK: - Keyboard

    private func handleKeyboardBar(_ key: KeyboardBar.Key) {
        switch key {
        case .text(let character): textView.insertText(character)
        case .tab: textView.insertText("\t")
        case .left: moveCaret(.left)
        case .right: moveCaret(.right)
        case .up: moveCaret(.up)
        case .down: moveCaret(.down)
        case .undo: textView.undoManager?.undo()
        case .redo: textView.undoManager?.redo()
        case .dismiss: textView.resignFirstResponder()
        case .palette: onCommand?("workbench.action.showCommands")
        case .find: showFind(replace: false)
        case .comment: toggleComment()
        }
    }

    private func moveCaret(_ direction: UITextLayoutDirection) {
        guard let range = textView.selectedTextRange,
              let position = textView.position(from: direction == .left || direction == .up ? range.start : range.end, in: direction, offset: 1) else { return }
        textView.selectedTextRange = textView.textRange(from: position, to: position)
    }

    lazy var keyCommands: [UIKeyCommand] = {
        func command(_ title: String, _ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return [
            command("Toggle Line Comment", "/", .command, #selector(keyToggleComment)),
            command("Indent Line", "]", .command, #selector(keyIndent)),
            command("Outdent Line", "[", .command, #selector(keyOutdent)),
            command("Outdent", "\t", .shift, #selector(keyOutdent)),
            command("Move Line Up", UIKeyCommand.inputUpArrow, .alternate, #selector(keyMoveUp)),
            command("Move Line Down", UIKeyCommand.inputDownArrow, .alternate, #selector(keyMoveDown)),
            command("Copy Line Down", UIKeyCommand.inputDownArrow, [.alternate, .shift], #selector(keyDuplicate)),
            command("Delete Line", "k", [.command, .shift], #selector(keyDeleteLines)),
            command("Insert Line Below", "\r", .command, #selector(keyInsertBelow)),
            command("Insert Line Above", "\r", [.command, .shift], #selector(keyInsertAbove)),
            command("Go to Bracket", "\\", [.command, .shift], #selector(keyJumpToBracket)),
            command("Expand Line Selection", "l", .command, #selector(keySelectLine)),
            command("Add Selection to Next Find Match", "d", .command, #selector(keySelectNext)),
            command("Find", "f", .command, #selector(keyFind)),
            command("Replace", "f", [.command, .alternate], #selector(keyReplace)),
            command("Find Next", "g", .command, #selector(keyFindNext)),
            command("Find Previous", "g", [.command, .shift], #selector(keyFindPrevious)),
            command("Close Find", UIKeyCommand.inputEscape, [], #selector(keyEscape)),
        ]
    }()

    @objc private func keyToggleComment() { toggleComment() }
    @objc private func keyIndent() { indentLines() }
    @objc private func keyOutdent() { outdentLines() }
    @objc private func keyMoveUp() { moveLines(up: true) }
    @objc private func keyMoveDown() { moveLines(up: false) }
    @objc private func keyDuplicate() { duplicateLines() }
    @objc private func keyDeleteLines() { deleteLines() }
    @objc private func keyInsertBelow() { insertLine(above: false) }
    @objc private func keyInsertAbove() { insertLine(above: true) }
    @objc private func keyJumpToBracket() { jumpToBracket() }
    @objc private func keySelectLine() { selectLine() }
    @objc private func keySelectNext() { selectNextOccurrence() }
    @objc private func keyFind() { showFind(replace: false) }
    @objc private func keyReplace() { showFind(replace: true) }
    @objc private func keyFindNext() { if find.isVisible { find.next() } else { showFind(replace: false) } }
    @objc private func keyFindPrevious() { if find.isVisible { find.previous() } else { showFind(replace: false) } }
    @objc private func keyEscape() { if find.isVisible { hideFind() } }
}

private extension TextEdit {
    static func newline(in text: NSString, selection: NSRange, language: LanguageDefinition, indentation: Indentation, lineEnding: String) -> TextEdit {
        TextEditing.newline(in: text, selection: selection, language: language, indentation: indentation, lineEnding: lineEnding)
    }
}

extension UIColor {
    /// The color itself, or `fallback` when this color is fully transparent.
    func alpha(orFallback fallback: UIColor) -> UIColor {
        var alpha: CGFloat = 0
        getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha == 0 ? fallback : self
    }
}
