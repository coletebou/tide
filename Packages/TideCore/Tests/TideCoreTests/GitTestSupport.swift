import Foundation
import Testing
@testable import TideCore

/// A failed git command, with its standard error.
struct GitCommandError: Error, CustomStringConvertible {
    var arguments: [String]
    var status: Int32
    var message: String

    var description: String { "git \(arguments.joined(separator: " ")) exited \(status): \(message)" }
}

/// A temporary directory in which tests build real repositories with
/// `/usr/bin/git`, then compare the Swift reader with git's own output.
///
/// Git runs hermetically: no system or global configuration, `HOME` inside
/// the sandbox, a fixed locale and time zone. The directory is removed when
/// the sandbox is released.
final class GitSandbox {
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("tide-git-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("gitconfig").path, contents: Data())
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// `/usr/bin/git` is an xcrun shim; telling it the developer directory up
    /// front saves a slow lookup on every call.
    private static let developerDirectory: String? = {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { return configured }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !path.isEmpty ? path : nil
    }()

    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ADVICE": "0",
            "LC_ALL": "C",
            "TZ": "UTC",
            "TMPDIR": root.path,
        ]
        if let developer = Self.developerDirectory { environment["DEVELOPER_DIR"] = developer }
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// Runs git and returns its standard output.
    @discardableResult
    func gitData(
        _ arguments: [String],
        in directory: URL,
        input: Data? = nil,
        environment extra: [String: String] = [:],
        allowedStatus: Set<Int32> = [0]
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment(extra)
        let output = Pipe()
        process.standardOutput = output
        // Files rather than pipes for stdin and stderr, so large outputs cannot deadlock.
        let errorURL = root.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        process.standardError = errorHandle
        var inputURL: URL?
        if let input {
            let url = root.appendingPathComponent("stdin-\(UUID().uuidString)")
            try input.write(to: url)
            process.standardInput = try FileHandle(forReadingFrom: url)
            inputURL = url
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer {
            try? FileManager.default.removeItem(at: errorURL)
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
        }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try errorHandle.close()
        guard allowedStatus.contains(process.terminationStatus) else {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw GitCommandError(arguments: arguments, status: process.terminationStatus, message: message)
        }
        return data
    }

    /// Runs git and returns its standard output as text.
    @discardableResult
    func git(_ arguments: String..., in directory: URL, environment extra: [String: String] = [:]) throws -> String {
        String(decoding: try gitData(arguments, in: directory, environment: extra), as: UTF8.self)
    }

    /// The version of the git the tests run, such as `[2, 54, 0]` for
    /// "git version 2.54.0 (Apple Git-157)".
    func gitVersion() throws -> [Int] {
        let text = try git("--version", in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let number = text.split(separator: " ").dropFirst(2).first ?? ""
        return number.split(separator: ".").compactMap { Int($0) }
    }

    /// `git init` with branch `main` and a committer identity.
    func makeRepository(_ name: String = "repo", arguments: [String] = []) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try gitData(["init", "-q", "-b", "main"] + arguments + [url.path], in: root)
        try git("config", "user.name", "Tide Tests", in: url)
        try git("config", "user.email", "tests@tide.invalid", in: url)
        return url
    }

    /// Writes a file, creating parent directories.
    func write(_ text: String, to path: String, in repository: URL) throws {
        try write(Data(text.utf8), to: path, in: repository)
    }

    func write(_ data: Data, to path: String, in repository: URL) throws {
        let url = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func remove(_ path: String, in repository: URL) throws {
        try FileManager.default.removeItem(at: repository.appendingPathComponent(path))
    }

    func symlink(_ path: String, to destination: String, in repository: URL) throws {
        let url = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    /// Commits everything in the work tree.
    func commitAll(_ message: String, in repository: URL) throws {
        try git("add", "-A", in: repository)
        try git("commit", "-q", "--allow-empty", "-m", message, in: repository)
    }

    /// `git status --porcelain=v1 -uall --no-renames`, one `XY path` string per
    /// entry. `-z` keeps paths unquoted; optional locks are off so git does not
    /// rewrite the index while it looks.
    func porcelainStatus(_ repository: URL) throws -> [String] {
        let data = try gitData(
            ["--no-optional-locks", "status", "--porcelain=v1", "-uall", "--no-renames", "-z"],
            in: repository
        )
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The Swift reader's status in the same `XY path` form.
    func swiftStatus(_ repository: URL) throws -> [String] {
        let opened = try #require(GitRepository(workTree: repository))
        return try opened.status().porcelainLines
    }
}

extension GitStatus {
    /// Entries as `XY path` strings, the form of `git status --porcelain=v1 -z`.
    var porcelainLines: [String] {
        entries.map { "\($0.porcelainCode) \($0.path)" }
    }
}

extension GitRepository {
    /// Opens a repository the test just created.
    static func opened(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> GitRepository {
        try #require(GitRepository(workTree: url), sourceLocation: sourceLocation)
    }
}
