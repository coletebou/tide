import Foundation
import Observation
import SwiftUI
import TideCore

/// One row in Quick Open or a pick list.
struct QuickInputItem: Identifiable {
    enum Icon {
        case file(String)
        case symbol(String)
        case none
    }

    let id: String
    var label: String
    var labelHighlights: [Range<Int>] = []
    var description: String?
    var descriptionHighlights: [Range<Int>] = []
    var detail: String?
    var keybinding: String?
    var icon: Icon = .none
    /// Group label drawn above this row ("recently opened", "other commands").
    var separator: String?
    var isPicked = false
    let accept: () -> Void
}

/// VS Code's Quick Input: one picker routed by prefix. With no prefix it
/// opens files; `>` runs commands; `:` goes to a line; `@` and `@:` jump to
/// symbols; `#` searches symbols in open files; `view ` opens views; `?` lists
/// the prefixes. It also hosts pick lists such as the Color Theme picker.
@Observable
final class QuickInputModel {
    struct PickList {
        var title: String
        var placeholder: String
        var items: [QuickInputItem]
        /// Called as the highlighted row changes (live theme preview).
        var onFocus: ((QuickInputItem) -> Void)?
        var onCancel: (() -> Void)?
        /// For free-text prompts ("New File..."): called with the typed text on Enter.
        var onSubmitText: ((String) -> Void)?
        /// Shows the typed text as dots, for passwords.
        var isSecure = false
        /// Turns the typed text into a first row, such as Remote-SSH's
        /// "user@host", so a new entry wins over a list item it resembles.
        var textItem: ((String) -> QuickInputItem?)?
    }

    var text: String { didSet { refresh() } }
    private(set) var items: [QuickInputItem] = []
    var selectedIndex = 0 { didSet { focusChanged() } }
    private(set) var placeholder = "Search files by name (append : to go to line or @ to go to symbol)"
    private(set) var title: String?
    private(set) var message: String?
    let pickList: PickList?

    @ObservationIgnored private weak var workbench: Workbench?
    /// Set once the input is accepted or cancelled, so it is answered once.
    @ObservationIgnored private var isFinished = false

    init(workbench: Workbench, text: String = "", pickList: PickList? = nil) {
        self.workbench = workbench
        self.text = text
        self.pickList = pickList
        refresh()
    }

    var selectedItem: QuickInputItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    func acceptSelected() {
        guard let workbench else { return }
        if let pickList, let onSubmitText = pickList.onSubmitText {
            isFinished = true
            workbench.quickInput = nil
            onSubmitText(text)
            return
        }
        if text.hasPrefix(":"), pickList == nil {
            goToLine()
            return
        }
        guard let item = selectedItem else { return }
        isFinished = true
        workbench.quickInput = nil
        item.accept()
    }

    func cancel() {
        dismiss()
        workbench?.quickInput = nil
    }

    /// Cancels the input without closing it, when another input replaces it,
    /// so a prompt that someone is waiting on always gets its answer.
    func dismiss() {
        guard !isFinished else { return }
        isFinished = true
        pickList?.onCancel?()
    }

    private func focusChanged() {
        if let item = selectedItem { pickList?.onFocus?(item) }
    }

    // MARK: - Providers

    private func refresh() {
        guard let workbench else { return }
        message = nil
        if let pickList {
            title = pickList.title
            placeholder = pickList.placeholder
            let typed = pickList.textItem?(text).map { [$0] } ?? []
            items = typed + (pickList.onSubmitText != nil ? [] : filter(pickList.items, by: text))
            selectedIndex = max(0, items.firstIndex(where: \.isPicked) ?? 0)
            return
        }
        title = nil
        if text.hasPrefix(">") {
            placeholder = ""
            items = commandItems(query: String(text.dropFirst()), workbench: workbench)
        } else if text.hasPrefix(":") {
            items = []
            message = lineMessage(workbench: workbench)
        } else if text.hasPrefix("@") {
            items = symbolItems(query: String(text.dropFirst()), workbench: workbench)
            if items.isEmpty { message = workbench.activeDocument == nil ? "No editor is open." : "No matching symbols." }
        } else if text.hasPrefix("#") {
            items = workspaceSymbolItems(query: String(text.dropFirst()), workbench: workbench)
        } else if text.hasPrefix("view ") {
            items = viewItems(query: String(text.dropFirst(5)), workbench: workbench)
        } else if text.hasPrefix("?") {
            items = helpItems(workbench: workbench)
        } else {
            placeholder = "Search files by name (append : to go to line or @ to go to symbol)"
            items = fileItems(query: text, workbench: workbench)
            if items.isEmpty, !text.isEmpty { message = workbench.workspace.isIndexing ? "Indexing files..." : "No matching results" }
        }
        selectedIndex = 0
    }

