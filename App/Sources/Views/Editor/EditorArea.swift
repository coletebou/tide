import SwiftUI
import TideCore
import UIKit

/// Editor groups side by side (⌘\ splits).
struct EditorArea: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(workbench.groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { Rectangle().fill(theme.color("editorGroup.border")).frame(width: 1) }
                EditorGroupView(workbench: workbench, group: group)
            }
        }
    }
}

struct EditorGroupView: View {
    @Bindable var workbench: Workbench
    @Bindable var group: EditorGroup
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if !group.tabs.isEmpty {
                TabBar(workbench: workbench, group: group)
            }
            if let tab = group.activeTab {
                if case .file(let path) = tab.content {
                    BreadcrumbsBar(workbench: workbench, path: path)
                }
                content(for: tab)
                    .id(tab.id)
            } else {
                EmptyEditorWatermark(workbench: workbench)
            }
        }
        .background(theme.color("editor.background"))
        .simultaneousGesture(TapGesture().onEnded { workbench.activeGroupID = group.id })
    }

    @ViewBuilder
    private func content(for tab: EditorTab) -> some View {
        switch tab.content {
        case .file:
            if let controller = workbench.controller(for: tab) {
                CodeEditorView(controller: controller)
                    .overlay(alignment: .topTrailing) {
                        if controller.find.isVisible {
                            FindWidget(find: controller.find, controller: controller)
                                .padding(.trailing, controller.configuration.minimap ? 96 : 16)
                        }
                    }
                    .overlay(alignment: .top) {
                        if let document = workbench.document(for: tab.content.filePath ?? ""), document.hasConflict {
                            ConflictBanner(workbench: workbench, document: document)
                        }
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .welcome:
            WelcomeView(workbench: workbench)
        case .settings:
            SettingsEditorView(workbench: workbench)
        case .markdownPreview(let path):
            MarkdownPreview(workbench: workbench, path: path)
        case .diff(let path):
            DiffView(workbench: workbench, path: path)
        case .keyboardShortcuts:
            KeyboardShortcutsView(workbench: workbench)
        }
    }
}

/// Hosts an editor controller's UIKit view hierarchy.
struct CodeEditorView: UIViewRepresentable {
    let controller: EditorController

    func makeUIView(context: Context) -> EditorContainerView {
        controller.container
    }

    func updateUIView(_ view: EditorContainerView, context: Context) {}
}

/// The 35pt tab row.
struct TabBar: View {
    @Bindable var workbench: Workbench
    @Bindable var group: EditorGroup
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(group.tabs) { tab in
                            TabItem(workbench: workbench, group: group, tab: tab)
                                .id(tab.id)
                        }
                    }
                }
                .onChange(of: group.activeTabID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
            Spacer(minLength: 0)
            if group.activeTab?.content.filePath.map({ workbench.document(for: $0)?.language.id == "markdown" }) == true {
                tabAction("eye", "Open Preview to the Side") { workbench.run("markdown.showPreviewToSide") }
            }
            tabAction("rectangle.split.2x1", "Split Editor Right") { workbench.splitEditor() }
            Menu {
                Button("Close All", systemImage: "xmark.square") { workbench.closeAll(in: group) }
                Button("Close Saved", systemImage: "checkmark.square") { workbench.closeSaved(in: group) }
                Divider()
                Button("Toggle Minimap", systemImage: "sidebar.right") { workbench.run("editor.action.toggleMinimap") }
                Button("Toggle Word Wrap", systemImage: "text.word.spacing") { workbench.run("editor.action.toggleWordWrap") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 30, height: 35)
            }
            .foregroundStyle(theme.color("icon.foreground"))
        }
        .frame(height: 35)
        .background(theme.color("editorGroupHeader.tabsBackground"))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.color("editorGroupHeader.tabsBorder")).frame(height: 1) }
    }

    private func tabAction(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 30, height: 35).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("icon.foreground"))
        .accessibilityLabel(label)
    }
}

struct TabItem: View {
    @Bindable var workbench: Workbench
    @Bindable var group: EditorGroup
    let tab: EditorTab
    @Environment(\.theme) private var theme

