import SwiftUI
import TideCore

/// VS Code's Welcome page: Start actions, recent files and shortcuts.
struct WelcomeView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tide").font(.system(size: 44, weight: .light))
                        Text("Editing evolved, for iPad and iPhone").font(.system(size: 19)).foregroundStyle(theme.color("descriptionForeground"))
                    }
                    section("Start") {
                        link("doc.badge.plus", "New File...") { workbench.run("workbench.action.files.newUntitledFile") }
                        link("folder", "Open Folder...") { workbench.run("workbench.action.files.openFolder") }
                        link("shippingbox", "Open Sample Workspace") { workbench.run("workbench.action.files.openSampleFolder") }
                        link("terminal", "Open Terminal") { workbench.run("workbench.action.terminal.toggleTerminal") }
                    }
                    section("Recent") {
                        if workbench.recentFiles.isEmpty {
                            Text("Files you open appear here.").foregroundStyle(theme.color("descriptionForeground")).font(.system(size: 13))
                        }
                        ForEach(workbench.recentFiles.prefix(8), id: \.self) { path in
                            HStack(spacing: 6) {
                                link(nil, WorkspacePath.name(of: path)) { Task { await workbench.open(path, preview: false) } }
                                Text(WorkspacePath.parent(of: path)).font(.system(size: 12)).foregroundStyle(theme.color("descriptionForeground"))
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 28) {
                    section("Walkthroughs") {
                        card("command", "Find any command", "Press ⇧⌘P to search every command, ⌘P to jump to a file, then : for a line or @ for a symbol.")
                        card("rectangle.split.3x1", "Make it yours", "Pick a color theme with ⌘K ⌘T, import a VS Code theme, or edit settings.json.") {
                            workbench.run("workbench.action.selectTheme")
                        }
                        card("keyboard", "Code with the on-screen keyboard", "The keyboard bar adds Tab, brackets, arrows and undo above the iOS keyboard.")
                        card("server.rack", "Work on a remote machine", "Connect to an SSH host from the Remote Explorer and use its shell in the terminal panel.")
                    }
                    Toggle("Show welcome page on startup", isOn: Binding(
                        get: { workbench.settings.string("workbench.startupEditor") == "welcomePage" },
                        set: { workbench.set("workbench.startupEditor", .string($0 ? "welcomePage" : "none")) }
                    ))
                    .font(.system(size: 13))
                    .frame(maxWidth: 360)
                }
            }
            .padding(48)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .foregroundStyle(theme.color("foreground"))
        .accessibilityIdentifier("welcome")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 19, weight: .regular))
            content()
        }
    }

    private func link(_ symbol: String?, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).frame(width: 18) }
                Text(title)
            }
            .font(.system(size: 14))
            .foregroundStyle(theme.color("textLink.foreground"))
        }
        .buttonStyle(.plain)
    }

    private func card(_ symbol: String, _ title: String, _ detail: String, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(theme.color("textLink.foreground")).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(theme.color("descriptionForeground")).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: 420, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("welcomePage.tileBackground").opacity(0.9)))
        }
        .buttonStyle(.plain)
    }
}

