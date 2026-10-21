import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import TideCore

/// An unknown host key, for the user to trust or refuse, as `ssh` asks
/// "The authenticity of host ... can't be established."
public struct SSHHostKeyPrompt: Equatable, Sendable {
    public var target: SSHTarget
    /// The key's type as known_hosts writes it, such as "ssh-ed25519".
    public var keyType: String
    /// The key, base64, as known_hosts writes it.
    public var key: String
    public var fingerprint: String

    /// "ED25519" or "ECDSA", as ssh names key types in its messages.
    public var displayType: String {
        switch keyType {
        case "ssh-ed25519": "ED25519"
        case let type where type.hasPrefix("ecdsa-"): "ECDSA"
        case "ssh-rsa": "RSA"
        default: keyType
        }
    }
}

/// What a session needs from the app: the keys to offer, the hosts the user
/// trusts, and the questions only the user can answer.
public struct SSHSessionOptions: Sendable {
    public var keys: [SSHUserKey]
    public var knownHosts: KnownHosts
    /// Asked about a host key the known hosts do not list; true trusts it.
    public var trustHostKey: @Sendable (SSHHostKeyPrompt) async -> Bool
    /// Asked for a password: 1 the first time, 2 after a wrong one, and so
    /// on. Nil stops trying.
    public var password: @Sendable (_ attempt: Int) async -> String?
    public var term = "xterm-256color"

    public init(keys: [SSHUserKey], knownHosts: KnownHosts, trustHostKey: @escaping @Sendable (SSHHostKeyPrompt) async -> Bool, password: @escaping @Sendable (_ attempt: Int) async -> String?) {
        self.keys = keys
        self.knownHosts = knownHosts
        self.trustHostKey = trustHostKey
        self.password = password
    }
}

/// Why a session could not start or did not finish, in words that read like
/// OpenSSH's for anyone who knows ssh.
public enum SSHConnectionError: Error, Equatable, LocalizedError {
    case unreachable(String)
    case hostKeyChanged(host: String, keyType: String, fingerprint: String, known: [String])
    case hostKeyRevoked(host: String, fingerprint: String)
    case hostKeyNotTrusted
    case unreadableHostKey
    case authenticationFailed(user: String)
    case terminalRefused
    case shellRefused
    case closed

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason):
            "Could not reach the host: \(reason)."
        case let .hostKeyChanged(host, keyType, fingerprint, known):
            "The \(keyType) host key for \(host) has changed: it is \(fingerprint), and the known hosts list \(known.joined(separator: ", ")). Someone could be intercepting the connection, or the host was reinstalled. Tide did not connect. If the change is expected, run Remote-SSH: Forget Host Key... and connect again."
        case let .hostKeyRevoked(host, fingerprint):
            "The host key \(fingerprint) for \(host) is marked as revoked in the known hosts. Tide did not connect."
        case .hostKeyNotTrusted:
            "The host key was not trusted, so Tide did not connect."
        case .unreadableHostKey:
            "The host sent a key Tide could not read."
        case .authenticationFailed(let user):
            "Permission denied for \(user): the host accepted none of the keys or passwords offered."
        case .terminalRefused:
            "The host refused to give the session a terminal."
        case .shellRefused:
            "The host refused to start a shell."
        case .closed:
            "The host closed the connection."
        }
    }
}

/// An interactive shell on an SSH host, on a pseudo-terminal. Its output
/// arrives on the stream `open` returns; input, resizes and closing go
/// through this handle, from any thread.
public final class SSHShellSession: Sendable {
    private let connection: any Channel
    private let channel: any Channel

    private init(connection: any Channel, channel: any Channel) {
        self.connection = connection
        self.channel = channel
    }

    /// Connects, checks the host key, logs in, and starts a shell on a pty
    /// of this size. The stream carries the shell's output and then one
    /// `.ended` with its exit status, or why it stopped.
    public static func open(_ target: SSHTarget, size: TerminalGridSize, options: SSHSessionOptions) async throws -> (SSHShellSession, AsyncStream<TerminalConnectionEvent>) {
        let failure = NIOLockedValueBox<(any Error)?>(nil)
        let authenticator = Authenticator(user: target.user, keys: options.keys.map(\.nioKey), password: options.password)
        let hostKeys = HostKeyChecker(target: target, knownHosts: options.knownHosts, trust: options.trustHostKey)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: authenticator, serverAuthDelegate: hostKeys)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try sync.addHandler(ssh)
                    try sync.addHandler(FailureRecorder(failure: failure))
                }
            }
        let connection: any Channel
        do {
            connection = try await bootstrap.connect(host: target.host, port: target.port).get()
        } catch {
            throw SSHConnectionError.unreachable(String(describing: error))
        }

        let (events, continuation) = AsyncStream<TerminalConnectionEvent>.makeStream()
        let started = connection.eventLoop.makePromise(of: Void.self)
        let term = options.term
        do {
            // The channel opens once the host has accepted the login.
            let channel = try await connection.eventLoop.flatSubmit {
                let promise = connection.eventLoop.makePromise(of: (any Channel).self)
                do {
                    let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(promise, channelType: .session) { child, _ in
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(ShellChannelHandler(term: term, size: size, events: continuation, started: started))
                        }
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult
            }.get()
            try await started.futureResult.get()
            return (SSHShellSession(connection: connection, channel: channel), events)
        } catch {
            connection.close(promise: nil)
            continuation.finish()
            // The host key check and the login fail the connection, which then
            // fails the channel too; their reason is the one worth reporting.
            throw failure.withLockedValue { $0 } ?? error
        }
    }

    /// Input for the shell: keys, pasted text, replies to terminal queries.
    public func write(_ bytes: [UInt8]) {
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes))), promise: nil)
    }

    /// Tells the host the terminal's new size (a window-change request).
    public func resize(to size: TerminalGridSize) {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: size.pixelWidth,
            terminalPixelHeight: size.pixelHeight
        )
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    /// Ends the session and the connection.
    public func close() {
        connection.close(promise: nil)
    }
}

