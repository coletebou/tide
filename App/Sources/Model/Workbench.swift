import Foundation
import Observation
import SwiftUI
import TideCore

enum SideBarView: String, CaseIterable, Identifiable, Codable {
    case explorer, search, sourceControl, remote, extensions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explorer: "Explorer"
        case .search: "Search"
        case .sourceControl: "Source Control"
        case .remote: "Remote Explorer"
        case .extensions: "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .explorer: "doc.on.doc"
        case .search: "magnifyingglass"
        case .sourceControl: "arrow.triangle.branch"
        case .remote: "server.rack"
        case .extensions: "square.grid.2x2"
        }
    }

    var commandID: String {
        switch self {
        case .explorer: "workbench.view.explorer"
        case .search: "workbench.view.search"
        case .sourceControl: "workbench.view.scm"
        case .remote: "workbench.view.remote"
        case .extensions: "workbench.view.extensions"
        }
    }
}

enum PanelKind: String, CaseIterable, Identifiable, Codable {
    case problems, output, terminal

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

/// What an editor tab shows.
enum EditorContent: Hashable, Codable {
    /// A file in the workspace, by its workspace-relative path.
    case file(String)
    /// The user's settings.json, which lives in Tide's own folder rather than
    /// the workspace, so a workspace file of the same name is a different document.
    case userSettingsJSON
    case welcome
    case settings
    case markdownPreview(String)
    case diff(String)
    case keyboardShortcuts

    var filePath: String? {
        if case .file(let path) = self { return path }
        return nil
    }
}

struct EditorTab: Identifiable, Hashable, Codable {
    var id = UUID()
    var content: EditorContent
    /// Preview tabs (italic) are replaced by the next file opened from the Explorer.
    var isPreview: Bool
}

@Observable
final class EditorGroup: Identifiable {
    let id = UUID()
    var tabs: [EditorTab] = []
    var activeTabID: UUID?

    var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } }
}

/// One toast in the bottom-right corner.
struct Toast: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    let id = UUID()
    var kind: Kind
    var message: String
}

/// The state of one Tide window: workspace, editors, side bar, panel, settings.
@Observable
final class Workbench {
    // Layout
    var sideBarVisible = true
    var activeView: SideBarView = .explorer
    var sideBarWidth: CGFloat = 280
    var panelVisible = false
    var activePanel: PanelKind = .terminal
    var panelHeight: CGFloat = 240
    var secondarySideBarVisible = false
    var secondarySideBarWidth: CGFloat = 360
    var zenMode = false

    // Content
    private(set) var workspace: Workspace
    var groups: [EditorGroup]
    var activeGroupID: UUID
    /// Open text documents, by the tab content that shows them.
    private(set) var documents: [EditorContent: TextDocument] = [:]
    private(set) var recentlyClosed: [EditorContent] = []
    private(set) var recentFiles: [String] = []

    // Status
    var cursorLine = 0
    var cursorColumn = 0
    var selectionLength = 0
    var toasts: [Toast] = []
    var outputLog: [String] = []
    var quickInput: QuickInputModel?
    /// Set by commands that need a system picker; the window presents it.
    var requestOpenFolder = false
    var requestThemeImport = false

    // Settings and theme
    private(set) var settings = SettingsStore()
    private(set) var theme: Theme = BuiltinThemes.defaultDark
    private(set) var editorConfiguration = EditorConfiguration()
    var systemColorScheme: ColorScheme = .dark
    private(set) var importedThemes: [Theme] = []

    let commands = CommandRegistry()
    let search: SearchModel
    let terminals: TerminalManager
    let scm = SourceControlModel()

    @ObservationIgnored private var controllers: [UUID: EditorController] = [:]
    @ObservationIgnored private var autoSaveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var untitledCounter = 0

    init(workspace: Workspace) {
        self.workspace = workspace
        let group = EditorGroup()
        groups = [group]
        activeGroupID = group.id
        search = SearchModel()
        terminals = TerminalManager()
        search.workbench = self
        terminals.workbench = self
        scm.workbench = self
        BuiltinCommands.register(in: commands)
        loadSettings()
        loadImportedThemes()
    }

    // MARK: - Groups and tabs

    var activeGroup: EditorGroup { groups.first { $0.id == activeGroupID } ?? groups[0] }
    var activeTab: EditorTab? { activeGroup.activeTab }

    var activeDocument: TextDocument? {
        guard let content = activeTab?.content else { return nil }
        return documents[content]
    }

    var activeController: EditorController? {
        guard let tab = activeTab else { return nil }
        return controllers[tab.id]
    }

    /// The open document of a workspace file.
    func document(for path: String) -> TextDocument? { documents[.file(path)] }

