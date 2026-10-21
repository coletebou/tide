import Foundation

/// Tide's built-in shell as a terminal connection. iOS apps cannot start
/// processes, so a local folder's terminal runs `VirtualShell` over the
/// workspace, with `LineEditor` doing the line editing that a pty would
/// leave to a real shell. A workspace without a local folder gets a notice
/// instead of a shell.
@MainActor
public final class LocalShellConnection: TerminalConnection {
    public var onEvent: ((TerminalConnectionEvent) -> Void)?
    private let shell: VirtualShell?
    private var lineEditor = LineEditor()
    private var ended = false

    public init(root: URL?) {
        shell = root.map(VirtualShell.init(root:))
    }

    /// "tide-sh", or "tide-sh: src" once the shell has left the root.
    public var title: String {
        guard let shell, !WorkspacePath.name(of: shell.displayDirectory).isEmpty else { return "tide-sh" }
        return "tide-sh: " + WorkspacePath.name(of: shell.displayDirectory)
    }

    public func start(size: TerminalGridSize) {
        guard let shell else {
            write("This workspace has no local folder. Open a terminal on the remote host instead.\r\n")
            return
        }
        write("\u{1B}[2mTide built-in shell. Type 'help' for commands; connect a host from the Remote Explorer for a full shell.\u{1B}[0m\r\n")
        write(shell.prompt)
    }

    public func send(_ bytes: [UInt8]) {
        guard let shell, !ended else { return }
        var events = lineEditor.feed(bytes, history: shell.history)
        while true {
            for event in events {
                handle(event, shell: shell)
                if ended { return }
            }
            // The editor stops at a Tab so the completion lands before the
            // input after it, as when "ec\tfoo" is pasted; then it resumes.
            guard case .complete? = events.last else { return }
            events = lineEditor.feed([], history: shell.history)
        }
    }

    /// The built-in shell does not lay its output out to the terminal's width.
    public func resize(to size: TerminalGridSize) {}

    public func redrawAfterClear() {
        guard let shell, !ended else { return }
        write(shell.prompt + lineEditor.line)
    }

    public func close() {
        ended = true
    }

    private func handle(_ event: LineEditor.Event, shell: VirtualShell) {
        switch event {
        case .output(let text):
            write(text)
        case .submit(let line):
            let result = shell.run(line)
            if result.clearScreen { write("\u{1B}[2J\u{1B}[H") }
            write(result.text)
            if !result.openFiles.isEmpty { onEvent?(.openFiles(result.openFiles)) }
            if line.trimmingCharacters(in: .whitespaces) == "exit" {
                ended = true
                onEvent?(.ended(.status(result.exitCode)))
                return
            }
            onEvent?(.title(title))
            write(shell.prompt)
        case .interrupt:
            write(shell.prompt)
        case .clearScreen:
            write("\u{1B}[2J\u{1B}[H" + shell.prompt + lineEditor.line)
        case .complete(let line):
            complete(line, shell: shell)
        }
    }

    /// Completes the word before the cursor: a single match is inserted, a
    /// longer common prefix is inserted, and otherwise the options are listed.
    private func complete(_ line: String, shell: VirtualShell) {
        let options = shell.completions(for: line)
        let word = line.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if options.count == 1 {
            let suffix = String(options[0].dropFirst(word.count)) + (options[0].hasSuffix("/") ? "" : " ")
            write(lineEditor.insert(suffix))
        } else if options.count > 1 {
            let common = options.dropFirst().reduce(options[0]) { prefix, option in String(zip(prefix, option).prefix { $0 == $1 }.map(\.0)) }
            if common.count > word.count {
                write(lineEditor.insert(String(common.dropFirst(word.count))))
            } else {
                let names = options.map { WorkspacePath.name(of: $0.hasSuffix("/") ? String($0.dropLast()) : $0) + ($0.hasSuffix("/") ? "/" : "") }
                write("\r\n" + names.joined(separator: "  ") + "\r\n" + shell.prompt + lineEditor.line)
            }
        }
    }

    private func write(_ text: String) {
        guard !text.isEmpty else { return }
        onEvent?(.output(Array(text.utf8)))
    }
}
