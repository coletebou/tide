import Foundation
import Testing
import TideCore
@testable import TideSSH

/// A public key the test server does not list, made with ssh-keygen for KnownHostsTests.
private let otherKey = "AAAAC3NzaC1lZDI1NTE5AAAAIB8SRn5sTQCub6otps8eUGL3MH8z2QV11CyF7bRNbrWX" // gitleaks:allow
private let otherFingerprint = "SHA256:M8OzUyO2CKx6Ym9l7s4bJXaZohxkvVn+YFLe+UuOXVo"
private let size = TerminalGridSize(columns: 80, rows: 24)

@Test func theTestServerRunsWhereItIsRequired() {
    #expect(!TestSSHServer.isRequired || TestSSHServer.shared != nil, "TIDE_REQUIRE_SSHD=1, but scripts/ssh-test-server.sh did not start an sshd")
}

/// Sessions against a real OpenSSH server on this machine.
@Suite(.enabled(if: TestSSHServer.shared != nil, "needs an sshd; scripts/ssh-test-server.sh starts one"))
struct SSHShellSessionTests {
    private let server = TestSSHServer.shared!

    private func options(
        keys: [SSHUserKey],
        knownHosts: KnownHosts,
        prompts: Recorded<SSHHostKeyPrompt> = Recorded(),
        trust: Bool = false,
        passwords: Recorded<Int> = Recorded()
    ) -> SSHSessionOptions {
        SSHSessionOptions(keys: keys, knownHosts: knownHosts, trustHostKey: { prompt in
            prompts.append(prompt)
            return trust
        }, password: { attempt in
            passwords.append(attempt)
            return nil
        })
    }

    @Test func runsAShellOnAPseudoTerminal() async throws {
        let prompts = Recorded<SSHHostKeyPrompt>()
        let (session, events) = try await SSHShellSession.open(server.target, size: size, options: options(keys: [try server.key("client_ed25519")], knownHosts: try server.knownHosts(), prompts: prompts))
        let log = SessionLog(events)
        session.write(Array("printf 'tide-%s\\n' $((6*7))\r".utf8))
        #expect(await log.wait(for: "tide-42"), "\(log.output)")
        session.write(Array("stty size\r".utf8))
        #expect(await log.wait(for: "24 80"), "\(log.output)")
        session.resize(to: TerminalGridSize(columns: 100, rows: 30))
        session.write(Array("stty size\r".utf8))
        #expect(await log.wait(for: "30 100"), "\(log.output)")
        session.write(Array("exit 3\r".utf8))
        #expect(await log.waitForEnd() == .status(3))
        #expect(prompts.all.isEmpty, "a listed host key needs no question")
    }

    @Test func logsInWithAnECDSAKey() async throws {
        let (session, events) = try await SSHShellSession.open(server.target, size: size, options: options(keys: [try server.key("client_ecdsa")], knownHosts: try server.knownHosts()))
        let log = SessionLog(events)
        session.write(Array("echo ecdsa-$((1+1))\r".utf8))
        #expect(await log.wait(for: "ecdsa-2"), "\(log.output)")
        session.close()
        #expect(await log.waitForEnd() != nil)
    }

    @Test func asksAboutAnUnknownHostKeyAndStopsWhenRefused() async throws {
        let prompts = Recorded<SSHHostKeyPrompt>()
        await #expect(throws: SSHConnectionError.hostKeyNotTrusted) {
            _ = try await SSHShellSession.open(server.target, size: size, options: options(keys: [try server.key("client_ed25519")], knownHosts: KnownHosts(), prompts: prompts))
        }
        let prompt = try #require(prompts.all.first)
        #expect(prompts.all.count == 1)
        #expect(prompt.target == server.target)
        #expect(prompt.displayType == "ED25519")
        #expect(prompt.fingerprint == KnownHosts.fingerprint(try server.hostKey().key))
    }

    @Test func connectsOnceTheHostKeyIsTrusted() async throws {
        let prompts = Recorded<SSHHostKeyPrompt>()
        let (session, events) = try await SSHShellSession.open(server.target, size: size, options: options(keys: [try server.key("client_ed25519")], knownHosts: KnownHosts(), prompts: prompts, trust: true))
        let log = SessionLog(events)
        session.write(Array("echo trusted-$((2+2))\r".utf8))
        #expect(await log.wait(for: "trusted-4"), "\(log.output)")
        #expect(prompts.all.count == 1)
        session.write(Array("exit\r".utf8))
        #expect(await log.waitForEnd() == .status(0))
    }

    @Test func refusesAChangedHostKeyWithoutAsking() async throws {
        let prompts = Recorded<SSHHostKeyPrompt>()
        var knownHosts = KnownHosts()
        knownHosts.add(host: server.host, port: server.port, keyType: "ssh-ed25519", key: otherKey)
        let expected = SSHConnectionError.hostKeyChanged(
            host: KnownHosts.name(host: server.host, port: server.port),
            keyType: "ED25519",
            fingerprint: try #require(KnownHosts.fingerprint(try server.hostKey().key)),
            known: [otherFingerprint]
        )
        await #expect(throws: expected) {
            _ = try await SSHShellSession.open(server.target, size: size, options: options(keys: [try server.key("client_ed25519")], knownHosts: knownHosts, prompts: prompts))
        }
        #expect(prompts.all.isEmpty)
    }

    /// The server takes keys only, so a key it does not list ends the login
    /// without a password question.
    @Test func reportsARefusedLogin() async throws {
        let passwords = Recorded<Int>()
        await #expect(throws: SSHConnectionError.authenticationFailed(user: server.user)) {
            _ = try await SSHShellSession.open(server.target, size: size, options: options(keys: [SSHUserKey.generateEd25519()], knownHosts: try server.knownHosts(), passwords: passwords))
        }
        #expect(passwords.all.isEmpty)
    }

    @Test func reportsAHostThatIsNotListening() async throws {
        await #expect(throws: SSHConnectionError.self) {
            _ = try await SSHShellSession.open(SSHTarget(user: server.user, host: "127.0.0.1", port: 1), size: size, options: options(keys: [], knownHosts: KnownHosts()))
        }
    }

    /// The connection a terminal uses: it says it is connecting, buffers keys
    /// typed before the shell is up, and reports the shell's exit.
    @MainActor
    @Test func drivesATerminalConnection() async throws {
        let connection = SSHTerminalConnection(target: server.target, options: options(keys: [try server.key("client_ed25519")], knownHosts: try server.knownHosts()))
        let (events, continuation) = AsyncStream<TerminalConnectionEvent>.makeStream()
        connection.onEvent = { continuation.yield($0) }
        let log = SessionLog(events)
        connection.start(size: size)
        connection.send(Array("echo early-$((3*3))\r".utf8))
        #expect(await log.wait(for: "Connecting to \(server.target)"))
        #expect(await log.wait(for: "early-9"), "\(log.output)")
        connection.send(Array("exit\r".utf8))
        #expect(await log.waitForEnd() == .status(0))
    }

    @MainActor
    @Test func endsATerminalConnectionThatCannotLogIn() async throws {
        let connection = SSHTerminalConnection(target: server.target, options: options(keys: [], knownHosts: try server.knownHosts()))
        let (events, continuation) = AsyncStream<TerminalConnectionEvent>.makeStream()
        connection.onEvent = { continuation.yield($0) }
        let log = SessionLog(events)
        connection.start(size: size)
        let end = await log.waitForEnd()
        #expect(end == .failure(SSHConnectionError.authenticationFailed(user: server.user).errorDescription!))
    }
}