    func document(for content: EditorContent) -> TextDocument? { documents[content] }

    /// The editor view controller for a tab, created on first use.
    func controller(for tab: EditorTab) -> EditorController? {
        if let existing = controllers[tab.id] { return existing }
        guard let document = documents[tab.content] else { return nil }
        let controller = EditorController(document: document, theme: theme, configuration: editorConfiguration)
        controller.onCursorChange = { [weak self] line, column, selected in
            self?.cursorLine = line
            self?.cursorColumn = column
            self?.selectionLength = selected
        }
        controller.onCommand = { [weak self] id in self?.run(id) }
        controller.onFocus = { [weak self, weak group = groups.first(where: { $0.tabs.contains(tab) })] in
            if let group { self?.activeGroupID = group.id }
        }
        controllers[tab.id] = controller
        return controller
    }

    /// Opens a file, reusing its tab or the group's preview tab.
    func open(_ path: String, preview: Bool? = nil, line: Int? = nil, column: Int = 0, in group: EditorGroup? = nil) async {
        let group = group ?? activeGroup
        let usePreview = preview ?? settings.bool("workbench.editor.enablePreview")
        do {
            if documents[.file(path)] == nil {
                let document = try await TextDocument.load(path: path, fileSystem: workspace.fileSystem, theme: theme, fonts: editorConfiguration.fonts, settings: settings)
                document.onEdit = { [weak self] document in self?.documentEdited(document) }
                documents[.file(path)] = document
            }
        } catch {
            show(error: error, prefix: "Unable to open '\(WorkspacePath.name(of: path))'")
            return
        }
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 30 { recentFiles.removeLast() }
        let tab = place(.file(path), preview: usePreview, in: group)
        activeGroupID = group.id
        if let line { goTo(line: line, column: column, in: tab) }
        Task { await workspace.reveal(path) }
    }

    /// Opens a document at a position, as the Problems panel does.
    func open(_ content: EditorContent, line: Int, column: Int) async {
        if let path = content.filePath {
            await open(path, preview: false, line: line, column: column)
        } else if content == .userSettingsJSON {
            await openSettingsJSON()
            if let tab = activeTab, tab.content == content { goTo(line: line, column: column, in: tab) }
        }
    }