    private func filter(_ items: [QuickInputItem], by query: String) -> [QuickInputItem] {
        guard !query.isEmpty else { return items }
        let scored: [(score: Int, item: QuickInputItem)] = items.compactMap { item -> (score: Int, item: QuickInputItem)? in
            guard let match = FuzzyScorer.score(item.label, query: query) else { return nil }
            var copy = item
            copy.labelHighlights = match.ranges
            copy.separator = nil
            return (match.score, copy)
        }
        return scored.sorted { $0.score > $1.score }.map(\.item)
    }

    private func fileItems(query rawQuery: String, workbench: Workbench) -> [QuickInputItem] {
        // "file.swift:12" and "file.swift@symbol" keep their suffix for after opening.
        var query = rawQuery
        var line: Int?
        if let colon = query.lastIndex(of: ":"), let number = Int(query[query.index(after: colon)...].split(separator: ":").first ?? "") {
            line = number - 1
            query = String(query[..<colon])
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            var seen = Set<String>()
            let recent = workbench.recentFiles.filter { seen.insert($0).inserted }.prefix(20)
            return recent.enumerated().map { index, path in
                QuickInputItem(id: "recent:" + path, label: WorkspacePath.name(of: path), description: WorkspacePath.parent(of: path), icon: .file(path), separator: index == 0 ? "recently opened" : nil) {
                    Task { await workbench.open(path, preview: false, line: line) }
                }
            }
        }
        var scored: [(FuzzyScorer.ItemScore, String)] = []
        for path in workbench.workspace.allFiles {
            let name = WorkspacePath.name(of: path)
            if let score = FuzzyScorer.scoreItem(label: name, description: WorkspacePath.parent(of: path), query: trimmed) {
                scored.append((score, path))
            }
        }
        let recentRank = Dictionary(uniqueKeysWithValues: workbench.recentFiles.enumerated().reversed().map { ($1, $0) })
        scored.sort { lhs, rhs in
            if lhs.0.score != rhs.0.score { return lhs.0.score > rhs.0.score }
            let lhsRecent = recentRank[lhs.1] ?? .max
            let rhsRecent = recentRank[rhs.1] ?? .max
            if lhsRecent != rhsRecent { return lhsRecent < rhsRecent }
            return lhs.1.count < rhs.1.count
        }
        return scored.prefix(80).enumerated().map { index, entry in
            let (score, path) = entry
            return QuickInputItem(
                id: "file:" + path,
                label: WorkspacePath.name(of: path),
                labelHighlights: WordFilter.merge(score.labelPositions),
                description: WorkspacePath.parent(of: path),
                descriptionHighlights: WordFilter.merge(score.descriptionPositions),
                icon: .file(path),
                separator: index == 0 ? "file results" : nil
            ) {
                Task { await workbench.open(path, preview: workbench.settings.bool("workbench.editor.enablePreview") && line == nil, line: line) }
            }
        }
    }

