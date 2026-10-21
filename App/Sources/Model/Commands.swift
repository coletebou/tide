import Foundation
import SwiftUI
import TideCore
import UIKit

/// A workbench command. Ids and titles follow VS Code
/// (`workbench.action.quickOpen`, "Go to File...").
struct Command: Identifiable {
    let id: String
    let title: String
    var category: String?
    /// Display form of the default shortcut, such as "⇧⌘P".
    var keybinding: String?
    var isEnabled: (Workbench) -> Bool = { _ in true }
    let run: (Workbench) -> Void

    /// "View: Toggle Minimap" as the Command Palette shows it.
    var label: String { category.map { "\($0): \(title)" } ?? title }
}

/// All commands, plus the Command Palette's recently-used list.
final class CommandRegistry {
    static let recentlyUsedKey = "tide.recentCommands"

    private(set) var commands: [String: Command] = [:]
    private(set) var order: [String] = []
    /// Most recent first, capped at `workbench.commandPalette.history` (50).
    private(set) var recentlyUsed: [String] = UserDefaults.standard.stringArray(forKey: CommandRegistry.recentlyUsedKey) ?? []

    func register(_ command: Command) {
        if commands[command.id] == nil { order.append(command.id) }
        commands[command.id] = command
    }

    func run(_ id: String, in workbench: Workbench) {
        guard let command = commands[id], command.isEnabled(workbench) else { return }
        recordUse(id, limit: workbench.settings.int("workbench.commandPalette.history"))
        command.run(workbench)
    }

    private func recordUse(_ id: String, limit: Int) {
        recentlyUsed.removeAll { $0 == id }
        recentlyUsed.insert(id, at: 0)
        if recentlyUsed.count > max(0, limit) { recentlyUsed.removeLast(recentlyUsed.count - max(0, limit)) }
        UserDefaults.standard.set(recentlyUsed, forKey: Self.recentlyUsedKey)
    }

    var all: [Command] { order.compactMap { commands[$0] } }
}