    private func goTo(line: Int, column: Int, in tab: EditorTab) {
        // Let the editor view appear before moving the caret.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            self.controllers[tab.id]?.goTo(line: line, column: column)
        }
    }

    func open(_ content: EditorContent, in group: EditorGroup? = nil) {
        let group = group ?? activeGroup
        _ = place(content, preview: false, in: group)
        activeGroupID = group.id
    }

    @discardableResult
    private func place(_ content: EditorContent, preview: Bool, in group: EditorGroup) -> EditorTab {
        if let index = group.tabs.firstIndex(where: { $0.content == content }) {
            if !preview { group.tabs[index].isPreview = false }
            group.activeTabID = group.tabs[index].id
            return group.tabs[index]
        }
        let tab = EditorTab(content: content, isPreview: preview)
        if preview, let previewIndex = group.tabs.firstIndex(where: \.isPreview) {
            discardController(for: group.tabs[previewIndex])
            group.tabs[previewIndex] = tab
        } else if let activeIndex = group.tabs.firstIndex(where: { $0.id == group.activeTabID }) {
            group.tabs.insert(tab, at: activeIndex + 1)
        } else {
            group.tabs.append(tab)
        }
        group.activeTabID = tab.id
        return tab
    }

    func activate(_ tab: EditorTab, in group: EditorGroup) {
        group.activeTabID = tab.id
        activeGroupID = group.id
        if let path = tab.content.filePath {
            cursorLine = 0
            cursorColumn = 0
            Task { await workspace.reveal(path) }
        }
    }

    /// Pins a preview tab ("Keep Open"), as editing or double-tapping does.
    func keepOpen(_ tab: EditorTab, in group: EditorGroup) {
        guard let index = group.tabs.firstIndex(of: tab) else { return }
        group.tabs[index].isPreview = false
    }

    func close(_ tab: EditorTab, in group: EditorGroup) {
        guard let index = group.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        group.tabs.remove(at: index)
        recentlyClosed.append(tab.content)
        discardController(for: tab)
        if group.activeTabID == tab.id {
            group.activeTabID = group.tabs.isEmpty ? nil : group.tabs[min(index, group.tabs.count - 1)].id
        }
        if group.tabs.isEmpty, groups.count > 1 {
            groups.removeAll { $0.id == group.id }
            activeGroupID = groups[0].id
        }
        releaseUnusedDocuments()
    }

    func closeOthers(_ tab: EditorTab, in group: EditorGroup) {
        for other in group.tabs where other.id != tab.id { close(other, in: group) }
    }

    func closeToTheRight(_ tab: EditorTab, in group: EditorGroup) {
        guard let index = group.tabs.firstIndex(of: tab) else { return }
        for other in group.tabs.suffix(from: index + 1) { close(other, in: group) }
    }

    func closeSaved(in group: EditorGroup) {
        for tab in group.tabs where documents[tab.content]?.isDirty != true { close(tab, in: group) }
    }

    func closeAll(in group: EditorGroup) {
        for tab in group.tabs { close(tab, in: group) }
    }

    func reopenClosed() {
        guard let content = recentlyClosed.popLast() else { return }
        if let path = content.filePath {
            Task { await open(path, preview: false) }
        } else if content == .userSettingsJSON {
            Task { await openSettingsJSON() }
        } else {
            open(content)
        }
    }

    func splitEditor() {
        guard let tab = activeTab, groups.count < 3 else { return }
        let group = EditorGroup()
        groups.insert(group, at: (groups.firstIndex { $0.id == activeGroupID } ?? 0) + 1)
        _ = place(tab.content, preview: false, in: group)
        activeGroupID = group.id
    }

    func focusNextGroup() {
        guard let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { return }
        activeGroupID = groups[(index + 1) % groups.count].id
    }

    func cycleTabs(forward: Bool) {
        let group = activeGroup
        guard let index = group.tabs.firstIndex(where: { $0.id == group.activeTabID }), group.tabs.count > 1 else { return }
        let next = (index + (forward ? 1 : -1) + group.tabs.count) % group.tabs.count
        activate(group.tabs[next], in: group)
    }

    private func discardController(for tab: EditorTab) {
        controllers[tab.id]?.detach()
        controllers[tab.id] = nil
    }

    /// Drops documents no tab shows, unless they have unsaved edits.
    private func releaseUnusedDocuments() {
        let shown = Set(groups.flatMap(\.tabs).map(\.content))
        for (content, document) in documents where !shown.contains(content) && !document.isDirty {
            documents[content] = nil
        }
    }

    // MARK: - Files

    func newUntitledFile() async {
        untitledCounter += 1
        var name = "Untitled-\(untitledCounter).txt"
        while await workspace.fileSystem.exists(name) {
            untitledCounter += 1
            name = "Untitled-\(untitledCounter).txt"
        }
        do {
            let path = try await workspace.createFile(named: name, in: "")
            await open(path, preview: false)
        } catch {
            show(error: error, prefix: "Unable to create a file")
        }
    }

    func save(_ document: TextDocument) async {
        do {
            try await document.save(trimTrailingWhitespace: settings.bool("files.trimTrailingWhitespace"), insertFinalNewline: settings.bool("files.insertFinalNewline"))
            log("Saved \(document.path)")
            if document === documents[.userSettingsJSON] {
                applySettingsText(document.savedContent)
            }
            await search.documentSaved()
        } catch {
            show(error: error, prefix: "Failed to save '\(document.name)'")
        }
    }

    func saveActive() async {
        if let document = activeDocument { await save(document) }
    }

    /// Saves every dirty document; returns false when one is still unsaved.
    @discardableResult
    func saveAll() async -> Bool {
        for document in documents.values where document.isDirty { await save(document) }
        return dirtyCount == 0
    }

    var dirtyCount: Int { documents.values.filter(\.isDirty).count }

    private func documentEdited(_ document: TextDocument) {
        // Editing a preview tab keeps it open, as in VS Code.
        for group in groups {
            if let index = group.tabs.firstIndex(where: { $0.isPreview && documents[$0.content] === document }) {
                group.tabs[index].isPreview = false
            }
        }
        guard settings.string("files.autoSave") == "afterDelay", document.isDirty else { return }
        autoSaveTasks[document.id]?.cancel()
        let delay = max(100, settings.int("files.autoSaveDelay"))
        autoSaveTasks[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, let document, document.isDirty else { return }
            await self.save(document)
        }
    }

    /// Saves on focus loss and when the app moves to the background.
    func flushAutoSave() async {
        guard settings.string("files.autoSave") != "off" else { return }
        await saveAll()
    }

    func renamed(_ oldPath: String, to newPath: String) {
        for (content, document) in documents {
            guard let path = content.filePath, WorkspacePath.isDescendant(path, of: oldPath) else { continue }
            let updated = newPath + path.dropFirst(oldPath.count)
            document.didMove(to: updated)
            documents[content] = nil
            documents[.file(updated)] = document
        }
        for group in groups {
            for index in group.tabs.indices {
                if let path = group.tabs[index].content.filePath, WorkspacePath.isDescendant(path, of: oldPath) {
                    group.tabs[index].content = .file(newPath + path.dropFirst(oldPath.count))
                }
            }
        }
    }

    func deleted(_ path: String) {
        for group in groups {
            for tab in group.tabs where tab.content.filePath.map({ WorkspacePath.isDescendant($0, of: path) }) ?? false {
                close(tab, in: group)
            }
        }
        for content in documents.keys where content.filePath.map({ WorkspacePath.isDescendant($0, of: path) }) ?? false { documents[content] = nil }
    }

    /// Switches to another folder, closing editors of the old one. When an
    /// unsaved file cannot be saved, the old folder stays open and this returns false.
    @discardableResult
    func openWorkspace(_ workspace: Workspace) async -> Bool {
        guard await saveAll() else {
            toast("'\(workspace.name)' was not opened because some changes could not be saved. Save or revert them, then try again.", kind: .error)
            return false
        }
        for group in groups { for tab in group.tabs { discardController(for: tab) } }
        documents = [:]
        let group = EditorGroup()
        groups = [group]
        activeGroupID = group.id
        self.workspace = workspace
        workspace.excludes = settings.globs("files.exclude").map { Glob($0) }
        await workspace.refresh()
        search.reset()
        terminals.workspaceChanged()
        log("Opened folder \(workspace.name)")
        if settings.string("workbench.startupEditor") == "readme", await workspace.fileSystem.exists("README.md") {
            await open("README.md", preview: false)
        } else {
            open(.welcome)
        }
        return true
    }

    // MARK: - Settings and theme

    static var userDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tide/User", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let settingsPath = "settings.json"
    private var settingsURL: URL { Self.userDirectory.appendingPathComponent(Self.settingsPath) }

    private func loadSettings() {
        let text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? "{\n}\n"
        applySettingsText(text, persist: false)
    }

    private func applySettingsText(_ text: String, persist: Bool = false) {
        let (store, problems) = SettingsStore.parse(text)
        for problem in problems { log("settings.json: \(problem)") }
        settings = store
        if persist { try? store.json().write(to: settingsURL, atomically: true, encoding: .utf8) }
        settingsChanged()
    }

    /// Updates one setting and writes `settings.json`.
    func set(_ key: String, _ value: SettingValue) {
        var store = settings
        store.set(key, value)
        settings = store
        try? store.json().write(to: settingsURL, atomically: true, encoding: .utf8)
        if let document = documents[.userSettingsJSON], !document.isDirty, workspace.localRoot == Self.userDirectory {
            document.replaceText(with: store.json())
        }
        settingsChanged()
    }

    func resetSetting(_ key: String) {
        var store = settings
        store.reset(key)
        settings = store
        try? store.json().write(to: settingsURL, atomically: true, encoding: .utf8)
        settingsChanged()
    }

    /// Opens settings.json in the editor, as "Preferences: Open User Settings (JSON)".
    func openSettingsJSON() async {
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            try? settings.json().write(to: settingsURL, atomically: true, encoding: .utf8)
        }
        let userFileSystem = LocalFileSystem(root: Self.userDirectory, displayName: "User")
        do {
            if documents[.userSettingsJSON] == nil {
                let document = try await TextDocument.load(path: Self.settingsPath, fileSystem: userFileSystem, theme: theme, fonts: editorConfiguration.fonts, settings: settings)
                document.onEdit = { [weak self] document in self?.documentEdited(document) }
                documents[.userSettingsJSON] = document
            }
            _ = place(.userSettingsJSON, preview: false, in: activeGroup)
        } catch {
            show(error: error, prefix: "Unable to open settings.json")
        }
    }

    private func settingsChanged() {
        workspace.excludes = settings.globs("files.exclude").map { Glob($0) }
        resolveTheme()
        let configuration = EditorConfiguration(settings: settings)
        let restyle = configuration != editorConfiguration
        editorConfiguration = configuration
        applyAppearance(restyle: restyle)
    }

    func resolveTheme() {
        let name: String
        if settings.bool("window.autoDetectColorScheme") {
            name = settings.string(systemColorScheme == .dark ? "workbench.preferredDarkColorTheme" : "workbench.preferredLightColorTheme")
        } else {
            name = settings.string("workbench.colorTheme")
        }
        let resolved = allThemes.first { $0.name == name || $0.id == name } ?? BuiltinThemes.defaultDark
        if resolved != theme {
            theme = resolved
            applyAppearance(restyle: true)
        }
    }

    var allThemes: [Theme] { BuiltinThemes.all + importedThemes }

    /// Previews a theme without saving it (the Color Theme picker).
    func previewTheme(_ theme: Theme?) {
        if let theme {
            self.theme = theme
        } else {
            resolveTheme()
        }
        applyAppearance(restyle: true)
    }

    private func applyAppearance(restyle: Bool) {
        for document in documents.values {
            document.restyle(theme: theme, fonts: editorConfiguration.fonts, bracketPairColorization: editorConfiguration.bracketPairColorization)
        }
        for controller in controllers.values {
            controller.apply(theme: theme, configuration: editorConfiguration, restyleDocument: false)
        }
        terminals.applyTheme(theme, fontSize: settings.number("terminal.integrated.fontSize"))
    }

    func adjustFontSize(by delta: Double) {
        let size = min(36, max(8, settings.number("editor.fontSize") + delta))
        set("editor.fontSize", .number(size))
    }

    // MARK: - Imported themes

    private var themesDirectory: URL {
        let url = Self.userDirectory.appendingPathComponent("themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadImportedThemes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: themesDirectory, includingPropertiesForKeys: nil)) ?? []
        importedThemes = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return try? VSCodeThemeImporter.importTheme(from: text, id: "imported-" + url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Imports a VS Code `*-color-theme.json` and switches to it.
    func importTheme(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let theme = try VSCodeThemeImporter.importTheme(from: text, id: "imported-" + url.deletingPathExtension().lastPathComponent)
            try text.write(to: themesDirectory.appendingPathComponent(url.lastPathComponent), atomically: true, encoding: .utf8)
            loadImportedThemes()
            set("workbench.colorTheme", .string(theme.name))
            toast("Installed color theme '\(theme.name)'.")
        } catch {
            show(error: error, prefix: "Could not import the theme")
        }
    }

    // MARK: - Commands, toasts, logging

    func run(_ commandID: String) {
        commands.run(commandID, in: self)
    }

    func toast(_ message: String, kind: Toast.Kind = .info) {
        let toast = Toast(kind: kind, message: message)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        log(message)
        let seconds = kind == .error ? 15 : kind == .warning ? 12 : 10
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    func show(error: Error, prefix: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        toast("\(prefix): \(message)", kind: .error)
    }

    func log(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        outputLog.append("[\(time)] \(message)")
        if outputLog.count > 2_000 { outputLog.removeFirst(500) }
    }

    /// Problems across open documents, worst first.
    var problems: [(content: EditorContent, path: String, diagnostics: [Diagnostic])] {
        documents
            .filter { !$0.value.diagnostics.isEmpty }
            .sorted { $0.value.path < $1.value.path }
            .map { ($0.key, $0.value.path, $0.value.diagnostics.sorted { ($0.severity, $0.line, $0.column) < ($1.severity, $1.line, $1.column) }) }
    }

    var problemCounts: (errors: Int, warnings: Int) {
        let all = documents.values.flatMap(\.diagnostics)
        return (all.filter { $0.severity == .error }.count, all.filter { $0.severity == .warning }.count)
    }

    // MARK: - Session

    struct Session: Codable {
        var openFiles: [String]
        var activeFile: String?
        var sideBarVisible: Bool
        var activeView: SideBarView
        var panelVisible: Bool
        var activePanel: PanelKind
        var sideBarWidth: Double
        var panelHeight: Double
    }

    private static var sessionURL: URL { userDirectory.appendingPathComponent("session.json") }

    func saveSession() {
        let session = Session(
            openFiles: groups.flatMap(\.tabs).compactMap { $0.content.filePath },
            activeFile: activeTab?.content.filePath,
            sideBarVisible: sideBarVisible,
            activeView: activeView,
            panelVisible: panelVisible,
            activePanel: activePanel,
            sideBarWidth: sideBarWidth,
            panelHeight: panelHeight
        )
        if let data = try? JSONEncoder().encode(session) { try? data.write(to: Self.sessionURL) }
    }

    func restoreSession() async -> Bool {
        guard let data = try? Data(contentsOf: Self.sessionURL), let session = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        sideBarVisible = session.sideBarVisible
        activeView = session.activeView
        panelVisible = session.panelVisible
        activePanel = session.activePanel
        sideBarWidth = session.sideBarWidth
        panelHeight = session.panelHeight
        var opened = false
        for path in session.openFiles where await workspace.fileSystem.exists(path) {
            await open(path, preview: false)
            opened = true
        }
        if let active = session.activeFile, let tab = activeGroup.tabs.first(where: { $0.content == .file(active) }) {
            activate(tab, in: activeGroup)
        }
        return opened
    }
}