    private func commandItems(query: String, workbench: Workbench) -> [QuickInputItem] {
        let recent = workbench.commands.recentlyUsed.compactMap { workbench.commands.commands[$0] }
        let recentIDs = Set(recent.map(\.id))
        let others = workbench.commands.all.filter { !recentIDs.contains($0.id) }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        var result: [QuickInputItem] = []
        func add(_ commands: [Command], separator: String) {
            var first = true
            for command in commands where command.isEnabled(workbench) {
                guard let highlights = WordFilter.matches(query, in: command.label) else { continue }
                result.append(QuickInputItem(id: "command:" + command.id, label: command.label, labelHighlights: highlights, keybinding: command.keybinding, separator: first ? separator : nil) {
                    workbench.run(command.id)
                })
                first = false
            }
        }
        add(recent, separator: "recently used")
        add(others, separator: recent.isEmpty ? "" : "other commands")
        if result.isEmpty { message = "No matching commands" }
        return result
    }

    private func lineMessage(workbench: Workbench) -> String {
        guard let document = workbench.activeDocument else { return "Open a text editor first to go to a line." }
        let lineCount = document.lineIndex.lineCount
        let spec = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        if let line = spec.first.flatMap({ Int($0) }) {
            let column = spec.count > 1 ? Int(spec[1]) : nil
            if line < 1 || line > lineCount { return "Line \(line) is out of range. Type a line number between 1 and \(lineCount) to navigate to." }
            return column.map { "Go to line \(line), character \($0)." } ?? "Go to line \(line)."
        }
        return "Current Line: \(workbench.cursorLine + 1), Character: \(workbench.cursorColumn + 1). Type a line number between 1 and \(lineCount) to navigate to."
    }

    private func goToLine() {
        guard let workbench, let controller = workbench.activeController else { return }
        let spec = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard let line = spec.first.flatMap({ Int($0) }) else { return }
        let column = spec.count > 1 ? (Int(spec[1]) ?? 1) : 1
        workbench.quickInput = nil
        controller.goTo(line: max(0, line - 1), column: max(0, column - 1))
    }

    private func symbolItems(query rawQuery: String, workbench: Workbench) -> [QuickInputItem] {
        guard let document = workbench.activeDocument else { return [] }
        let grouped = rawQuery.hasPrefix(":")
        let query = grouped ? String(rawQuery.dropFirst()) : rawQuery
        var flattened: [(symbol: DocumentSymbol, container: String?)] = []
        func walk(_ symbols: [DocumentSymbol], container: String?) {
            for symbol in symbols {
                flattened.append((symbol, container))
                walk(symbol.children, container: symbol.name)
            }
        }
        walk(document.symbols, container: nil)
        var matches: [(Int, QuickInputItem)] = []
        for (index, entry) in flattened.enumerated() {
            var highlights: [Range<Int>] = []
            var score = -index
            if !query.isEmpty {
                guard let match = FuzzyScorer.score(entry.symbol.name, query: query) else { continue }
                highlights = match.ranges
                score = match.score
            }
            let symbol = entry.symbol
            matches.append((score, QuickInputItem(id: "symbol:\(symbol.id)", label: symbol.name, labelHighlights: highlights, description: entry.container, detail: "Ln \(symbol.line + 1)", icon: .symbol(symbol.kind.iconName)) {
                workbench.activeController?.goTo(line: symbol.line, column: symbol.column)
            }))
        }
        var items = query.isEmpty ? matches.map(\.1) : matches.sorted { $0.0 > $1.0 }.map(\.1)
        if grouped {
            let kindOf = Dictionary(uniqueKeysWithValues: flattened.map { ("symbol:\($0.symbol.id)", $0.symbol.kind) })
            items.sort { (kindOf[$0.id]?.rawValue ?? "") < (kindOf[$1.id]?.rawValue ?? "") }
            var lastKind: SymbolKind?
            for index in items.indices {
                let kind = kindOf[items[index].id]
                if kind != lastKind { items[index].separator = kind.map { "\($0.rawValue)s" } }
                lastKind = kind
            }
        } else if !items.isEmpty {
            items[0].separator = "symbols (\(items.count))"
        }
        return items
    }

