import Foundation
import Observation
import TideCore
import UIKit

/// An open text file. The document owns the one `NSTextStorage` for its text;
/// every editor showing it attaches its own layout manager to that storage,
/// so split editors of the same file stay in sync with no extra work.
@Observable
final class TextDocument: Identifiable {
    let id = UUID()
    private(set) var path: String
    @ObservationIgnored let fileSystem: any WorkspaceFileSystem
    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored private(set) var highlighter: SyntaxHighlighter!

    private(set) var language: LanguageDefinition
    var format: TextFileFormat
    var indentation: Indentation
    private(set) var version = 0
    private(set) var isDirty = false
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var symbols: [DocumentSymbol] = []
    /// Set when the file changed on disk while it had unsaved edits.
    var hasConflict = false
    /// Untitled documents have no file yet.
    let isUntitled: Bool

    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    /// Called after every edit (used for auto save).
    @ObservationIgnored var onEdit: ((TextDocument) -> Void)?

    var name: String { WorkspacePath.name(of: path) }
    var text: String { storage.string }
    var lineIndex: LineIndex { highlighter.lineIndex }

    init(path: String, text: String, format: TextFileFormat, fileSystem: any WorkspaceFileSystem, theme: Theme, fonts: EditorFonts, settings: SettingsStore, isUntitled: Bool = false) {
        self.path = path
        self.fileSystem = fileSystem
        self.format = format
        self.isUntitled = isUntitled
        savedText = text
        let firstLine = text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        language = LanguageRegistry.shared.language(forFileName: WorkspacePath.name(of: path), firstLine: firstLine)
        let configured = Indentation(tabSize: settings.int("editor.tabSize"), insertSpaces: settings.bool("editor.insertSpaces"))
        indentation = settings.bool("editor.detectIndentation") ? Indentation.detect(in: text, default: configured) : configured
        storage.setAttributedString(NSAttributedString(string: text))
        highlighter = SyntaxHighlighter(storage: storage, language: language, theme: theme, fonts: fonts, tabSize: indentation.tabSize)
        highlighter.bracketPairColorization = settings.bool("editor.bracketPairColorization.enabled")
        highlighter.onEdit = { [weak self] _, _ in self?.didEdit() }
        scheduleAnalysis(delay: 0)
    }

    /// Loads a file from a workspace.
    static func load(path: String, fileSystem: any WorkspaceFileSystem, theme: Theme, fonts: EditorFonts, settings: SettingsStore) async throws -> TextDocument {
        let data = try await fileSystem.read(path)
        guard let (text, format) = TextFileCodec.decode(data) else { throw WorkspaceError.binaryFile(path) }
        return TextDocument(path: path, text: text, format: format, fileSystem: fileSystem, theme: theme, fonts: fonts, settings: settings)
    }

    // MARK: - Editing state

    private func didEdit() {
        version += 1
        // Undoing back to the saved text clears the dirty flag, as in VS Code.
        isDirty = storage.length != (savedText as NSString).length || storage.string != savedText
        scheduleAnalysis(delay: 0.35)
        onEdit?(self)
    }

    private func scheduleAnalysis(delay: TimeInterval) {
        analysisTask?.cancel()
        let snapshot = storage.string
        let language = language
        let fileName = name
        analysisTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            let (diagnostics, symbols) = await Task.detached(priority: .utility) {
                (Diagnostics.analyze(snapshot, language: language, fileName: fileName), DocumentSymbols.extract(from: snapshot, language: language))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.diagnostics = diagnostics
            self.symbols = symbols
        }
    }

    func setLanguage(_ language: LanguageDefinition) {
        self.language = language
        highlighter.update(language: language)
        scheduleAnalysis(delay: 0)
    }

    func restyle(theme: Theme, fonts: EditorFonts, bracketPairColorization: Bool) {
        highlighter.bracketPairColorization = bracketPairColorization
        highlighter.update(theme: theme, fonts: fonts)
    }

    func setIndentation(_ indentation: Indentation) {
        self.indentation = indentation
        highlighter.update(tabSize: indentation.tabSize)
    }

    /// Replaces the whole text (reload, line-ending conversion).
    func replaceText(with text: String) {
        let full = NSRange(location: 0, length: storage.length)
        storage.replaceCharacters(in: full, with: text)
    }

    func setLineEnding(_ lineEnding: LineEnding) {
        guard lineEnding != format.lineEnding else { return }
        format.lineEnding = lineEnding
        replaceText(with: lineEnding.normalize(storage.string))
    }

    // MARK: - Saving

    func save(trimTrailingWhitespace: Bool = false, insertFinalNewline: Bool = false) async throws {
        var text = storage.string
        if trimTrailingWhitespace {
            text = text.components(separatedBy: "\n").map { line in
                var line = line
                let hadCR = line.hasSuffix("\r")
                if hadCR { line.removeLast() }
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return hadCR ? line + "\r" : line
            }.joined(separator: "\n")
        }
        if insertFinalNewline, !text.isEmpty, !text.hasSuffix("\n") { text += format.lineEnding.rawValue }
        if text != storage.string { replaceText(with: text) }
        let writtenVersion = version
        try await fileSystem.write(path, data: TextFileCodec.encode(text, format: format))
        savedText = text
        // Edits typed while the write was in flight are still unsaved.
        isDirty = version != writtenVersion && storage.string != text
        hasConflict = false
    }

    /// Discards unsaved changes and reloads from disk.
    func revert() async throws {
        let data = try await fileSystem.read(path)
        guard let (text, format) = TextFileCodec.decode(data) else { throw WorkspaceError.binaryFile(path) }
        self.format = format
        savedText = text
        replaceText(with: text)
        isDirty = false
        hasConflict = false
    }

    /// Re-reads the file if it changed on disk; keeps local edits and flags a conflict instead.
    func refreshFromDisk() async {
        guard !isUntitled, let data = try? await fileSystem.read(path), let (text, _) = TextFileCodec.decode(data), text != savedText else { return }
        if isDirty {
            hasConflict = true
        } else {
            savedText = text
            replaceText(with: text)
            isDirty = false
        }
    }

    func didMove(to newPath: String) {
        path = newPath
        let newLanguage = LanguageRegistry.shared.language(forFileName: WorkspacePath.name(of: newPath))
        if newLanguage != language { setLanguage(newLanguage) }
    }

    /// The text last saved (or loaded), for dirty diffs.
    var savedContent: String { savedText }
}
