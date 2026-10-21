import Foundation
import TideCore
@testable import TideSSH

/// The OpenSSH server scripts/ssh-test-server.sh runs for these tests, started
/// once per test run and stopped when it ends. Nil where there is no sshd;
/// CI sets TIDE_REQUIRE_SSHD=1, which makes that a failure there.
struct TestSSHServer: Sendable {
    let host: String
    let port: Int
    let user: String
    let directory: URL

    static let shared: TestSSHServer? = start()

    static var isRequired: Bool { ProcessInfo.processInfo.environment["TIDE_REQUIRE_SSHD"] == "1" }

    var target: SSHTarget { SSHTarget(user: user, host: host, port: port) }

    /// One of the client keys the server accepts: client_ed25519, client_ecdsa.
    func key(_ name: String) throws -> SSHUserKey {
        try SSHUserKey(openSSHPrivateKey: String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
    }

    /// The server's host key, as known_hosts lists it.
    func hostKey() throws -> (keyType: String, key: String) {
        let line = try String(contentsOf: directory.appendingPathComponent("host_ed25519.pub"), encoding: .utf8)
        guard let parts = KnownHosts.split(openSSHKey: line) else { throw SSHKeyError.corrupt }
        return parts
    }

    /// Known hosts that list this server's key.
    func knownHosts() throws -> KnownHosts {
        let hostKey = try hostKey()
        var hosts = KnownHosts()
        hosts.add(host: host, port: port, keyType: hostKey.keyType, key: hostKey.key)
        return hosts
    }

    private static func start() -> TestSSHServer? {
        // This file is Packages/TideSSH/Tests/TideSSHTests/TestSupport.swift.
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tide-sshd-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appendingPathComponent("scripts/ssh-test-server.sh").path, "start", directory.path]
        // No pipe: the daemon would inherit it and keep it open.
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let env = try? String(contentsOf: directory.appendingPathComponent("env"), encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in env.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        guard let host = values["TIDE_SSH_HOST"], let port = values["TIDE_SSH_PORT"].flatMap(Int.init), let user = values["TIDE_SSH_USER"] else { return nil }
        serverDirectory = directory.path
        atexit {
            guard let directory = serverDirectory,
                  let pid = (try? String(contentsOfFile: directory + "/sshd.pid", encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return }
            kill(pid, SIGTERM)
        }
        return TestSSHServer(host: host, port: port, user: user, directory: directory)
    }
}

/// Where the server lives, for the exit handler, which cannot capture it.
private nonisolated(unsafe) var serverDirectory: String?

/// Collects a session's output and how it ended, as they arrive.
final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var exit: TerminalExit?

    init(_ events: AsyncStream<TerminalConnectionEvent>) {
        Task {
            for await event in events { self.record(event) }
        }
    }

    var output: String { lock.withLock { text } }
    var end: TerminalExit? { lock.withLock { exit } }

    /// Waits for the output to contain `needle`; false on timeout.
    func wait(for needle: String, timeout: Duration = .seconds(20)) async -> Bool {
        await poll(timeout) { self.output.contains(needle) }
    }

    /// Waits for the session to end, and says how it did.
    func waitForEnd(timeout: Duration = .seconds(20)) async -> TerminalExit? {
        _ = await poll(timeout) { self.end != nil }
        return end
    }

    private func record(_ event: TerminalConnectionEvent) {
        lock.withLock {
            switch event {
            case .output(let bytes): text += String(decoding: bytes, as: UTF8.self)
            case .ended(let end): exit = end
            case .title, .openFiles: break
            }
        }
    }
}

/// Polls `condition` every 50 ms until it holds or `timeout` passes.
func poll(_ timeout: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

/// Things a callback saw, readable once the call it was part of is over.
final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []

    func append(_ value: Value) { lock.withLock { items.append(value) } }
    var all: [Value] { lock.withLock { items } }
}

/// Runs ssh-keygen to make a key in `directory`; returns its path.
func sshKeygen(_ arguments: [String], name: String, in directory: URL) throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(name).path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-q", "-C", "tide-test"] + arguments + ["-f", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SSHKeyError.corrupt }
    return path
}