/// Offers each key once, then asks for a password up to three times, as
/// OpenSSH's NumberOfPasswordPrompts does by default.
private final class Authenticator: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private struct State {
        var keys: [NIOSSHPrivateKey]
        var passwordAttempts = 0
    }

    private let user: String
    private let password: @Sendable (Int) async -> String?
    private let state: NIOLockedValueBox<State>

    init(user: String, keys: [NIOSSHPrivateKey], password: @escaping @Sendable (Int) async -> String?) {
        self.user = user
        self.password = password
        state = NIOLockedValueBox(State(keys: keys))
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let user = self.user
        if availableMethods.contains(.publicKey), let key = state.withLockedValue({ $0.keys.isEmpty ? nil : $0.keys.removeFirst() }) {
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
            return
        }
        let attempt = state.withLockedValue { state -> Int? in
            guard state.passwordAttempts < 3 else { return nil }
            state.passwordAttempts += 1
            return state.passwordAttempts
        }
        guard availableMethods.contains(.password), let attempt else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed(user: user))
            return
        }
        let password = self.password
        Task {
            guard let typed = await password(attempt) else {
                nextChallengePromise.fail(SSHConnectionError.authenticationFailed(user: user))
                return
            }
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .password(.init(password: typed))))
        }
    }
}

/// Checks the host's key against the known hosts, asking the user about a
/// key they do not list and refusing a changed or revoked one outright.
private final class HostKeyChecker: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let target: SSHTarget
    private let knownHosts: KnownHosts
    private let trust: @Sendable (SSHHostKeyPrompt) async -> Bool

    init(target: SSHTarget, knownHosts: KnownHosts, trust: @escaping @Sendable (SSHHostKeyPrompt) async -> Bool) {
        self.target = target
        self.knownHosts = knownHosts
        self.trust = trust
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let parts = KnownHosts.split(openSSHKey: String(openSSHPublicKey: hostKey)), let fingerprint = KnownHosts.fingerprint(parts.key) else {
            validationCompletePromise.fail(SSHConnectionError.unreadableHostKey)
            return
        }
        let prompt = SSHHostKeyPrompt(target: target, keyType: parts.keyType, key: parts.key, fingerprint: fingerprint)
        let name = KnownHosts.name(host: target.host, port: target.port)
        switch knownHosts.verdict(host: target.host, port: target.port, keyType: parts.keyType, key: parts.key) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .revoked:
            validationCompletePromise.fail(SSHConnectionError.hostKeyRevoked(host: name, fingerprint: fingerprint))
        case .changed(let known):
            validationCompletePromise.fail(SSHConnectionError.hostKeyChanged(host: name, keyType: prompt.displayType, fingerprint: fingerprint, known: known))
        case .unknown:
            let trust = self.trust
            Task {
                if await trust(prompt) {
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(SSHConnectionError.hostKeyNotTrusted)
                }
            }
        }
    }
}

/// Keeps the first error the connection reports (the host key check's or
/// the login's), then closes it.
private final class FailureRecorder: ChannelInboundHandler {
    typealias InboundIn = Any

    private let failure: NIOLockedValueBox<(any Error)?>

    init(failure: NIOLockedValueBox<(any Error)?>) {
        self.failure = failure
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failure.withLockedValue { recorded in
            if recorded == nil { recorded = error }
        }
        context.close(promise: nil)
    }
}

/// Runs a shell on the session channel: asks for a pty and a shell when the
/// channel opens, then forwards the output and the exit status.
private final class ShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let term: String
    private let size: TerminalGridSize
    private let events: AsyncStream<TerminalConnectionEvent>.Continuation
    private let started: EventLoopPromise<Void>
    private var replies = 0
    private var startCompleted = false
    private var exit: TerminalExit?

    init(term: String, size: TerminalGridSize, events: AsyncStream<TerminalConnectionEvent>.Continuation, started: EventLoopPromise<Void>) {
        self.term = term
        self.size = size
        self.events = events
        self.started = started
    }

    func channelActive(context: ChannelHandlerContext) {
        // IUTF8 (opcode 42) tells the host's line discipline the terminal
        // sends UTF-8, so a backspace erases a whole character.
        let modes = SSHTerminalModes([SSHTerminalModes.Opcode(rawValue: 42): SSHTerminalModes.OpcodeValue(rawValue: 1)])
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: size.pixelWidth,
            terminalPixelHeight: size.pixelHeight,
            terminalModes: modes
        )
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"), promise: nil)
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            // Replies come in the order of the requests that asked for one:
            // the pty's, then the shell's.
            replies += 1
            if replies == 2 { completeStart(.success(())) }
        case is ChannelFailureEvent:
            completeStart(.failure(replies == 0 ? SSHConnectionError.terminalRefused : SSHConnectionError.shellRefused))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exit = .status(Int32(truncatingIfNeeded: status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exit = .failure("The shell was ended by signal \(signal.signalName).")
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        events.yield(.output(Array(buffer.readableBytesView)))
    }

    func channelInactive(context: ChannelHandlerContext) {
        completeStart(.failure(SSHConnectionError.closed))
        events.yield(.ended(exit ?? .failure(SSHConnectionError.closed.errorDescription ?? "The host closed the connection.")))
        events.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        completeStart(.failure(error))
        context.close(promise: nil)
    }

    private func completeStart(_ result: Result<Void, any Error>) {
        guard !startCompleted else { return }
        startCompleted = true
        started.completeWith(result)
    }
}
