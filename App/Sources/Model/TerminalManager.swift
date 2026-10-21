import Foundation
import Observation
import SwiftTerm
import TideCore
import UIKit

/// One terminal in the panel. Local sessions run Tide's built-in shell over
/// the workspace; the SwiftTerm view renders it like any VT100 terminal, so
/// SSH sessions can use the same view later.
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private var shell: VirtualShell?
    @ObservationIgnored private var lineEditor = LineEditor()
    @ObservationIgnored private let delegateBridge: TerminalDelegateBridge
    @ObservationIgnored weak var workbench: Workbench?

    init(localRoot: URL?, title: String, workbench: Workbench) {
        self.title = title
        self.workbench = workbench
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        delegateBridge = TerminalDelegateBridge()
        view.terminalDelegate = delegateBridge
        view.accessibilityIdentifier = "terminal"
        delegateBridge.onSend = { [weak self] data in self?.received(data) }
        if let localRoot {
            shell = VirtualShell(root: localRoot)
            view.feed(text: "\u{1B}[2mTide built-in shell. Type 'help' for commands; connect a host from the Remote Explorer for a full shell.\u{1B}[0m\r\n")
            view.feed(text: shell!.prompt)
        } else {
            view.feed(text: "This workspace has no local folder. Open a terminal on the remote host instead.\r\n")
        }
    }

    func apply(theme: Theme, settings: SettingsStore) {
        let ansiKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let colors = (ansiKeys.map { "terminal.ansi\($0)" } + ansiKeys.map { "terminal.ansiBright\($0)" }).map { key -> SwiftTerm.Color in
            let color = theme[key]
            return SwiftTerm.Color(red: UInt16(color.red * 65535), green: UInt16(color.green * 65535), blue: UInt16(color.blue * 65535))
        }
        view.installColors(colors)
        view.nativeBackgroundColor = theme.uiColor("terminal.background")
        view.nativeForegroundColor = theme.uiColor("terminal.foreground")
        view.caretColor = theme.uiColor("terminalCursor.foreground")
        view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(settings.number("terminal.integrated.fontSize")), weight: .regular)
        view.getTerminal().setCursorStyle(Self.cursorStyle(settings.string("terminal.integrated.cursorStyle"), blinking: settings.bool("terminal.integrated.cursorBlinking")))
    }

    /// VS Code's cursor style names. As in VS Code the cursor is steady unless
    /// blinking is turned on, which also spares the battery an endless animation.
    static func cursorStyle(_ name: String, blinking: Bool) -> CursorStyle {
        switch name {
        case "line": blinking ? .blinkBar : .steadyBar
        case "underline": blinking ? .blinkUnderline : .steadyUnderline
        default: blinking ? .blinkBlock : .steadyBlock
        }
    }

    func clear() {
        view.feed(text: "\u{1B}[2J\u{1B}[H")
        if let shell { view.feed(text: shell.prompt + lineEditor.line) }
    }

    private func received(_ data: ArraySlice<UInt8>) {
        guard let shell else { return }
        for event in lineEditor.feed(data, history: shell.history) {
            switch event {
            case .output(let text):
                view.feed(text: text)
            case .submit(let line):
                let result = shell.run(line)
                if result.clearScreen { view.feed(text: "\u{1B}[2J\u{1B}[H") }
                view.feed(text: result.text)
                for path in result.openFiles {
                    Task { await workbench?.open(path, preview: false) }
                }
                if line.trimmingCharacters(in: .whitespaces) == "exit" {
                    workbench?.terminals.close(self)
                    return
                }
                title = WorkspacePath.name(of: shell.displayDirectory).isEmpty ? "tide-sh" : "tide-sh: " + WorkspacePath.name(of: shell.displayDirectory)
                view.feed(text: shell.prompt)
            case .interrupt:
                view.feed(text: shell.prompt)
            case .clearScreen:
                view.feed(text: "\u{1B}[2J\u{1B}[H" + shell.prompt + lineEditor.line)
            case .complete(let line):
                let options = shell.completions(for: line)
                let word = line.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
                if options.count == 1 {
                    let suffix = String(options[0].dropFirst(word.count)) + (options[0].hasSuffix("/") ? "" : " ")
                    view.feed(text: lineEditor.insert(suffix))
                } else if options.count > 1 {
                    let common = options.dropFirst().reduce(options[0]) { prefix, option in String(zip(prefix, option).prefix { $0 == $1 }.map(\.0)) }
                    if common.count > word.count {
                        view.feed(text: lineEditor.insert(String(common.dropFirst(word.count))))
                    } else {
                        view.feed(text: "\r\n" + options.map { WorkspacePath.name(of: $0.hasSuffix("/") ? String($0.dropLast()) : $0) + ($0.hasSuffix("/") ? "/" : "") }.joined(separator: "  ") + "\r\n" + shell.prompt + lineEditor.line)
                    }
                }
            }
        }
    }
}

/// SwiftTerm's delegate protocol, forwarded to closures.
final class TerminalDelegateBridge: NSObject, TerminalViewDelegate {
    var onSend: ((ArraySlice<UInt8>) -> Void)?
    var onTitle: ((String) -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onSend?(data) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
    func clipboardRead(source: TerminalView) -> Data? { UIPasteboard.general.string?.data(using: .utf8) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@Observable
final class TerminalManager {
    private(set) var sessions: [TerminalSession] = []
    var activeSessionID: UUID?
    @ObservationIgnored weak var workbench: Workbench?
    @ObservationIgnored private var counter = 0

    var activeSession: TerminalSession? { sessions.first { $0.id == activeSessionID } ?? sessions.last }

    func newLocalSession() {
        guard let workbench else { return }
        counter += 1
        let session = TerminalSession(localRoot: workbench.workspace.localRoot, title: "tide-sh", workbench: workbench)
        session.apply(theme: workbench.theme, settings: workbench.settings)
        sessions.append(session)
        activeSessionID = session.id
    }

    func close(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id { activeSessionID = sessions.last?.id }
    }

    func clearActive() { activeSession?.clear() }

    func apply(theme: Theme, settings: SettingsStore) {
        for session in sessions { session.apply(theme: theme, settings: settings) }
    }

    func workspaceChanged() {
        sessions = []
        activeSessionID = nil
    }
}