    private func workspaceSymbolItems(query: String, workbench: Workbench) -> [QuickInputItem] {
        var results: [(Int, QuickInputItem)] = []
        for (path, document) in workbench.documentsSnapshot {
            for symbol in document.symbols.flatMap(\.flattened) {
                var score = 0
                var highlights: [Range<Int>] = []
                if !query.isEmpty {
                    guard let match = FuzzyScorer.score(symbol.name, query: query) else { continue }
                    score = match.score
                    highlights = match.ranges
                }
                results.append((score, QuickInputItem(id: "ws:\(path):\(symbol.id)", label: symbol.name, labelHighlights: highlights, description: path, icon: .symbol(symbol.kind.iconName)) {
                    Task { await workbench.open(path, preview: false, line: symbol.line, column: symbol.column) }
                }))
            }
        }
        if results.isEmpty { message = "Workspace symbols come from open editors. Open a file to search its symbols." }
        return results.sorted { $0.0 > $1.0 }.prefix(200).map(\.1)
    }

    private func viewItems(query: String, workbench: Workbench) -> [QuickInputItem] {
        var items: [QuickInputItem] = SideBarView.allCases.map { view in
            QuickInputItem(id: "view:\(view.rawValue)", label: view.title, description: "Side Bar", icon: .symbol(view.symbol)) { workbench.showView(view) }
        }
        items += PanelKind.allCases.map { panel in
            QuickInputItem(id: "panel:\(panel.rawValue)", label: panel.title.capitalized, description: "Panel", icon: .symbol("rectangle.bottomhalf.inset.filled")) { workbench.showPanel(panel) }
        }
        return filter(items, by: query)
    }

    private func helpItems(workbench: Workbench) -> [QuickInputItem] {
        [
            ("", "Go to File"), (">", "Show and Run Commands"), (":", "Go to Line/Column"), ("@", "Go to Symbol in Editor"),
            ("@:", "Go to Symbol in Editor by Category"), ("#", "Go to Symbol in Workspace"), ("view ", "Open View"), ("?", "Help"),
        ].map { prefix, label in
            QuickInputItem(id: "help:\(prefix)", label: prefix.isEmpty ? "…" : prefix, description: label) {
                Task { @MainActor in workbench.showQuickInput(prefix: prefix) }
            }
        }
    }
}

extension Workbench {
    var documentsSnapshot: [(String, TextDocument)] {
        groups.flatMap(\.tabs).compactMap { $0.content.filePath }.reduce(into: [(String, TextDocument)]()) { result, path in
            if let document = document(for: path), !result.contains(where: { $0.0 == path }) { result.append((path, document)) }
        }
    }

    func showQuickInput(prefix: String) {
        present(QuickInputModel(workbench: self, text: prefix))
    }

    func showPick(_ pickList: QuickInputModel.PickList) {
        present(QuickInputModel(workbench: self, pickList: pickList))
    }

    /// Shows an input in place of the one open, which counts as cancelled.
    func present(_ model: QuickInputModel) {
        quickInput?.dismiss()
        quickInput = model
    }

    func showThemePicker() {
        let current = theme
        let darkThemes = allThemes.filter { $0.kind.isDark }
        let lightThemes = allThemes.filter { !$0.kind.isDark }
        var items: [QuickInputItem] = []
        for (index, theme) in lightThemes.enumerated() {
            items.append(QuickInputItem(id: "theme:\(theme.id)", label: theme.name, icon: .symbol("sun.max"), separator: index == 0 ? "light themes" : nil, isPicked: theme.id == current.id) { [weak self] in
                self?.set("workbench.colorTheme", .string(theme.name))
            })
        }
        for (index, theme) in darkThemes.enumerated() {
            items.append(QuickInputItem(id: "theme:\(theme.id)", label: theme.name, icon: .symbol("moon"), separator: index == 0 ? "dark themes" : nil, isPicked: theme.id == current.id) { [weak self] in
                self?.set("workbench.colorTheme", .string(theme.name))
            })
        }
        items.append(QuickInputItem(id: "theme:import", label: "Import VS Code Color Theme...", icon: .symbol("square.and.arrow.down"), separator: "") { [weak self] in
            self?.requestThemeImport = true
        })
        let themes = allThemes
        showPick(.init(title: "Select Color Theme", placeholder: "Select Color Theme (Up/Down Keys to Preview)", items: items, onFocus: { [weak self] item in
            if let theme = themes.first(where: { "theme:\($0.id)" == item.id }) { self?.previewTheme(theme) }
        }, onCancel: { [weak self] in
            self?.previewTheme(nil)
        }))
    }

