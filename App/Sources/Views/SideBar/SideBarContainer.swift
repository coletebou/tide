import SwiftUI
import TideCore

/// The primary side bar: a title row (uppercase, like VS Code) and the active view.
struct SideBarContainer: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workbench.activeView.title.uppercased())
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.color("sideBarTitle.foreground"))
                    .padding(.leading, 20)
                Spacer()
                headerActions
            }
            .frame(height: 35)
            switch workbench.activeView {
            case .explorer: ExplorerView(workbench: workbench)
            case .search: SearchView(workbench: workbench, search: workbench.search)
            case .sourceControl: SourceControlView(workbench: workbench, scm: workbench.scm)
            case .remote: RemoteExplorerView(workbench: workbench)
            case .extensions: ExtensionsView(workbench: workbench)
            }
        }
        .background(theme.color("sideBar.background"))
        .foregroundStyle(theme.color("sideBar.foreground"))
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 2) {
            switch workbench.activeView {
            case .explorer:
                headerButton("doc.badge.plus", "New File...") { workbench.showNewFileInput(folder: false, in: "") }
                headerButton("folder.badge.plus", "New Folder...") { workbench.showNewFileInput(folder: true, in: "") }
                headerButton("arrow.clockwise", "Refresh Explorer") { Task { await workbench.workspace.refresh() } }
                headerButton("rectangle.compress.vertical", "Collapse Folders in Explorer") { workbench.workspace.collapseAll() }
            case .search:
                headerButton("arrow.clockwise", "Refresh") { workbench.search.rerun() }
                headerButton("xmark.circle", "Clear Search Results") { workbench.search.query = "" }
            case .sourceControl:
                headerButton("arrow.clockwise", "Refresh") { Task { await workbench.scm.refresh() } }
            default:
                EmptyView()
            }
        }
        .padding(.trailing, 8)
    }

    private func headerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("icon.foreground"))
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

/// A collapsible pane header ("OPEN EDITORS", "OUTLINE").
struct PaneHeader<Actions: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var actions: () -> Actions
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Spacer()
                actions()
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("sideBarSectionHeader.foreground"))
        .background(theme.color("sideBarSectionHeader.background"))
        .overlay(alignment: .top) { Rectangle().fill(theme.color("sideBarSectionHeader.border")).frame(height: 1) }
    }
}

extension PaneHeader where Actions == EmptyView {
    init(title: String, isExpanded: Binding<Bool>) {
        self.init(title: title, isExpanded: isExpanded) { EmptyView() }
    }
}

/// Text with fuzzy-match ranges drawn in `list.highlightForeground`, bold.
struct HighlightedText: View {
    let text: String
    let ranges: [Range<Int>]
    var color: Color
    var highlight: Color
    var font: Font = .system(size: 13)

    var body: some View {
        Text(attributed).font(font)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = color
        let characters = Array(text)
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= characters.count {
            let start = result.index(result.startIndex, offsetByCharacters: range.lowerBound)
            let end = result.index(result.startIndex, offsetByCharacters: range.upperBound)
            result[start..<end].foregroundColor = highlight
            result[start..<end].font = font.bold()
        }
        return result
    }
}
