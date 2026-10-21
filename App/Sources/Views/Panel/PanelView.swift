import SwiftTerm
import SwiftUI
import TideCore

/// The bottom panel: Problems, Output and Terminal.
struct PanelView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(PanelKind.allCases) { kind in
                    Button {
                        workbench.activePanel = kind
                        if kind == .terminal, workbench.terminals.sessions.isEmpty { workbench.terminals.newLocalSession() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(kind.title).font(.system(size: 11))
                            if kind == .problems, workbench.problemCounts.errors + workbench.problemCounts.warnings > 0 {
                                Text("\(workbench.problemCounts.errors + workbench.problemCounts.warnings)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .background(Capsule().fill(theme.color("badge.background")))
                                    .foregroundStyle(theme.color("badge.foreground"))
                            }
                        }
                        .foregroundStyle(theme.color(workbench.activePanel == kind ? "panelTitle.activeForeground" : "panelTitle.inactiveForeground"))
                        .frame(height: 33)
                        .overlay(alignment: .bottom) {
                            if workbench.activePanel == kind { Rectangle().fill(theme.color("panelTitle.activeBorder")).frame(height: 1) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("panel-tab-\(kind.rawValue)")
                }
                Spacer()
                if workbench.activePanel == .terminal {
                    panelButton("plus", "New Terminal") { workbench.run("workbench.action.terminal.new") }
                    panelButton("trash", "Kill Terminal") {
                        if let session = workbench.terminals.activeSession { workbench.terminals.close(session) }
                    }
                }
                panelButton("chevron.up", "Maximize Panel Size") { workbench.panelHeight = 2_000 }
                panelButton("xmark", "Close Panel") { withAnimation { workbench.panelVisible = false } }
            }
            .padding(.horizontal, 12)
            switch workbench.activePanel {
            case .problems: ProblemsView(workbench: workbench)
            case .output: OutputView(lines: workbench.outputLog)
            case .terminal: TerminalPanelView(terminals: workbench.terminals)
            }
        }
        .background(theme.color("panel.background"))
    }

    private func panelButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("icon.foreground"))
        .accessibilityLabel(label)
    }
}

struct ProblemsView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        let problems = workbench.problems
        if problems.isEmpty {
            Text("No problems have been detected in the workspace.")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("descriptionForeground"))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(problems), id: \.id) { row in
                        if let diagnostic = row.diagnostic {
                            diagnosticRow(diagnostic, content: row.content)
                        } else {
                            fileRow(path: row.path, count: row.count)
                        }
                    }
                }
            }
            .foregroundStyle(theme.color("foreground"))
        }
    }

    /// A file's header or one of its diagnostics, as one flat list.
    private struct Row {
        /// Unique across files: a diagnostic's own id names no file, so rows
        /// nested per file could repeat ids, and the lazy list then shows
        /// one file's rows under another.
        let id: String
        let content: EditorContent
        let path: String
        let count: Int
        let diagnostic: Diagnostic?
    }

    private func rows(_ problems: [(content: EditorContent, path: String, diagnostics: [Diagnostic])]) -> [Row] {
        problems.flatMap { entry -> [Row] in
            let file = "\(entry.content)"
            return [Row(id: "file:\(file)", content: entry.content, path: entry.path, count: entry.diagnostics.count, diagnostic: nil)]
                + entry.diagnostics.enumerated().map { Row(id: "problem:\(file)#\($0.offset)", content: entry.content, path: entry.path, count: 0, diagnostic: $0.element) }
        }
    }

    private func fileRow(path: String, count: Int) -> some View {
        HStack(spacing: 6) {
            FileIcon(name: WorkspacePath.name(of: path), size: 12)
            Text(WorkspacePath.name(of: path)).font(.system(size: 13))
            Text(WorkspacePath.parent(of: path)).font(.system(size: 11)).foregroundStyle(theme.color("descriptionForeground"))
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .background(Capsule().fill(theme.color("badge.background")))
        }
        .padding(.leading, 12)
        .frame(height: 22)
    }

    private func diagnosticRow(_ diagnostic: Diagnostic, content: EditorContent) -> some View {
        Button {
            Task { await workbench.open(content, line: diagnostic.line, column: diagnostic.column) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: diagnostic.severity == .error ? "xmark.circle.fill" : diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(theme.color(diagnostic.severity == .error ? "editorError.foreground" : diagnostic.severity == .warning ? "editorWarning.foreground" : "editorInfo.foreground"))
                    .font(.system(size: 11))
                Text(diagnostic.message).font(.system(size: 13)).lineLimit(1)
                Text("\(diagnostic.source) [Ln \(diagnostic.line + 1), Col \(diagnostic.column + 1)]")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("descriptionForeground"))
                Spacer()
            }
            .padding(.leading, 34)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("problem-\(diagnostic.line)")
    }
}

struct OutputView: View {
    let lines: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).id(index)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1) }
        }
        .foregroundStyle(theme.color("editor.foreground"))
    }
}

struct TerminalPanelView: View {
    @Bindable var terminals: TerminalManager
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if let session = terminals.activeSession {
                TerminalHost(session: session)
                    .id(session.id)
                    .padding(.leading, 8)
            } else {
                Text("No terminal").foregroundStyle(theme.color("descriptionForeground")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if terminals.sessions.count > 1 {
                Rectangle().fill(theme.color("panel.border")).frame(width: 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(terminals.sessions) { session in
                        Button {
                            terminals.activeSessionID = session.id
                        } label: {
                            HStack {
                                Image(systemName: "terminal").font(.system(size: 11))
                                Text(session.title).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(session.id == terminals.activeSession?.id ? theme.color("list.inactiveSelectionBackground") : .clear)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 150)
            }
        }
    }
}

struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> TerminalView {
        session.view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}
}
