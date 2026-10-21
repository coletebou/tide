import Foundation
import Observation
import TideCore
import UIKit

/// One terminal in the panel: an engine that draws it and a connection that
/// runs its shell, Tide's built-in shell for a local folder or a shell on an
/// SSH host. The session wires them together and knows neither's type.
@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    var title: String
    /// Shows the terminal's text as a read-only view instead of the terminal.
    private(set) var showsAccessibleBuffer = false
    private(set) var bufferText = ""
    @ObservationIgnored let engine: any TerminalEngine
    @ObservationIgnored private let connection: any TerminalConnection
    @ObservationIgnored weak var workbench: Workbench?
    /// Set once the shell has ended; the next key press closes the terminal.
    @ObservationIgnored private var ended = false

    init(id: UUID = UUID(), connection: any TerminalConnection, title: String, workbench: Workbench, engine: any TerminalEngine = SwiftTermEngine()) {
        self.id = id
        self.connection = connection
        self.title = title
        self.workbench = workbench
        self.engine = engine
        engine.onInput = { [weak self] bytes in self?.input(bytes) }
        engine.onGridResize = { [weak self] size in self?.connection.resize(to: size) }
        engine.onTitle = { [weak self] title in self?.title = title }
        connection.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start() {
        connection.start(size: engine.gridSize)
    }

    func apply(theme: Theme, settings: SettingsStore) {
        engine.apply(TerminalAppearance(theme: theme, settings: settings))
    }

    func clear() {
        engine.clear()
        connection.redrawAfterClear()
        if showsAccessibleBuffer { bufferText = engine.text() }
    }

    /// Ends the shell, as closing its terminal does.
    func terminate() {
        ended = true
        connection.close()
    }

    /// VS Code's accessible buffer: the terminal's text, which VoiceOver can
    /// read and a finger can select and copy.
    func showAccessibleBuffer() {
        bufferText = engine.text()
        showsAccessibleBuffer = true
    }

    func hideAccessibleBuffer() {
        showsAccessibleBuffer = false
    }

    private func input(_ bytes: [UInt8]) {
        guard !ended else {
            workbench?.terminals.close(self)
            return
        }
        connection.send(bytes)
    }

    private func handle(_ event: TerminalConnectionEvent) {
        switch event {
        case .output(let bytes):
            engine.feed(bytes)
            if showsAccessibleBuffer { bufferText = engine.text() }
        case .title(let title):
            self.title = title
        case .openFiles(let paths):
            for path in paths {
                Task { await workbench?.open(path, preview: false) }
            }
        case .ended(let exit):
            ended = true
            // As in VS Code, a shell that exits cleanly takes its terminal
            // with it; otherwise the terminal stays to show what happened.
            if exit == .status(0) {
                workbench?.terminals.close(self)
                return
            }
            let reason = switch exit {
            case .status(let code): "The shell exited with code \(code)."
            case .failure(let message): message
            }
            engine.feed(Array("\r\n\u{1B}[2m\(reason) Press any key to close the terminal.\u{1B}[0m\r\n".utf8))
        }
    }
}

@Observable
final class TerminalManager {
    private(set) var sessions: [TerminalSession] = []
    var activeSessionID: UUID?
    @ObservationIgnored weak var workbench: Workbench?

    var activeSession: TerminalSession? { sessions.first { $0.id == activeSessionID } ?? sessions.last }

    func newLocalSession() {
        guard let workbench else { return }
        let connection = LocalShellConnection(root: workbench.workspace.localRoot)
        add(TerminalSession(connection: connection, title: connection.title, workbench: workbench))
    }

    /// Shows a new session and starts its shell.
    func add(_ session: TerminalSession) {
        guard let workbench else { return }
        session.apply(theme: workbench.theme, settings: workbench.settings)
        sessions.append(session)
        activeSessionID = session.id
        session.start()
    }

    func close(_ session: TerminalSession) {
        cancelPrompt(of: session)
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id { activeSessionID = sessions.last?.id }
    }

    func clearActive() { activeSession?.clear() }

    /// A question only this terminal's connection is waiting on goes with it.
    private func cancelPrompt(of session: TerminalSession) {
        if let prompt = workbench?.quickInput, prompt.pickList?.owner == session.id { prompt.cancel() }
    }

    func apply(theme: Theme, settings: SettingsStore) {
        for session in sessions { session.apply(theme: theme, settings: settings) }
    }

    func workspaceChanged() {
        for session in sessions {
            cancelPrompt(of: session)
            session.terminate()
        }
        sessions = []
        activeSessionID = nil
    }
}