    private var isActive: Bool { group.activeTabID == tab.id }
    private var isFocusedGroup: Bool { workbench.activeGroupID == group.id }
    private var isDirty: Bool { tab.content.filePath.flatMap { workbench.document(for: $0)?.isDirty } ?? false }

    var body: some View {
        let title = tab.title(in: workbench)
        HStack(spacing: 6) {
            switch tab.content {
            case .file(let path): FileIcon(name: WorkspacePath.name(of: path), size: 13)
            case .welcome: Image(systemName: "hand.wave").font(.system(size: 12))
            case .settings: Image(systemName: "gearshape").font(.system(size: 12))
            case .markdownPreview: Image(systemName: "eye").font(.system(size: 12))
            case .diff: Image(systemName: "plusminus").font(.system(size: 12))
            case .keyboardShortcuts: Image(systemName: "keyboard").font(.system(size: 12))
            }
            Text(title)
                .font(.system(size: 13))
                .italic(tab.isPreview)
                .lineLimit(1)
            Button {
                workbench.close(tab, in: group)
            } label: {
                ZStack {
                    if isDirty, !isActive {
                        Circle().fill(theme.color(isActive ? "tab.activeForeground" : "tab.inactiveForeground")).frame(width: 8, height: 8)
                    } else {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .opacity(isActive || isDirty ? 1 : 0.55)
                    }
                    if isDirty, isActive {
                        Circle().fill(theme.color("tab.activeForeground")).frame(width: 8, height: 8)
                            .background(Circle().fill(theme.color("tab.activeBackground")).frame(width: 14, height: 14))
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
        }
        .foregroundStyle(theme.color(isActive ? "tab.activeForeground" : "tab.inactiveForeground"))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 35)
        .frame(minWidth: 80)
        .background(theme.color(isActive ? "tab.activeBackground" : "tab.inactiveBackground"))
        .overlay(alignment: .top) {
            if isActive, isFocusedGroup {
                Rectangle().fill(theme.color("tab.activeBorderTop")).frame(height: 1)
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.color("tab.border")).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { workbench.activate(tab, in: group) }
        .onTapGesture(count: 2) { workbench.keepOpen(tab, in: group) }
        .contextMenu {
            Button("Close", systemImage: "xmark") { workbench.close(tab, in: group) }
            Button("Close Others") { workbench.closeOthers(tab, in: group) }
            Button("Close to the Right") { workbench.closeToTheRight(tab, in: group) }
            Button("Close Saved") { workbench.closeSaved(in: group) }
            Button("Close All") { workbench.closeAll(in: group) }
            Divider()
            if tab.isPreview {
                Button("Keep Open", systemImage: "pin") { workbench.keepOpen(tab, in: group) }
            }
            if let path = tab.content.filePath {
                Button("Copy Path", systemImage: "doc.on.clipboard") {
                    UIPasteboard.general.string = workbench.workspace.localRoot.map { $0.appendingPathComponent(path).path } ?? path
                }
                Button("Copy Relative Path") { UIPasteboard.general.string = path }
                Button("Reveal in Explorer View", systemImage: "sidebar.left") {
                    workbench.showView(.explorer)
                    Task { await workbench.workspace.reveal(path) }
                }
            }
            Divider()
            Button("Split Right", systemImage: "rectangle.split.2x1") {
                workbench.activate(tab, in: group)
                workbench.splitEditor()
            }
        }
        .accessibilityIdentifier("tab-\(title)")
    }
}

/// Path segments and the symbol at the cursor (22pt).
struct BreadcrumbsBar: View {
    @Bindable var workbench: Workbench
    let path: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            let components = WorkspacePath.components(of: path)
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 { chevron }
                Button {
                    if index == components.count - 1 {
                        workbench.showQuickInput(prefix: "@")
                    } else {
                        workbench.showQuickInput(prefix: components[0...index].joined(separator: "/") + "/")
                    }
                } label: {
                    HStack(spacing: 3) {
                        if index == components.count - 1 { FileIcon(name: component, size: 11) }
                        Text(component)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(symbolPath, id: \.id) { symbol in
                chevron
                Button {
                    workbench.showQuickInput(prefix: "@")
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: symbol.kind.iconName).font(.system(size: 10))
                        Text(symbol.name)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.color("breadcrumb.foreground"))
        .lineLimit(1)
        .padding(.leading, 14)
        .frame(height: 22)
        .background(theme.color("breadcrumb.background"))
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).opacity(0.7)
    }

    private var symbolPath: [DocumentSymbol] {
        guard let document = workbench.document(for: path) else { return [] }
        var chain: [DocumentSymbol] = []
        var level = document.symbols
        let line = workbench.cursorLine
        while let symbol = level.first(where: { $0.line <= line && line <= $0.endLine }) {
            chain.append(symbol)
            level = symbol.children
        }
        return chain
    }
}

/// VS Code's find widget, floating at the top right of the editor.
struct FindWidget: View {
    @Bindable var find: FindModel
    let controller: EditorController
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button {
                find.showReplace.toggle()
            } label: {
                Image(systemName: find.showReplace ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 26)
            }
            .buttonStyle(.plain)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    field("Find", text: $find.query)
                        .focused($focused)
                        .onSubmit { find.next() }
                    Text(find.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color(find.matches.isEmpty && !find.query.isEmpty ? "errorForeground" : "descriptionForeground"))
                        .frame(minWidth: 70, alignment: .leading)
                        .accessibilityIdentifier("find-summary")
                    iconButton("arrow.up", "Previous Match") { find.previous() }
                    iconButton("arrow.down", "Next Match") { find.next() }
                    iconButton("xmark", "Close") { controller.hideFind() }
                }
                if find.showReplace {
                    HStack(spacing: 4) {
                        field("Replace", text: $find.replacement)
                        iconButton("arrow.turn.down.right", "Replace") { find.replaceCurrent() }
                        iconButton("text.badge.checkmark", "Replace All") { find.replaceAll() }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(5)
        .frame(width: 430)
        .background(theme.color("editorWidget.background"))
        .overlay(alignment: .leading) { Rectangle().fill(theme.color("focusBorder")).frame(width: 3).opacity(focused ? 1 : 0) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.36), radius: 8, y: 2)
        .onChange(of: find.focusRequest, initial: true) { _, _ in focused = true }
        .onKeyPress(.escape) {
            controller.hideFind()
            return .handled
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: text)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.leading, 6)
                .accessibilityIdentifier("find-\(placeholder.lowercased())")
            if placeholder == "Find" {
                toggle("Aa", $find.matchCase)
                toggle("ab", $find.wholeWord)
                toggle(".*", $find.isRegex)
            }
        }
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 2).fill(theme.color("input.background")))
    }

    private func toggle(_ label: String, _ value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 3).fill(value.wrappedValue ? theme.color("inputOption.activeBackground") : .clear))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Shown when a file changed on disk while it had unsaved edits.