    func showLanguagePicker() {
        guard let document = activeDocument else { return }
        let items = LanguageRegistry.shared.languages.sorted { $0.name < $1.name }.map { language in
            QuickInputItem(id: "lang:\(language.id)", label: language.name, description: "(\(language.id))", icon: .file("x.\(language.id)"), isPicked: language.id == document.language.id) {
                document.setLanguage(language)
            }
        }
        showPick(.init(title: "Select Language Mode", placeholder: "Select Language Mode", items: items))
    }

    func showEOLPicker() {
        guard let document = activeDocument else { return }
        let items = LineEnding.allCases.map { ending in
            QuickInputItem(id: "eol:\(ending.label)", label: ending.label, isPicked: document.format.lineEnding == ending) {
                document.setLineEnding(ending)
            }
        }
        showPick(.init(title: "Select End of Line Sequence", placeholder: "Select End of Line Sequence", items: items))
    }

    func showIndentationPicker() {
        guard let document = activeDocument else { return }
        var items: [QuickInputItem] = []
        for size in [2, 4, 8] {
            items.append(QuickInputItem(id: "indent:spaces:\(size)", label: "Indent Using Spaces: \(size)", isPicked: document.indentation == Indentation(tabSize: size, insertSpaces: true)) {
                document.setIndentation(Indentation(tabSize: size, insertSpaces: true))
            })
        }
        for size in [2, 4, 8] {
            items.append(QuickInputItem(id: "indent:tabs:\(size)", label: "Indent Using Tabs: \(size)", isPicked: document.indentation == Indentation(tabSize: size, insertSpaces: false)) {
                document.setIndentation(Indentation(tabSize: size, insertSpaces: false))
            })
        }
        items.append(QuickInputItem(id: "indent:convert-spaces", label: "Convert Indentation to Spaces", separator: "") { [weak self] in self?.convertIndentation(toSpaces: true) })
        items.append(QuickInputItem(id: "indent:convert-tabs", label: "Convert Indentation to Tabs") { [weak self] in self?.convertIndentation(toSpaces: false) })
        showPick(.init(title: "Select Indentation", placeholder: "Select Action", items: items))
    }

    /// Prompts for a name, as the Explorer's New File / New Folder do.
    func showNewFileInput(folder isFolder: Bool, in parent: String? = nil) {
        let folder = parent ?? activeDocument.map { WorkspacePath.parent(of: $0.path) } ?? ""
        showPick(.init(title: isFolder ? "New Folder" : "New File", placeholder: folder.isEmpty ? "Name (in the workspace root)" : "Name (in \(folder))", items: [], onSubmitText: { [weak self] name in
            guard let self, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task {
                do {
                    if isFolder {
                        _ = try await self.workspace.createFolder(named: name, in: folder)
                    } else {
                        let path = try await self.workspace.createFile(named: name, in: folder)
                        await self.open(path, preview: false)
                    }
                } catch {
                    self.show(error: error, prefix: "Unable to create '\(name)'")
                }
            }
        }))
    }

    func showRenameInput(for path: String) {
        let model = QuickInputModel(workbench: self, text: WorkspacePath.name(of: path), pickList: .init(title: "Rename", placeholder: "New name", items: [], onSubmitText: { [weak self] name in
            guard let self, !name.isEmpty, name != WorkspacePath.name(of: path) else { return }
            Task {
                do {
                    let destination = try await self.workspace.rename(path, to: name)
                    self.renamed(path, to: destination)
                } catch {
                    self.show(error: error, prefix: "Unable to rename '\(WorkspacePath.name(of: path))'")
                }
            }
        }))
        present(model)
    }
}
