import SwiftUI
import TideCore
import UniformTypeIdentifiers

@main
struct TideApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands { TideCommands() }
    }
}

/// Creates the window's workbench: the folder opened last, else the sample.
struct RootView: View {
    @State private var workbench: Workbench?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let workbench {
                WorkbenchView(workbench: workbench)
                    .fileImporter(isPresented: Binding(get: { workbench.requestOpenFolder }, set: { workbench.requestOpenFolder = $0 }), allowedContentTypes: [.folder]) { result in
                        if case .success(let url) = result { Task { await WorkspaceLauncher.open(folder: url, in: workbench) } }
                    }
                    .background {
                        // A second importer must live on another view.
                        Color.clear.fileImporter(isPresented: Binding(get: { workbench.requestThemeImport }, set: { workbench.requestThemeImport = $0 }), allowedContentTypes: [.json]) { result in
                            if case .success(let url) = result { workbench.importTheme(from: url) }
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase != .active {
                            workbench.saveSession()
                            Task { await workbench.flushAutoSave() }
                        }
                    }
                    .onChange(of: colorScheme, initial: true) { _, scheme in
                        workbench.systemColorScheme = scheme
                        workbench.resolveTheme()
                    }
            } else {
                Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()
            }
        }
        .task {
            guard workbench == nil else { return }
            workbench = await WorkspaceLauncher.makeWorkbench()
        }
    }
}

/// Finds the folder to open at launch and seeds the sample workspace.
enum WorkspaceLauncher {
    static let bookmarkKey = "tide.lastFolderBookmark"

    static var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var sampleURL: URL { documentsURL.appendingPathComponent("Tide Sample", isDirectory: true) }

    /// The UI tests launch with `-uiTesting`, so every launch starts the same way.
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }

    static func makeWorkbench() async -> Workbench {
        if isUITesting { resetForUITesting() }
        seedSampleIfNeeded()
        let fresh = isUITesting || ProcessInfo.processInfo.arguments.contains("-resetWorkspace")
        var workspace: Workspace?
        if !fresh, let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() {
                workspace = Workspace(fileSystem: LocalFileSystem(root: url), scopedURL: url)
            }
        }
        let workbench = Workbench(workspace: workspace ?? Workspace(fileSystem: LocalFileSystem(root: sampleURL, displayName: "Tide Sample")))
        await workbench.workspace.refresh()
        var restored = false
        if !fresh {
            restored = await workbench.restoreSession()
        }
        if !restored {
            if workbench.settings.string("workbench.startupEditor") != "none" { workbench.open(.welcome) }
            if await workbench.workspace.fileSystem.exists("README.md") {
                await workbench.open("README.md", preview: false)
            }
        }
        workbench.log("Tide started with \(workbench.workspace.name)")
        return workbench
    }

    /// Forgets everything an earlier run left: settings (replaced by the
    /// `TIDE_UI_TEST_SETTINGS` settings.json body, if set), session, imported
    /// themes, recent commands, the folder bookmark and edits to the sample.
    private static func resetForUITesting() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: CommandRegistry.recentlyUsedKey)
        try? FileManager.default.removeItem(at: Workbench.userDirectory)
        if let settings = ProcessInfo.processInfo.environment["TIDE_UI_TEST_SETTINGS"] {
            try? settings.write(to: Workbench.userDirectory.appendingPathComponent(Workbench.settingsPath), atomically: true, encoding: .utf8)
        }
        seedSampleIfNeeded(force: true)
    }

    /// Copies the bundled sample project into Documents the first time.
    static func seedSampleIfNeeded(force: Bool = false) {
        guard let bundled = Bundle.main.url(forResource: "SampleWorkspace", withExtension: nil) else { return }
        let manager = FileManager.default
        if force { try? manager.removeItem(at: sampleURL) }
        guard !manager.fileExists(atPath: sampleURL.path) else { return }
        try? manager.copyItem(at: bundled, to: sampleURL)
    }

    static func open(folder url: URL, in workbench: Workbench) async {
        guard url.startAccessingSecurityScopedResource() else {
            workbench.toast("Tide could not get access to that folder.", kind: .error)
            return
        }
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
        await workbench.openWorkspace(Workspace(fileSystem: LocalFileSystem(root: url), scopedURL: url))
    }
}

extension Workbench {
    func openSampleWorkspace() async {
        WorkspaceLauncher.seedSampleIfNeeded()
        UserDefaults.standard.removeObject(forKey: WorkspaceLauncher.bookmarkKey)
        await openWorkspace(Workspace(fileSystem: LocalFileSystem(root: WorkspaceLauncher.sampleURL, displayName: "Tide Sample")))
    }
}

private struct WorkbenchFocusKey: FocusedValueKey {
    typealias Value = Workbench
}

extension FocusedValues {
    var workbench: Workbench? {
        get { self[WorkbenchFocusKey.self] }
        set { self[WorkbenchFocusKey.self] = newValue }
    }
}

/// The iPadOS menu bar, mirroring VS Code's menus and default shortcuts.
struct TideCommands: Commands {
    @FocusedValue(\.workbench) private var workbench