struct ConflictBanner: View {
    let workbench: Workbench
    let document: TextDocument
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.color("editorWarning.foreground"))
            Text("The file has changed on disk.").font(.system(size: 13))
            Spacer()
            Button("Revert") { Task { try? await document.revert() } }
            Button("Keep Mine") { document.hasConflict = false }
        }
        .padding(8)
        .background(theme.color("editorWidget.background"))
    }
}

/// VS Code's empty editor group: the shortcut watermark.
struct EmptyEditorWatermark: View {
    let workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "water.waves")
                .font(.system(size: 88, weight: .thin))
                .foregroundStyle(theme.color("editor.foreground").opacity(0.08))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                row("Show All Commands", "⇧ ⌘ P", "workbench.action.showCommands")
                row("Go to File", "⌘ P", "workbench.action.quickOpen")
                row("Find in Files", "⇧ ⌘ F", "workbench.view.search")
                row("Toggle Terminal", "⌃ `", "workbench.action.terminal.toggleTerminal")
                row("Open Folder", "⌘ O", "workbench.action.files.openFolder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ label: String, _ keys: String, _ command: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.color("editor.foreground").opacity(0.6))
                .gridColumnAlignment(.trailing)
            Button(keys) { workbench.run(command) }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.color("keybindingLabel.background")))
                .foregroundStyle(theme.color("keybindingLabel.foreground"))
        }
        .font(.system(size: 13))
    }
}