enum BuiltinCommands {
    static func register(in registry: CommandRegistry) {
        func add(_ id: String, _ title: String, _ category: String? = nil, _ keybinding: String? = nil, enabled: @escaping (Workbench) -> Bool = { _ in true }, _ run: @escaping (Workbench) -> Void) {
            registry.register(Command(id: id, title: title, category: category, keybinding: keybinding, isEnabled: enabled, run: run))
        }
        let hasEditor: (Workbench) -> Bool = { $0.activeController != nil }

        // Quick access
        add("workbench.action.quickOpen", "Go to File...", nil, "⌘P") { $0.showQuickInput(prefix: "") }
        add("workbench.action.showCommands", "Show All Commands", nil, "⇧⌘P") { $0.showQuickInput(prefix: ">") }
        add("workbench.action.gotoLine", "Go to Line/Column...", "Go", "⌃G") { $0.showQuickInput(prefix: ":") }
        add("workbench.action.gotoSymbol", "Go to Symbol in Editor...", "Go", "⇧⌘O") { $0.showQuickInput(prefix: "@") }
        add("workbench.action.showAllSymbols", "Go to Symbol in Workspace...", "Go", "⌘T") { $0.showQuickInput(prefix: "#") }
        add("workbench.action.quickOpenView", "Open View...", "View", "⌃Q") { $0.showQuickInput(prefix: "view ") }

        // Files
        add("workbench.action.files.newUntitledFile", "New Text File", "File", "⌘N") { workbench in Task { await workbench.newUntitledFile() } }
        add("workbench.action.files.save", "Save", "File", "⌘S", enabled: { $0.activeDocument != nil }) { workbench in Task { await workbench.saveActive() } }
        add("workbench.action.files.saveAll", "Save All", "File", "⌥⌘S") { workbench in Task { await workbench.saveAll() } }
        add("workbench.action.files.revert", "Revert File", "File", enabled: { $0.activeDocument?.isDirty == true }) { workbench in
            guard let document = workbench.activeDocument else { return }
            Task { try? await document.revert() }
        }
        add("workbench.action.files.openFolder", "Open Folder...", "File", "⌘O") { $0.requestOpenFolder = true }
        add("workbench.action.files.openSampleFolder", "Open Sample Workspace", "File") { workbench in Task { await workbench.openSampleWorkspace() } }
        add("workbench.action.closeActiveEditor", "Close Editor", "View", "⌘W", enabled: { $0.activeTab != nil }) { workbench in
            if let tab = workbench.activeTab { workbench.close(tab, in: workbench.activeGroup) }
        }
        add("workbench.action.closeAllEditors", "Close All Editors", "View", "⇧⌘W") { workbench in
            for group in workbench.groups { workbench.closeAll(in: group) }
        }
        add("workbench.action.reopenClosedEditor", "Reopen Closed Editor", "View", "⇧⌘T") { $0.reopenClosed() }
        add("workbench.action.keepEditor", "Keep Editor", "View", enabled: { $0.activeTab?.isPreview == true }) { workbench in
            if let tab = workbench.activeTab { workbench.keepOpen(tab, in: workbench.activeGroup) }
        }
        add("workbench.action.splitEditor", "Split Editor", "View", "⌘\\", enabled: { $0.activeTab != nil }) { $0.splitEditor() }
        add("workbench.action.focusNextGroup", "Focus Next Editor Group", "View") { $0.focusNextGroup() }
        add("workbench.action.nextEditor", "Open Next Editor", "View", "⌥⌘→") { $0.cycleTabs(forward: true) }
        add("workbench.action.previousEditor", "Open Previous Editor", "View", "⌥⌘←") { $0.cycleTabs(forward: false) }
        add("copyFilePath", "Copy Path of Active File", "File", enabled: { $0.activeDocument != nil }) { workbench in
            guard let document = workbench.activeDocument else { return }
            UIPasteboard.general.string = workbench.workspace.localRoot.map { $0.appendingPathComponent(document.path).path } ?? document.path
        }
        add("copyRelativeFilePath", "Copy Relative Path of Active File", "File", enabled: { $0.activeDocument != nil }) { workbench in
            UIPasteboard.general.string = workbench.activeDocument?.path
        }
        add("workbench.files.action.showActiveFileInExplorer", "Reveal Active File in Explorer View", "File", enabled: { $0.activeDocument != nil }) { workbench in
            guard let path = workbench.activeDocument?.path else { return }
            workbench.showView(.explorer)
            Task { await workbench.workspace.reveal(path) }
        }

        // Views and layout
        add("workbench.action.toggleSidebarVisibility", "Toggle Primary Side Bar Visibility", "View", "⌘B") { workbench in
            withAnimation(.easeInOut(duration: 0.18)) { workbench.sideBarVisible.toggle() }
        }
        add("workbench.action.togglePanel", "Toggle Panel Visibility", "View", "⌘J") { workbench in
            withAnimation(.easeInOut(duration: 0.18)) { workbench.panelVisible.toggle() }
        }
        add("workbench.action.toggleAuxiliaryBar", "Toggle Secondary Side Bar Visibility", "View", "⌥⌘B") { workbench in
            withAnimation(.easeInOut(duration: 0.18)) { workbench.secondarySideBarVisible.toggle() }
        }
        add("workbench.action.toggleZenMode", "Toggle Zen Mode", "View") { workbench in
            withAnimation(.easeInOut(duration: 0.2)) { workbench.zenMode.toggle() }
        }
        add("workbench.view.explorer", "Show Explorer", "View", "⇧⌘E") { $0.showView(.explorer) }
        add("workbench.view.search", "Show Search", "View", "⇧⌘F") { workbench in
            workbench.showView(.search)
            workbench.search.focusRequest += 1
        }
        add("workbench.view.scm", "Show Source Control", "View", "⌃⇧G") { $0.showView(.sourceControl) }
        add("workbench.view.remote", "Show Remote Explorer", "View") { $0.showView(.remote) }
        add("workbench.view.extensions", "Show Extensions", "View", "⇧⌘X") { $0.showView(.extensions) }
        add("workbench.actions.view.problems", "Show Problems", "View", "⇧⌘M") { $0.showPanel(.problems) }
        add("workbench.action.output.toggleOutput", "Show Output", "View", "⇧⌘U") { $0.showPanel(.output) }
        add("workbench.action.terminal.toggleTerminal", "Toggle Terminal", "View", "⌃`") { workbench in
            if workbench.panelVisible, workbench.activePanel == .terminal {
                withAnimation(.easeInOut(duration: 0.18)) { workbench.panelVisible = false }
            } else {
                workbench.showPanel(.terminal)
            }
        }
        add("workbench.action.terminal.new", "Create New Terminal", "Terminal", "⌃⇧`") { workbench in
            workbench.terminals.newLocalSession()
            workbench.showPanel(.terminal)
        }
        add("workbench.action.terminal.clear", "Clear", "Terminal") { $0.terminals.clearActive() }
        add("workbench.action.terminal.focusAccessibleBuffer", "Focus Accessible Buffer", "Terminal", enabled: { $0.terminals.activeSession != nil }) { workbench in
            workbench.showPanel(.terminal)
            workbench.terminals.activeSession?.showAccessibleBuffer()
        }
        add("workbench.action.zoomIn", "Zoom In", "View", "⌘=") { $0.adjustFontSize(by: 1) }
        add("workbench.action.zoomOut", "Zoom Out", "View", "⌘-") { $0.adjustFontSize(by: -1) }
        add("workbench.action.zoomReset", "Reset Zoom", "View", "⌘0") { $0.set("editor.fontSize", .number(14)) }

        // Preferences
        add("workbench.action.openSettings", "Open Settings", "Preferences", "⌘,") { $0.open(.settings) }
        add("workbench.action.openSettingsJson", "Open User Settings (JSON)", "Preferences") { workbench in Task { await workbench.openSettingsJSON() } }
        add("workbench.action.selectTheme", "Color Theme", "Preferences", "⌘K ⌘T") { $0.showThemePicker() }
        add("workbench.action.openGlobalKeybindings", "Open Keyboard Shortcuts", "Preferences") { $0.open(.keyboardShortcuts) }
        add("workbench.action.importTheme", "Import VS Code Color Theme...", "Preferences") { $0.requestThemeImport = true }
        add("editor.action.toggleMinimap", "Toggle Minimap", "View") { workbench in
            workbench.set("editor.minimap.enabled", .bool(!workbench.settings.bool("editor.minimap.enabled")))
        }
        add("editor.action.toggleWordWrap", "Toggle Word Wrap", "View", "⌥Z") { workbench in
            workbench.set("editor.wordWrap", .string(workbench.settings.string("editor.wordWrap") == "off" ? "on" : "off"))
        }
        add("editor.action.toggleRenderWhitespace", "Toggle Render Whitespace", "View") { workbench in
            workbench.set("editor.renderWhitespace", .string(workbench.settings.string("editor.renderWhitespace") == "all" ? "selection" : "all"))
        }
        add("editor.action.toggleStickyScroll", "Toggle Sticky Scroll", "View") { workbench in
            workbench.set("editor.stickyScroll.enabled", .bool(!workbench.settings.bool("editor.stickyScroll.enabled")))
        }
        add("tide.toggleKeyboardBar", "Toggle Keyboard Bar", "View") { workbench in
            workbench.set("tide.keyboardBar.enabled", .bool(!workbench.settings.bool("tide.keyboardBar.enabled")))
        }

        // Editor
        add("actions.find", "Find", "Editor", "⌘F", enabled: hasEditor) { $0.activeController?.showFind(replace: false) }
        add("editor.action.startFindReplaceAction", "Replace", "Editor", "⌥⌘F", enabled: hasEditor) { $0.activeController?.showFind(replace: true) }
        add("editor.action.nextMatchFindAction", "Find Next", "Editor", "⌘G", enabled: hasEditor) { $0.activeController?.findNext() }
        add("editor.action.previousMatchFindAction", "Find Previous", "Editor", "⇧⌘G", enabled: hasEditor) { $0.activeController?.findPrevious() }
        add("editor.action.commentLine", "Toggle Line Comment", "Editor", "⌘/", enabled: hasEditor) { $0.activeController?.toggleComment() }
        add("editor.action.indentLines", "Indent Line", "Editor", "⌘]", enabled: hasEditor) { $0.activeController?.indentLines() }
        add("editor.action.outdentLines", "Outdent Line", "Editor", "⌘[", enabled: hasEditor) { $0.activeController?.outdentLines() }
        add("editor.action.moveLinesUpAction", "Move Line Up", "Editor", "⌥↑", enabled: hasEditor) { $0.activeController?.moveLines(up: true) }
        add("editor.action.moveLinesDownAction", "Move Line Down", "Editor", "⌥↓", enabled: hasEditor) { $0.activeController?.moveLines(up: false) }
        add("editor.action.copyLinesDownAction", "Copy Line Down", "Editor", "⇧⌥↓", enabled: hasEditor) { $0.activeController?.duplicateLines() }
        add("editor.action.deleteLines", "Delete Line", "Editor", "⇧⌘K", enabled: hasEditor) { $0.activeController?.deleteLines() }
        add("editor.action.insertLineAfter", "Insert Line Below", "Editor", "⌘↩", enabled: hasEditor) { $0.activeController?.insertLine(above: false) }
        add("editor.action.insertLineBefore", "Insert Line Above", "Editor", "⇧⌘↩", enabled: hasEditor) { $0.activeController?.insertLine(above: true) }
        add("editor.action.jumpToBracket", "Go to Bracket", "Editor", "⇧⌘\\", enabled: hasEditor) { $0.activeController?.jumpToBracket() }
        add("expandLineSelection", "Expand Line Selection", "Selection", "⌘L", enabled: hasEditor) { $0.activeController?.selectLine() }
        add("editor.action.addSelectionToNextFindMatch", "Add Selection to Next Find Match", "Selection", "⌘D", enabled: hasEditor) { $0.activeController?.selectNextOccurrence() }
        add("editor.action.selectAll", "Select All", "Selection", "⌘A", enabled: hasEditor) { $0.activeController?.textView.selectAll(nil) }
        add("undo", "Undo", "Edit", "⌘Z", enabled: hasEditor) { $0.activeController?.textView.undoManager?.undo() }
        add("redo", "Redo", "Edit", "⇧⌘Z", enabled: hasEditor) { $0.activeController?.textView.undoManager?.redo() }
        add("workbench.action.editor.changeLanguageMode", "Change Language Mode", nil, enabled: { $0.activeDocument != nil }) { $0.showLanguagePicker() }
        add("workbench.action.editor.changeEOL", "Change End of Line Sequence", nil, enabled: { $0.activeDocument != nil }) { $0.showEOLPicker() }
        add("editor.action.indentationToSpaces", "Convert Indentation to Spaces", nil, enabled: { $0.activeDocument != nil }) { $0.convertIndentation(toSpaces: true) }
        add("editor.action.indentationToTabs", "Convert Indentation to Tabs", nil, enabled: { $0.activeDocument != nil }) { $0.convertIndentation(toSpaces: false) }
        add("workbench.action.editor.changeIndentation", "Change Indentation", nil, enabled: { $0.activeDocument != nil }) { $0.showIndentationPicker() }
        add("markdown.showPreviewToSide", "Open Preview to the Side", "Markdown", "⌘K V", enabled: { $0.activeDocument?.language.id == "markdown" }) { workbench in
            guard let path = workbench.activeDocument?.path else { return }
            if workbench.groups.count < 2 { workbench.groups.append(EditorGroup()) }
            workbench.open(.markdownPreview(path), in: workbench.groups[workbench.groups.count - 1])
        }
        add("markdown.showPreview", "Open Preview", "Markdown", "⇧⌘V", enabled: { $0.activeDocument?.language.id == "markdown" }) { workbench in
            if let path = workbench.activeDocument?.path { workbench.open(.markdownPreview(path)) }
        }

        // Explorer
        add("explorer.newFile", "New File...", "File") { $0.showNewFileInput(folder: false) }
        add("explorer.newFolder", "New Folder...", "File") { $0.showNewFileInput(folder: true) }
        add("workbench.files.action.refreshFilesExplorer", "Refresh Explorer", "File") { workbench in Task { await workbench.workspace.refresh() } }
        add("workbench.files.action.collapseExplorerFolders", "Collapse Folders in Explorer", "File") { $0.workspace.collapseAll() }

        // Help
        add("workbench.action.openWelcome", "Welcome", "Help") { $0.open(.welcome) }
        add("workbench.action.showOutput", "Show Log", "Developer") { $0.showPanel(.output) }
    }
}

