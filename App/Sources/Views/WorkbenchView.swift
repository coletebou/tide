import SwiftUI
import TideCore

/// The VS Code workbench: activity bar, side bar, editor groups, panel and
/// status bar. Sizes follow VS Code's classic layout (48pt activity bar, 35pt
/// tabs, 22pt status bar, side bar and panel resizable by dragging).
struct WorkbenchView: View {
    @Bindable var workbench: Workbench
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var dragStartWidth: CGFloat?
    @State private var dragStartHeight: CGFloat?

    private var theme: Theme { workbench.theme }
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !workbench.zenMode {
                        ActivityBar(workbench: workbench)
                    }
                    if workbench.sideBarVisible, !workbench.zenMode, !compact {
                        SideBarContainer(workbench: workbench)
                            .frame(width: min(workbench.sideBarWidth, geometry.size.width * 0.6))
                        sideBarSash(maxWidth: geometry.size.width * 0.6)
                    }
                    VStack(spacing: 0) {
                        EditorArea(workbench: workbench)
                        if workbench.panelVisible, !workbench.zenMode {
                            panelSash(maxHeight: geometry.size.height * 0.8)
                            PanelView(workbench: workbench)
                                .frame(height: min(max(77, workbench.panelHeight), geometry.size.height * 0.8))
                        }
                    }
                    if workbench.secondarySideBarVisible, !workbench.zenMode, !compact {
                        Rectangle().fill(theme.color("sideBar.border")).frame(width: 1)
                        SecondarySideBar(workbench: workbench)
                            .frame(width: min(workbench.secondarySideBarWidth, geometry.size.width * 0.45))
                    }
                }
                if workbench.settings.bool("workbench.statusBar.visible"), !workbench.zenMode {
                    StatusBar(workbench: workbench)
                }
            }
            .overlay(alignment: .leading) {
                if compact, workbench.sideBarVisible, !workbench.zenMode {
                    compactSideBar(width: geometry.size.width)
                }
            }
            .overlay(alignment: .top) {
                if let model = workbench.quickInput {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.001)
                            .onTapGesture { model.cancel() }
                        QuickInputView(model: model)
                            .frame(width: min(620, geometry.size.width - 24))
                            .padding(.top, 8)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ToastStack(workbench: workbench)
                    .padding(.bottom, 30)
                    .padding(.trailing, 12)
            }
        }
        .background(theme.color("editor.background"))
        .environment(\.theme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.color("focusBorder"))
        .focusedSceneValue(\.workbench, workbench)
        .onAppear {
            if compact { workbench.sideBarVisible = false }
        }
    }

    private func compactSideBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { workbench.sideBarVisible = false } }
            HStack(spacing: 0) {
                ActivityBar(workbench: workbench)
                SideBarContainer(workbench: workbench)
            }
            .frame(width: min(width - 40, 380))
            .background(theme.color("sideBar.background"))
            .shadow(radius: 12)
            .transition(.move(edge: .leading))
        }
    }

    private func sideBarSash(maxWidth: CGFloat) -> some View {
        Rectangle()
            .fill(theme.color("sideBar.border"))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .hoverEffect(.highlight)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let start = dragStartWidth ?? workbench.sideBarWidth
                        dragStartWidth = start
                        workbench.sideBarWidth = min(maxWidth, max(170, start + value.translation.width))
                    }.onEnded { _ in dragStartWidth = nil })
            }
            .accessibilityIdentifier("sidebar-sash")
    }

    private func panelSash(maxHeight: CGFloat) -> some View {
        Rectangle()
            .fill(theme.color("panel.border"))
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 12)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let start = dragStartHeight ?? workbench.panelHeight
                        dragStartHeight = start
                        workbench.panelHeight = min(maxHeight, max(77, start - value.translation.height))
                    }.onEnded { _ in dragStartHeight = nil })
            }
    }
}

