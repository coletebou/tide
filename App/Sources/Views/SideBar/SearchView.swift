import SwiftUI
import TideCore

/// Find in files, with VS Code's toggles (Aa, ab, .*), include/exclude
/// globs, replace, and results grouped by file.
struct SearchView: View {
    @Bindable var workbench: Workbench
    @Bindable var search: SearchModel
    @Environment(\.theme) private var theme
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                Button {
                    search.showReplace.toggle()
                } label: {
                    Image(systemName: search.showReplace ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle Replace")
                .accessibilityIdentifier("search-toggle-replace")
                VStack(spacing: 4) {
                    inputField("Search", text: $search.query, focused: true) {
                        toggle("Aa", "Match Case", $search.matchCase)
                        toggle("ab", "Match Whole Word", $search.wholeWord, underline: true)
                        toggle(".*", "Use Regular Expression", $search.isRegex)
                    }
                    if search.showReplace {
                        HStack(spacing: 4) {
                            inputField("Replace", text: $search.replacement) { EmptyView() }
                            Button {
                                Task { await search.replaceAll() }
                            } label: {
                                Image(systemName: "text.badge.checkmark").font(.system(size: 13)).frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .disabled(!search.canReplaceAll)
                            .accessibilityLabel("Replace All")
                            .accessibilityIdentifier("search-replace-all")
                        }
                    }
                }
            }
            Button {
                search.showDetails.toggle()
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-toggle-details")
            .padding(.trailing, 4)
            if search.showDetails {
                VStack(alignment: .leading, spacing: 2) {
                    Text("files to include").font(.system(size: 11)).foregroundStyle(theme.color("descriptionForeground"))
                    inputField("e.g. *.ts, src/**/include", text: $search.include) { EmptyView() }
                    Text("files to exclude").font(.system(size: 11)).foregroundStyle(theme.color("descriptionForeground"))
                    inputField("e.g. *.ts, src/**/exclude", text: $search.exclude) { EmptyView() }
                }
                .padding(.leading, 20)
            }
            if !search.summary.isEmpty {
                Text(search.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color(search.error == nil ? "descriptionForeground" : "errorForeground"))
                    .padding(.leading, 20)
                    .accessibilityIdentifier("search-summary")
            }
            results
        }
        .padding(.horizontal, 8)
        .onChange(of: search.focusRequest, initial: true) { _, _ in queryFocused = true }
    }

    /// One row of the results list: a file's header or one of its matches.
    private enum ResultRow: Identifiable {
        case file(FileSearchResult)
        case match(FileSearchResult, index: Int, SearchMatch)

        /// Unique across files. Matches nested per file and numbered from 0 in
        /// each repeated their ids in the lazy list, which then showed one
        /// file's match under another file and dropped others.
        var id: String {
            switch self {
            case .file(let file): "file:\(file.path)"
            case .match(let file, let index, _): "match:\(file.path)#\(index)"
            }
        }
    }

    private var resultRows: [ResultRow] {
        search.results.flatMap { file -> [ResultRow] in
            guard !search.collapsed.contains(file.path) else { return [.file(file)] }
            return [.file(file)] + file.matches.prefix(200).enumerated().map { .match(file, index: $0.offset, $0.element) }
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(resultRows) { row in
                    switch row {
                    case .file(let file): fileHeader(file)
                    case .match(let file, _, let match): matchRow(match, in: file)
                    }
                }
            }
        }
    }