extension Workbench {
    func showView(_ view: SideBarView) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if sideBarVisible, activeView == view, view != .search {
                // VS Code toggles the side bar when the active view's icon is clicked again.
                sideBarVisible = false
            } else {
                activeView = view
                sideBarVisible = true
                zenMode = false
            }
        }
    }

    func showPanel(_ kind: PanelKind) {
        withAnimation(.easeInOut(duration: 0.18)) {
            activePanel = kind
            panelVisible = true
        }
        if kind == .terminal, terminals.sessions.isEmpty { terminals.newLocalSession() }
    }

    func convertIndentation(toSpaces: Bool) {
        guard let document = activeDocument, let controller = activeController else { return }
        let unit = String(repeating: " ", count: document.indentation.tabSize)
        let lines = document.text.components(separatedBy: "\n").map { line -> String in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let width = document.indentation.width(of: leading)
            let rest = line.dropFirst(leading.count)
            let indent = toSpaces ? String(repeating: " ", count: width) : String(repeating: "\t", count: width / document.indentation.tabSize) + String(repeating: " ", count: width % document.indentation.tabSize)
            return indent + rest
        }
        _ = unit
        controller.apply(TextEdit(range: NSRange(location: 0, length: document.storage.length), replacement: lines.joined(separator: "\n"), selection: controller.textView.selectedRange))
        document.setIndentation(Indentation(tabSize: document.indentation.tabSize, insertSpaces: toSpaces))
    }
}
