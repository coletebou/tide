import Foundation
import TideCore

/// A shell on an SSH host as a terminal connection. It connects when the
/// terminal starts; keys typed before the shell is up are sent once it is.
@MainActor
public final class SSHTerminalConnection: TerminalConnection {
    public var onEvent: ((TerminalConnectionEvent) -> Void)?
    public let target: SSHTarget
    private let options: SSHSessionOptions
    private var session: SSHShellSession?
    private var task: Task<Void, Never>?
    private var pendingInput: [UInt8] = []
    private var pendingSize: TerminalGridSize?
    private var closed = false

    public init(target: SSHTarget, options: SSHSessionOptions) {
        self.target = target
        self.options = options
    }

    public func start(size: TerminalGridSize) {
        onEvent?(.output(Array("\u{1B}[2mConnecting to \(target)...\u{1B}[0m\r\n".utf8)))
        task = Task { [weak self] in await self?.run(size: size) }
    }

    private func run(size: TerminalGridSize) async {
        let events: AsyncStream<TerminalConnectionEvent>
        do {
            let (session, stream) = try await SSHShellSession.open(target, size: size, options: options)
            guard !closed else {
                session.close()
                return
            }
            self.session = session
            events = stream
        } catch {
            guard !closed else { return }
            onEvent?(.ended(.failure((error as? LocalizedError)?.errorDescription ?? String(describing: error))))
            return
        }
        if let pendingSize, pendingSize != size { session?.resize(to: pendingSize) }
        if !pendingInput.isEmpty {
            session?.write(pendingInput)
            pendingInput = []
        }
        for await event in events {
            guard !closed else { break }
            onEvent?(event)
        }
    }

    public func send(_ bytes: [UInt8]) {
        guard !closed else { return }
        if let session {
            session.write(bytes)
        } else if pendingInput.count < 65_536 {
            pendingInput += bytes
        }
    }

    public func resize(to size: TerminalGridSize) {
        if let session {
            session.resize(to: size)
        } else {
            pendingSize = size
        }
    }

    /// A remote shell draws its own prompt; clearing leaves it alone.
    public func redrawAfterClear() {}

    public func close() {
        closed = true
        session?.close()
        task?.cancel()
    }
}