    private func item(_ title: String, _ id: String, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command) -> some View {
        Group {
            if let key {
                Button(title) { workbench?.run(id) }.keyboardShortcut(key, modifiers: modifiers)
            } else {
                Button(title) { workbench?.run(id) }
            }
        }
        .disabled(workbench == nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("New Text File", "workbench.action.files.newUntitledFile", "n")
            item("Open Folder...", "workbench.action.files.openFolder", "o")
            item("Open Sample Workspace", "workbench.action.files.openSampleFolder")
        }
        CommandGroup(replacing: .saveItem) {
            item("Save", "workbench.action.files.save", "s")
            item("Save All", "workbench.action.files.saveAll", "s", [.command, .option])
            item("Revert File", "workbench.action.files.revert")
            Divider()
            item("Close Editor", "workbench.action.closeActiveEditor", "w")
            item("Close All Editors", "workbench.action.closeAllEditors", "w", [.command, .shift])
            item("Reopen Closed Editor", "workbench.action.reopenClosedEditor", "t", [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            item("Settings", "workbench.action.openSettings", ",")
            item("Color Theme", "workbench.action.selectTheme")
            item("Keyboard Shortcuts", "workbench.action.openGlobalKeybindings")
        }
        CommandGroup(after: .textEditing) {
            Divider()
            item("Find", "actions.find", "f")
            item("Replace", "editor.action.startFindReplaceAction", "f", [.command, .option])
            item("Find in Files", "workbench.view.search", "f", [.command, .shift])
            Divider()
            item("Toggle Line Comment", "editor.action.commentLine", "/")
        }
        CommandMenu("Selection") {
            item("Expand Line Selection", "expandLineSelection", "l")
            item("Add Next Occurrence", "editor.action.addSelectionToNextFindMatch", "d")
            Divider()
            item("Copy Line Down", "editor.action.copyLinesDownAction", .downArrow, [.option, .shift])
            item("Move Line Up", "editor.action.moveLinesUpAction", .upArrow, .option)
            item("Move Line Down", "editor.action.moveLinesDownAction", .downArrow, .option)
            item("Delete Line", "editor.action.deleteLines", "k", [.command, .shift])
            Divider()
            item("Indent Line", "editor.action.indentLines", "]")
            item("Outdent Line", "editor.action.outdentLines", "[")
        }
        CommandMenu("View") {
            item("Command Palette...", "workbench.action.showCommands", "p", [.command, .shift])
            item("Open View...", "workbench.action.quickOpenView", "q", .control)
            Divider()
            item("Explorer", "workbench.view.explorer", "e", [.command, .shift])
            item("Search", "workbench.view.search")
            item("Source Control", "workbench.view.scm", "g", [.control, .shift])
            item("Remote Explorer", "workbench.view.remote")
            item("Extensions", "workbench.view.extensions", "x", [.command, .shift])
            Divider()
            item("Problems", "workbench.actions.view.problems", "m", [.command, .shift])
            item("Output", "workbench.action.output.toggleOutput", "u", [.command, .shift])
            item("Terminal", "workbench.action.terminal.toggleTerminal", "`", .control)
            Divider()
            item("Toggle Primary Side Bar", "workbench.action.toggleSidebarVisibility", "b")
            item("Toggle Panel", "workbench.action.togglePanel", "j")
            item("Toggle Secondary Side Bar", "workbench.action.toggleAuxiliaryBar", "b", [.command, .option])
            item("Split Editor", "workbench.action.splitEditor", "\\")
            item("Zen Mode", "workbench.action.toggleZenMode")
            Divider()
            item("Word Wrap", "editor.action.toggleWordWrap", "z", .option)
            item("Minimap", "editor.action.toggleMinimap")
            item("Zoom In", "workbench.action.zoomIn", "=")
            item("Zoom Out", "workbench.action.zoomOut", "-")
            item("Reset Zoom", "workbench.action.zoomReset", "0")
        }
        CommandMenu("Go") {
            item("Go to File...", "workbench.action.quickOpen", "p")
            item("Go to Symbol in Editor...", "workbench.action.gotoSymbol", "o", [.command, .shift])
            item("Go to Symbol in Workspace...", "workbench.action.showAllSymbols", "t")
            item("Go to Line/Column...", "workbench.action.gotoLine", "g", .control)
            item("Go to Bracket", "editor.action.jumpToBracket", "\\", [.command, .shift])
            Divider()
            item("Next Editor", "workbench.action.nextEditor", .rightArrow, [.command, .option])
            item("Previous Editor", "workbench.action.previousEditor", .leftArrow, [.command, .option])
        }
        CommandMenu("Terminal") {
            item("New Terminal", "workbench.action.terminal.new", "`", [.control, .shift])
            item("Clear Terminal", "workbench.action.terminal.clear")
        }
        CommandGroup(replacing: .help) {
            item("Welcome", "workbench.action.openWelcome")
            item("Show All Commands", "workbench.action.showCommands")
            item("Show Log", "workbench.action.showOutput")
        }
    }
}