    private func fileHeader(_ file: FileSearchResult) -> some View {
        let collapsed = search.collapsed.contains(file.path)
        return Button {
            if collapsed { search.collapsed.remove(file.path) } else { search.collapsed.insert(file.path) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 14)
                FileIcon(name: WorkspacePath.name(of: file.path), size: 13)
                Text(WorkspacePath.name(of: file.path)).font(.system(size: 13)).lineLimit(1)
                Text(WorkspacePath.parent(of: file.path)).font(.system(size: 11)).foregroundStyle(theme.color("descriptionForeground")).lineLimit(1)
                Spacer()
                Text("\(file.matches.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(theme.color("badge.background")))
                    .foregroundStyle(theme.color("badge.foreground"))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func matchRow(_ match: SearchMatch, in file: FileSearchResult) -> some View {
        Button {
            Task { await workbench.open(file.path, preview: true, line: match.line, column: match.range.location) }
        } label: {
            matchPreview(match)
                .padding(.leading, 34)
                .frame(height: 22, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search-match-\(file.path)-\(match.line)")
    }

    private func matchPreview(_ match: SearchMatch) -> some View {
        let preview = match.preview as NSString
        let before = preview.substring(to: match.previewRange.location)
        let matched = preview.substring(with: match.previewRange)
        let after = preview.substring(from: NSMaxRange(match.previewRange))
        var text = AttributedString(before)
        var highlight = AttributedString(matched)
        highlight.backgroundColor = theme.color("editor.findMatchHighlightBackground")
        if search.showReplace, !search.replacement.isEmpty {
            highlight.strikethroughStyle = .single
            var replacement = AttributedString(search.replacement)
            replacement.backgroundColor = theme.color("diffEditor.insertedTextBackground")
            highlight.append(replacement)
        }
        text.append(highlight)
        text.append(AttributedString(after))
        return Text(text).font(.system(size: 12)).lineLimit(1)
    }

    private func inputField<Accessory: View>(_ placeholder: String, text: Binding<String>, focused: Bool = false, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: text)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($queryFocused, equals: focused ? true : false)
                .padding(.leading, 6)
                .accessibilityIdentifier("search-\(placeholder.lowercased().prefix(12))")
            accessory()
        }
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 2).fill(theme.color("input.background")))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(theme.color("input.border"), lineWidth: 1))
    }

    private func toggle(_ label: String, _ help: String, _ value: Binding<Bool>, underline: Bool = false) -> some View {
        Button {
            value.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .underline(underline)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 3).fill(value.wrappedValue ? theme.color("inputOption.activeBackground") : .clear))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(value.wrappedValue ? theme.color("inputOption.activeBorder") : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
    }
}

/// Built-in languages and themes, and VS Code theme import.
struct ExtensionsView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var themesExpanded = true
    @State private var languagesExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Extensions", text: $query)
                .font(.system(size: 13))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 2).fill(theme.color("input.background")))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    PaneHeader(title: "Color Themes", isExpanded: $themesExpanded)
                    if themesExpanded {
                        ForEach(workbench.allThemes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                            extensionRow(icon: "paintpalette.fill", title: item.name, subtitle: item.id.hasPrefix("imported-") ? "Imported VS Code theme" : "Built-in \(item.kind.isDark ? "dark" : "light") theme", isActive: item.id == theme.id) {
                                workbench.set("workbench.colorTheme", .string(item.name))
                            }
                        }
                        Button("Import VS Code Color Theme...") { workbench.requestThemeImport = true }
                            .font(.system(size: 13))
                            .padding(10)
                    }
                    PaneHeader(title: "Languages", isExpanded: $languagesExpanded)
                    if languagesExpanded {
                        ForEach(LanguageRegistry.shared.languages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted { $0.name < $1.name }) { language in
                            extensionRow(icon: nil, fileName: "x.\(language.id)", title: language.name, subtitle: "Syntax highlighting, brackets and comments", isActive: false) {}
                        }
                    }
                }
            }
        }
    }

    private func extensionRow(icon: String?, fileName: String? = nil, title: String, subtitle: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 20))
                    } else {
                        FileIcon(name: fileName ?? "", size: 22)
                    }
                }
                .frame(width: 34, height: 34)
                .foregroundStyle(theme.color("textLink.foreground"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.color("descriptionForeground")).lineLimit(1)
                }
                Spacer()
                if isActive { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