/// The Settings editor: search, categories and one control per setting,
/// writing straight to settings.json like VS Code's UI.
struct SettingsEditorView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var category: SettingDescriptor.Category?

    private var descriptors: [SettingDescriptor] {
        SettingsRegistry.descriptors.filter { descriptor in
            (category == nil || descriptor.category == category) && (query.isEmpty || descriptor.key.localizedCaseInsensitiveContains(query) || descriptor.title.localizedCaseInsensitiveContains(query) || descriptor.summary.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.color("descriptionForeground"))
                TextField("Search settings", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings-search")
                Text("\(descriptors.count) Settings").font(.system(size: 12)).foregroundStyle(theme.color("descriptionForeground"))
                Button {
                    Task { await workbench.openSettingsJSON() }
                } label: {
                    Image(systemName: "doc.text")
                }
                .accessibilityLabel("Open Settings (JSON)")
            }
            .padding(10)
            .background(theme.color("input.background"))
            .padding(16)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    categoryButton(nil, "Commonly Used")
                    ForEach(SettingDescriptor.Category.allCases, id: \.self) { item in categoryButton(item, item.rawValue) }
                }
                .frame(width: 170, alignment: .leading)
                .padding(.leading, 16)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(descriptors) { descriptor in
                            SettingRow(workbench: workbench, descriptor: descriptor)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .foregroundStyle(theme.color("foreground"))
    }

    private func categoryButton(_ value: SettingDescriptor.Category?, _ title: String) -> some View {
        Button {
            category = value
        } label: {
            Text(title)
                .font(.system(size: 13, weight: category == value ? .semibold : .regular))
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(category == value ? theme.color("list.inactiveSelectionBackground") : .clear)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingRow: View {
    @Bindable var workbench: Workbench
    let descriptor: SettingDescriptor
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(workbench.settings.isModified(descriptor.key) ? theme.color("settings.modifiedItemIndicator").opacity(1) : .clear)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(descriptor.category.rawValue + ": ").foregroundStyle(theme.color("descriptionForeground"))
                    Text(descriptor.title).fontWeight(.semibold)
                    if workbench.settings.isModified(descriptor.key) {
                        Button("Reset") { workbench.resetSetting(descriptor.key) }
                            .font(.system(size: 11))
                    }
                }
                .font(.system(size: 13))
                Text(descriptor.summary).font(.system(size: 12)).foregroundStyle(theme.color("descriptionForeground"))
                control
                Text(descriptor.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.color("descriptionForeground").opacity(0.7))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setting-\(descriptor.key)")
    }

    @ViewBuilder
    private var control: some View {
        switch descriptor.defaultValue {
        case .bool:
            Toggle(descriptor.title, isOn: Binding(get: { workbench.settings.bool(descriptor.key) }, set: { workbench.set(descriptor.key, .bool($0)) }))
                .labelsHidden()
        case .number:
            HStack {
                Stepper(value: Binding(get: { workbench.settings.number(descriptor.key) }, set: { workbench.set(descriptor.key, .number($0)) }), in: descriptor.range ?? 0...10_000, step: stepSize) {
                    Text(numberText).font(.system(size: 13, design: .monospaced))
                }
                .frame(maxWidth: 260)
            }
        case .string:
            if !descriptor.options.isEmpty || descriptor.key.hasSuffix("ColorTheme") || descriptor.key == "workbench.colorTheme" {
                let options = descriptor.options.isEmpty ? workbench.allThemes.map(\.name) : descriptor.options
                Picker(descriptor.title, selection: Binding(get: { workbench.settings.string(descriptor.key) }, set: { workbench.set(descriptor.key, .string($0)) })) {
                    ForEach(options, id: \.self) { option in Text(option == "\n" ? "\\n (LF)" : option == "\r\n" ? "\\r\\n (CRLF)" : option).tag(option) }
                }
                .pickerStyle(.menu)
            } else {
                TextField(descriptor.title, text: Binding(get: { workbench.settings.string(descriptor.key) }, set: { workbench.set(descriptor.key, .string($0)) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
        case .globs:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(workbench.settings.globs(descriptor.key), id: \.self) { glob in
                    Text(glob).font(.system(size: 12, design: .monospaced))
                }
                Text("Edit in settings.json").font(.system(size: 11)).foregroundStyle(theme.color("textLink.foreground"))
                    .onTapGesture { Task { await workbench.openSettingsJSON() } }
            }
        }
    }

    private var stepSize: Double { descriptor.key.contains("Delay") ? 100 : descriptor.key == "editor.lineHeight" ? 0.1 : 1 }

    private var numberText: String {
        let value = workbench.settings.number(descriptor.key)
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// A rendered Markdown preview that follows the document as it changes.
struct MarkdownPreview: View {
    @Bindable var workbench: Workbench
    let path: String
    @Environment(\.theme) private var theme
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.color("editor.foreground"))
        .task(id: workbench.document(for: path)?.version) {
            if let document = workbench.document(for: path) {
                text = document.text
            } else if let data = try? await workbench.workspace.fileSystem.read(path) {
                text = String(decoding: data, as: UTF8.self)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            VStack(alignment: .leading, spacing: 4) {
                inline(content).font(.system(size: [30, 24, 20, 17, 15, 14][min(level, 6) - 1], weight: .semibold))
                if level <= 2 { Divider() }
            }
        case .paragraph(let content):
            inline(content).font(.system(size: 15)).lineSpacing(4)
        case .bullet(let content, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square" : "square")
                } else {
                    Text("•")
                }
                inline(content).font(.system(size: 15))
            }
        case .code(let language, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.color("textCodeBlock.background")))
            .overlay(alignment: .topTrailing) {
                if !language.isEmpty { Text(language).font(.system(size: 10)).padding(6).opacity(0.6) }
            }
        case .quote(let content):
            HStack(spacing: 10) {
                Rectangle().fill(theme.color("textBlockQuote.border")).frame(width: 4)
                inline(content).font(.system(size: 15)).foregroundStyle(theme.color("descriptionForeground"))
            }
        case .rule:
            Divider()
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.system(size: 14, weight: index == 0 ? .semibold : .regular))
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
        }
    }

    private func inline(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(markdown)
    }
}

/// Block-level Markdown for the preview (inline syntax is left to AttributedString).
enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String, checked: Bool?)
    case code(language: String, String)
    case quote(String)
    case rule
    case table([[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var code: [String]?
        var codeLanguage = ""
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    blocks.append(.code(language: codeLanguage, code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); flushTable()
                code = []
                codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.isEmpty {
                flushParagraph(); flushTable()
            } else if trimmed.hasPrefix("|") {
                flushParagraph()
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"), trimmed[hashes] == " " {
                flushParagraph(); flushTable()
                blocks.append(.heading(trimmed.distance(from: trimmed.startIndex, to: hashes), String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                var item = String(trimmed.dropFirst(2))
                var checked: Bool?
                if item.hasPrefix("[ ] ") { checked = false; item.removeFirst(4) } else if item.lowercased().hasPrefix("[x] ") { checked = true; item.removeFirst(4) }
                blocks.append(.bullet(item, checked: checked))
            } else if let dot = trimmed.firstIndex(of: "."), Int(trimmed[..<dot]) != nil, trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                blocks.append(.bullet(trimmed, checked: nil))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let code { blocks.append(.code(language: codeLanguage, code.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }
}

/// Unified diff of a change in the Source Control view: HEAD against the
/// index for a staged change, the index against the working tree otherwise.
struct DiffView: View {
    @Bindable var workbench: Workbench
    let path: String
    let staged: Bool
    @Environment(\.theme) private var theme
    @State private var rows: [(kind: Character, old: Int?, new: Int?, text: String)] = []

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        Text(row.old.map { String($0) } ?? "").frame(width: 44, alignment: .trailing)
                        Text(row.new.map { String($0) } ?? "").frame(width: 44, alignment: .trailing)
                        Text(String(row.kind)).frame(width: 20)
                        Text(row.text)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(row.kind == "@" ? theme.color("descriptionForeground") : theme.color("editor.foreground"))
                    .frame(height: 20)
                    .background(row.kind == "+" ? theme.color("diffEditor.insertedLineBackground") : row.kind == "-" ? theme.color("diffEditor.removedLineBackground") : .clear)
                }
            }
            .padding(.vertical, 8)
        }
        .task {
            let index = await workbench.scm.indexContent(of: path)
            if staged {
                let head = await workbench.scm.headContent(of: path) ?? ""
                rows = Self.rows(old: head, new: index ?? "")
                return
            }
            // A conflicted file has no staged version; compare it with HEAD.
            var base = index
            if base == nil { base = await workbench.scm.headContent(of: path) }
            let current: String
            if let document = workbench.document(for: path) {
                current = document.text
            } else if let data = try? await workbench.workspace.fileSystem.read(path) {
                current = String(decoding: data, as: UTF8.self)
            } else {
                current = ""
            }
            rows = Self.rows(old: base ?? "", new: current)
        }
    }

    static func rows(old: String, new: String) -> [(kind: Character, old: Int?, new: Int?, text: String)] {
        let oldLines = LineDiff.lines(of: old)
        let newLines = LineDiff.lines(of: new)
        var result: [(Character, Int?, Int?, String)] = []
        var oldIndex = 0
        var newIndex = 0
        for hunk in LineDiff.diff(old: oldLines, new: newLines) {
            let contextStart = max(oldIndex, hunk.oldStart - 3)
            if contextStart > oldIndex { result.append(("@", nil, nil, "··· \(contextStart - oldIndex) unchanged lines")) }
            newIndex += contextStart - oldIndex
            oldIndex = contextStart
            while oldIndex < hunk.oldStart {
                result.append((" ", oldIndex + 1, newIndex + 1, oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
            for line in hunk.oldRange { result.append(("-", line + 1, nil, oldLines[line])) }
            for line in hunk.newRange { result.append(("+", nil, line + 1, newLines[line])) }
            oldIndex = hunk.oldStart + hunk.oldCount
            newIndex = hunk.newStart + hunk.newCount
            let contextEnd = min(oldLines.count, oldIndex + 3)
            while oldIndex < contextEnd {
                result.append((" ", oldIndex + 1, newIndex + 1, oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }
        if result.isEmpty { result.append(("@", nil, nil, "No changes")) }
        return result
    }
}

/// Every command with its shortcut, searchable.
struct KeyboardShortcutsView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type to search in keybindings", text: $query)
                .padding(10)
                .background(theme.color("input.background"))
                .padding(16)
            List {
                ForEach(workbench.commands.all.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || ($0.keybinding?.contains(query) ?? false) }) { command in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(command.label).font(.system(size: 13))
                            Text(command.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.color("descriptionForeground"))
                        }
                        Spacer()
                        if let keybinding = command.keybinding {
                            Text(keybinding)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(theme.color("keybindingLabel.background")))
                        }
                    }
                    .listRowBackground(theme.color("editor.background"))
                    .contentShape(Rectangle())
                    .onTapGesture { workbench.run(command.id) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .foregroundStyle(theme.color("foreground"))
    }
}
