import Foundation
import Testing
@testable import TideCore

/// Records a connection's events. `output` is the text shown so far, without
/// colors or carriage returns, and `notices` are the other events in order.
@MainActor
private final class EventLog {
    private(set) var events: [TerminalConnectionEvent] = []

    init(_ connection: any TerminalConnection) {
        connection.onEvent = { [unowned self] event in self.events.append(event) }
    }

    var output: String {
        let bytes = events.flatMap { event -> [UInt8] in
            if case .output(let bytes) = event { return bytes }
            return []
        }
        return String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    var notices: [TerminalConnectionEvent] {
        events.filter { event in
            if case .output = event { return false }
            return true
        }
    }

    func clear() { events = [] }
}

private let size = TerminalGridSize(columns: 80, rows: 24)

@MainActor
struct LocalShellConnectionTests {
    @Test func startsWithTheBannerAndAPrompt() throws {
        let workspace = try TemporaryWorkspace()
        let shell = LocalShellConnection(root: workspace.url)
        let log = EventLog(shell)
        shell.start(size: size)
        #expect(log.output.hasPrefix("Tide built-in shell."))
        #expect(log.output.hasSuffix("\ntide@ipad \(workspace.url.lastPathComponent) % "))
        #expect(log.notices.isEmpty)
    }

    @Test func runsCommandsAndRetitlesTheTerminal() throws {
        let workspace = try TemporaryWorkspace(["src/main.swift": "print(1)\n"])
        let shell = LocalShellConnection(root: workspace.url)
        let log = EventLog(shell)
        #expect(shell.title == "tide-sh")
        shell.send(Array("cd src\r".utf8))
        #expect(log.notices == [.title("tide-sh: src")])
        log.clear()
        shell.send(Array("ls\r".utf8))
        #expect(log.output == "ls\nmain.swift\ntide@ipad src % ")
    }

    @Test func codeAsksToOpenFiles() throws {
        let workspace = try TemporaryWorkspace(["notes/todo.md": "- [ ] ship\n"])
        let shell = LocalShellConnection(root: workspace.url)
        let log = EventLog(shell)
        shell.send(Array("code notes/todo.md\r".utf8))
        #expect(log.notices.first == .openFiles(["notes/todo.md"]))
    }

    /// `exit` ends the shell: input after it in the same chunk is dropped,
    /// and later input is ignored.
    @Test func exitEndsTheShell() throws {
        let workspace = try TemporaryWorkspace()
        let shell = LocalShellConnection(root: workspace.url)
        let log = EventLog(shell)
        shell.send(Array("exit\rls\r".utf8))
        #expect(log.output == "exit\n")
        #expect(log.notices == [.ended(.status(0))])
        log.clear()
        shell.send(Array("ls\r".utf8))
        #expect(log.events.isEmpty)
    }

    @Test func redrawsThePromptAndLineAfterAClear() throws {
        let workspace = try TemporaryWorkspace()
        let shell = LocalShellConnection(root: workspace.url)
        let log = EventLog(shell)
        shell.send(Array("ech".utf8))
        log.clear()
        shell.redrawAfterClear()
        #expect(log.output == "tide@ipad \(workspace.url.lastPathComponent) % ech")
    }

    @Test func aWorkspaceWithoutAFolderGetsANotice() {
        let shell = LocalShellConnection(root: nil)
        let log = EventLog(shell)
        shell.start(size: size)
        #expect(log.output == "This workspace has no local folder. Open a terminal on the remote host instead.\n")
        log.clear()
        shell.send(Array("ls\r".utf8))
        #expect(log.events.isEmpty)
    }
}