/// The 48pt icon strip on the left.
struct ActivityBar: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SideBarView.allCases) { view in
                activityButton(symbol: view.symbol, label: view.title, isActive: workbench.sideBarVisible && workbench.activeView == view, badge: badge(for: view)) {
                    workbench.showView(view)
                }
            }
            Spacer()
            activityButton(symbol: "sparkles", label: "Chat", isActive: workbench.secondarySideBarVisible, badge: nil) {
                workbench.run("workbench.action.toggleAuxiliaryBar")
            }
            Menu {
                Button("Command Palette...", systemImage: "command") { workbench.run("workbench.action.showCommands") }
                Button("Settings", systemImage: "gearshape") { workbench.run("workbench.action.openSettings") }
                Button("Keyboard Shortcuts", systemImage: "keyboard") { workbench.run("workbench.action.openGlobalKeybindings") }
                Button("Color Theme", systemImage: "paintpalette") { workbench.run("workbench.action.selectTheme") }
                Divider()
                Button("Open Folder...", systemImage: "folder") { workbench.run("workbench.action.files.openFolder") }
                Button("Welcome", systemImage: "hand.wave") { workbench.run("workbench.action.openWelcome") }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(theme.color("activityBar.inactiveForeground"))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Manage")
            .accessibilityIdentifier("activity-manage")
        }
        .frame(width: 48)
        .background(theme.color("activityBar.background"))
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.color("activityBar.border")).frame(width: 1)
        }
    }

    private func badge(for view: SideBarView) -> Int? {
        switch view {
        case .sourceControl: workbench.scmChangeCount > 0 ? workbench.scmChangeCount : nil
        case .explorer: workbench.dirtyCount > 0 ? workbench.dirtyCount : nil
        default: nil
        }
    }

    private func activityButton(symbol: String, label: String, isActive: Bool, badge: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(theme.color(isActive ? "activityBar.foreground" : "activityBar.inactiveForeground"))
                .frame(width: 48, height: 48)
                .overlay(alignment: .leading) {
                    if isActive {
                        Rectangle().fill(theme.color("activityBar.activeBorder")).frame(width: 2)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.color("activityBarBadge.foreground"))
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(theme.color("activityBarBadge.background")))
                            .padding(.trailing, 6)
                            .padding(.bottom, 8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityIdentifier("activity-\(label)")
    }
}

/// The 22pt status bar: remote and branch on the left; cursor, indentation,
/// encoding, line ending and language on the right, each opening its picker.
struct StatusBar: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let foreground = theme.color("statusBar.foreground")
        HStack(spacing: 0) {
            Button {
                workbench.showView(.remote)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: workbench.workspace.isRemote ? "server.rack" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    if workbench.workspace.isRemote { Text(workbench.workspace.name) }
                }
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .foregroundStyle(theme.color("statusBarItem.remoteForeground"))
                .background(theme.color("statusBarItem.remoteBackground"))
            }
            .accessibilityLabel("Remote")
            if let branch = workbench.gitBranch {
                item(symbol: "arrow.triangle.branch", text: branch) { workbench.showView(.sourceControl) }
            }
            let counts = workbench.problemCounts
            item(symbol: nil, text: nil) {
                workbench.showPanel(.problems)
            } content: {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle")
                    Text("\(counts.errors)")
                    Image(systemName: "exclamationmark.triangle").padding(.leading, 4)
                    Text("\(counts.warnings)")
                }
            }
            .accessibilityIdentifier("status-problems")
            Spacer(minLength: 4)
            if let document = workbench.activeDocument {
                let selection = workbench.selectionLength > 0 ? " (\(workbench.selectionLength) selected)" : ""
                item(symbol: nil, text: "Ln \(workbench.cursorLine + 1), Col \(workbench.cursorColumn + 1)\(selection)") { workbench.showQuickInput(prefix: ":") }
                    .accessibilityIdentifier("status-position")
                if sizeClass != .compact {
                    item(symbol: nil, text: document.indentation.insertSpaces ? "Spaces: \(document.indentation.tabSize)" : "Tab Size: \(document.indentation.tabSize)") { workbench.showIndentationPicker() }
                    item(symbol: nil, text: document.format.encoding.label) {}
                    item(symbol: nil, text: document.format.lineEnding.label) { workbench.showEOLPicker() }
                }
                item(symbol: "curlybraces", text: document.language.name) { workbench.showLanguagePicker() }
                    .accessibilityIdentifier("status-language")
            }
            item(symbol: workbench.toasts.isEmpty ? "bell" : "bell.badge", text: nil) { workbench.showPanel(.output) }
        }
        .font(.system(size: 12))
        .foregroundStyle(foreground)
        .frame(height: 22)
        .background(theme.color("statusBar.background"))
        .overlay(alignment: .top) { Rectangle().fill(theme.color("statusBar.border")).frame(height: 1) }
    }

    private func item(symbol: String?, text: String?, action: @escaping () -> Void) -> some View {
        item(symbol: symbol, text: text, action: action) { EmptyView() }
    }

    private func item<Content: View>(symbol: String?, text: String?, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                if let text { Text(text).lineLimit(1) }
                content()
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// Up to three toasts in the corner, like VS Code's notifications.
struct ToastStack: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(workbench.toasts) { toast in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: toast.kind == .error ? "xmark.circle.fill" : toast.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(toast.kind == .error ? theme.color("editorError.foreground") : toast.kind == .warning ? theme.color("editorWarning.foreground") : theme.color("editorInfo.foreground"))
                    Text(toast.message)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.color("notifications.foreground"))
                        .frame(maxWidth: 380, alignment: .leading)
                    Button {
                        workbench.toasts.removeAll { $0.id == toast.id }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("descriptionForeground"))
                    .accessibilityLabel("Clear Notification")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("notifications.background")))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.color("notifications.border"), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toast")
            }
        }
        .animation(.easeOut(duration: 0.2), value: workbench.toasts)
    }
}
