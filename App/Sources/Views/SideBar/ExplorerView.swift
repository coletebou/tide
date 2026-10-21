import SwiftUI
import TideCore
import UIKit

/// The Explorer: Open Editors, the folder tree and the Outline.
struct ExplorerView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme
    @State private var openEditorsExpanded = false
    @State private var folderExpanded = true
    @State private var outlineExpanded = true
    @State private var pendingDelete: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Open Editors", isExpanded: $openEditorsExpanded)
            if openEditorsExpanded { openEditors }
            PaneHeader(title: workbench.workspace.name, isExpanded: $folderExpanded)
                .accessibilityIdentifier("explorer-folder-header")
            if folderExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRows, id: \.node.id) { row in
                            FileRow(workbench: workbench, node: row.node, depth: row.depth, pendingDelete: $pendingDelete)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .contextMenu { rootMenu }
            } else {
                Spacer(minLength: 0)
            }
            PaneHeader(title: "Outline", isExpanded: $outlineExpanded)
            if outlineExpanded { OutlineList(workbench: workbench).frame(maxHeight: 260) }
        }
        .confirmationDialog("Are you sure you want to delete '\(pendingDelete.map(WorkspacePath.name) ?? "")'?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let path = pendingDelete else { return }
                Task {
                    do {
                        try await workbench.workspace.delete(path)
                        workbench.deleted(path)
                    } catch {
                        workbench.show(error: error, prefix: "Unable to delete '\(WorkspacePath.name(of: path))'")
                    }
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private struct Row {
        let node: FileNode
        let depth: Int
    }

    private var visibleRows: [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(Row(node: node, depth: depth))
                if node.isDirectory, node.isExpanded, let children = node.children {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(workbench.workspace.root.children ?? [], depth: 0)
        return rows
    }

    @ViewBuilder
    private var rootMenu: some View {
        Button("New File...", systemImage: "doc.badge.plus") { workbench.showNewFileInput(folder: false, in: "") }
        Button("New Folder...", systemImage: "folder.badge.plus") { workbench.showNewFileInput(folder: true, in: "") }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await workbench.workspace.refresh() } }
    }

    private var openEditors: some View {
        VStack(spacing: 0) {
            ForEach(workbench.groups) { group in
                ForEach(group.tabs) { tab in
                    let isActive = group.activeTabID == tab.id && group.id == workbench.activeGroupID
                    HStack(spacing: 6) {
                        Button {
                            workbench.close(tab, in: group)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 18)
                        FileIcon(name: tab.title(in: workbench), size: 13)
                        Text(tab.title(in: workbench))
                            .font(.system(size: 13))
                            .italic(tab.isPreview)
                            .lineLimit(1)
                        if let path = tab.content.filePath {
                            Text(WorkspacePath.parent(of: path))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.color("descriptionForeground"))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.leading, 10)
                    .frame(height: 22)
                    .background(isActive ? theme.color("list.activeSelectionBackground") : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { workbench.activate(tab, in: group) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One row of the folder tree.
struct FileRow: View {
    @Bindable var workbench: Workbench
    @Bindable var node: FileNode
    let depth: Int
    @Binding var pendingDelete: String?
    @Environment(\.theme) private var theme

    private var isActive: Bool { workbench.activeDocument?.path == node.path }
    private var isDirty: Bool { workbench.document(for: node.path)?.isDirty ?? false }

    var body: some View {
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("icon.foreground"))
                    .frame(width: 16)
            } else {
                Color.clear.frame(width: 16)
            }
            if !node.isDirectory {
                FileIcon(name: node.name, size: 14)
            }
            Text(node.name)
                .font(.system(size: 13))
                .foregroundStyle(nameColor)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let status = workbench.scm.changes.first(where: { $0.path == node.path }) {
                Text(status.kind.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(status.kind))
                    .padding(.trailing, 10)
            } else if isDirty {
                Circle().fill(theme.color("sideBar.foreground")).frame(width: 7, height: 7).padding(.trailing, 12)
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .frame(height: 22)
        .background(isActive ? theme.color("list.inactiveSelectionBackground") : .clear)
        .contentShape(Rectangle())
        .onTapGesture { activate(preview: true) }
        .onTapGesture(count: 2) { activate(preview: false) }
        .contextMenu { menu }
        .draggable(node.path)
        .dropDestination(for: String.self) { paths, _ in
            guard node.isDirectory else { return false }
            Task {
                for path in paths where path != node.path && !WorkspacePath.isDescendant(node.path, of: path) {
                    do {
                        let destination = try await workbench.workspace.move(path, toFolder: node.path)
                        workbench.renamed(path, to: destination)
                    } catch {
                        workbench.show(error: error, prefix: "Unable to move '\(WorkspacePath.name(of: path))'")
                    }
                }
            }
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("explorer-row-\(node.path)")
        .accessibilityAddTraits(.isButton)
    }

    private var nameColor: Color {
        if let status = workbench.scm.changes.first(where: { $0.path == node.path }) { return statusColor(status.kind) }
        return theme.color("sideBar.foreground")
    }

    private func statusColor(_ kind: SourceControlModel.ChangeKind) -> Color {
        switch kind {
        case .modified, .renamed: theme.color("gitDecoration.modifiedResourceForeground")
        case .added: theme.color("gitDecoration.addedResourceForeground")
        case .untracked: theme.color("gitDecoration.untrackedResourceForeground")
        case .deleted: theme.color("gitDecoration.deletedResourceForeground")
        case .conflicted: theme.color("gitDecoration.conflictingResourceForeground")
        }
    }

    private func activate(preview: Bool) {
        if node.isDirectory {
            Task { await workbench.workspace.toggle(node) }
        } else {
            Task { await workbench.open(node.path, preview: preview) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        let folder = node.isDirectory ? node.path : WorkspacePath.parent(of: node.path)
        if !node.isDirectory {
            Button("Open to the Side", systemImage: "rectangle.split.2x1") {
                Task {
                    if workbench.groups.count < 2 { workbench.groups.append(EditorGroup()) }
                    await workbench.open(node.path, preview: false, in: workbench.groups.last)
                }
            }
            if node.name.lowercased().hasSuffix(".md") {
                Button("Open Preview", systemImage: "eye") { workbench.open(.markdownPreview(node.path)) }
            }
            Divider()
        }
        Button("New File...", systemImage: "doc.badge.plus") { workbench.showNewFileInput(folder: false, in: folder) }
        Button("New Folder...", systemImage: "folder.badge.plus") { workbench.showNewFileInput(folder: true, in: folder) }
        Divider()
        Button("Copy Path", systemImage: "doc.on.clipboard") {
            UIPasteboard.general.string = workbench.workspace.localRoot.map { $0.appendingPathComponent(node.path).path } ?? node.path
        }
        Button("Copy Relative Path", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = node.path }
        Divider()
        Button("Rename...", systemImage: "pencil") { workbench.showRenameInput(for: node.path) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            Task {
                do { _ = try await workbench.workspace.duplicate(node.path) } catch { workbench.show(error: error, prefix: "Unable to duplicate") }
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = node.path }
    }
}

/// Document symbols of the active editor (the Explorer's Outline pane).
struct OutlineList: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        if let document = workbench.activeDocument, !document.symbols.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(document.symbols), id: \.symbol.id) { row in
                        Button {
                            workbench.activeController?.goTo(line: row.symbol.line, column: row.symbol.column)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: row.symbol.kind.iconName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.color("symbolIcon.functionForeground").opacity(0.9))
                                Text(row.symbol.name).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, CGFloat(row.depth) * 12 + 22)
                            .frame(height: 22)
                            .contentShape(Rectangle())
                            .background(row.symbol.line <= workbench.cursorLine && workbench.cursorLine <= row.symbol.endLine && row.isInnermost(workbench.cursorLine) ? theme.color("list.inactiveSelectionBackground") : .clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            Text(workbench.activeDocument == nil ? "No editor is open." : "No symbols found in document '\(workbench.activeDocument!.name)'.")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("descriptionForeground"))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Row {
        let symbol: DocumentSymbol
        let depth: Int

        func isInnermost(_ line: Int) -> Bool {
            !symbol.children.contains { $0.line <= line && line <= $0.endLine }
        }
    }

    private func rows(_ symbols: [DocumentSymbol], depth: Int = 0) -> [Row] {
        symbols.flatMap { [Row(symbol: $0, depth: depth)] + rows($0.children, depth: depth + 1) }
    }
}

extension EditorTab {
    func title(in workbench: Workbench) -> String {
        switch content {
        case .file(let path): WorkspacePath.name(of: path)
        case .userSettingsJSON: Workbench.settingsPath
        case .welcome: "Welcome"
        case .settings: "Settings"
        case .markdownPreview(let path): "Preview " + WorkspacePath.name(of: path)
        case .diff(let path): WorkspacePath.name(of: path) + " (Working Tree)"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        }
    }
}
