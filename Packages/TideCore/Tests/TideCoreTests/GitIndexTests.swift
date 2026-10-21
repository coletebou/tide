import Foundation
import Testing
@testable import TideCore

struct GitIndexTests {
    /// Paths with long shared prefixes exercise the prefix compression of version 4.
    static let paths = [
        "README.md", "Sources/App/main.swift", "Sources/App/Views/ContentView.swift",
        "Sources/App/Views/ContentViewModel.swift", "Sources/Core/Model.swift", "Sources/Core/Model+Codable.swift",
        "Tests/AppTests/AppTests.swift", "a", "a b/c d.txt", "docs/naïve.md",
    ]

    /// Longer than the 12-bit length field (4095 bytes), and longer than any
    /// path the file system accepts, so it is added to the index directly.
    static let longPath = (0..<40).map { "segment\($0)" + String(repeating: "x", count: 100) }.joined(separator: "/")

    @Test(arguments: [2, 3, 4])
    func parsesEveryIndexVersionLikeGitLsFiles(version: Int) throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for (number, path) in Self.paths.enumerated() {
            try sandbox.write("file \(number)\n", to: path, in: repository)
        }
        try sandbox.git("add", "-A", in: repository)
        try sandbox.gitData(["hash-object", "-w", "--stdin"], in: repository, input: Data())
        try sandbox.git("update-index", "--add", "--cacheinfo", "100644,\(GitObjectID.emptyBlob.hex),\(Self.longPath)", in: repository)
        if version == 3 {
            // Version 3 is what git writes once an entry needs extended flags.
            try sandbox.git("update-index", "--skip-worktree", "a", in: repository)
        }
        try sandbox.git("update-index", "--index-version", "\(version)", in: repository)

        let index = try GitRepository.opened(repository).index()
        #expect(index.version == version)
        #expect(try index.entries.map(Self.stageLine) == Self.gitStageLines(sandbox, repository))
        #expect(index.entries.map(\.path).contains(Self.longPath))
        #expect(index.entries.map(\.path).contains("docs/naïve.md"))

        // Stat fields, as `git ls-files --debug` prints them.
        let debug = try sandbox.git("-c", "core.quotepath=false", "ls-files", "--debug", in: repository)
        let ours = index.entries.map { entry in
            [
                entry.path,
                "  ctime: \(entry.statusChangeTime.seconds):\(entry.statusChangeTime.nanoseconds)",
                "  mtime: \(entry.modificationTime.seconds):\(entry.modificationTime.nanoseconds)",
                "  dev: \(entry.device)\tino: \(entry.inode)",
                "  uid: \(entry.userID)\tgid: \(entry.groupID)",
            ].joined(separator: "\n")
        }
        let lines = debug.components(separatedBy: "\n")
        let theirs = stride(from: 0, to: lines.count, by: 6).map { lines[$0..<min($0 + 5, lines.count)].joined(separator: "\n") }
        #expect(ours == Array(theirs.prefix(ours.count)))
        let sizes = debug.components(separatedBy: "\n").filter { $0.hasPrefix("  size: ") }.map { line in
            line.dropFirst(8).prefix { $0 != "\t" }
        }
        #expect(index.entries.map { String($0.size) } == sizes.map(String.init))
    }

    @Test func readsAssumeValidSkipWorktreeAndIntentToAddFlags() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for name in ["assumed.txt", "skipped.txt", "plain.txt"] {
            try sandbox.write(name + "\n", to: name, in: repository)
        }
        try sandbox.commitAll("files", in: repository)
        try sandbox.write("new\n", to: "intended.txt", in: repository)
        try sandbox.git("add", "-N", "intended.txt", in: repository)
        try sandbox.git("update-index", "--assume-unchanged", "assumed.txt", in: repository)
        try sandbox.git("update-index", "--skip-worktree", "skipped.txt", in: repository)

        let index = try GitRepository.opened(repository).index()
        #expect(index.version == 3)
        let byPath = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.path, $0) })
        #expect(byPath["assumed.txt"]?.assumeValid == true)
        #expect(byPath["skipped.txt"]?.skipWorktree == true)
        #expect(byPath["intended.txt"]?.intentToAdd == true)
        #expect(byPath["intended.txt"]?.id == .emptyBlob)
        #expect(byPath["plain.txt"].map { !$0.assumeValid && !$0.skipWorktree && !$0.intentToAdd } == true)

        // `git ls-files -v` tags: lowercase for assume-unchanged, S for skip-worktree.
        let tags = try sandbox.git("ls-files", "-v", in: repository).split(separator: "\n").map { String($0.prefix(1)) }
        #expect(tags == index.entries.map { $0.skipWorktree ? "S" : $0.assumeValid ? "h" : "H" })
    }

    @Test func readsConflictStages() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("base\n", to: "both.txt", in: repository)
        try sandbox.commitAll("base", in: repository)
        try sandbox.git("switch", "-q", "-c", "other", in: repository)
        try sandbox.write("theirs\n", to: "both.txt", in: repository)
        try sandbox.commitAll("theirs", in: repository)
        try sandbox.git("switch", "-q", "main", in: repository)
        try sandbox.write("ours\n", to: "both.txt", in: repository)
        try sandbox.commitAll("ours", in: repository)
        _ = try? sandbox.git("merge", "-q", "other", in: repository)

        let index = try GitRepository.opened(repository).index()
        #expect(index.entries.map(\.stage) == [1, 2, 3])
        #expect(try index.entries.map(Self.stageLine) == Self.gitStageLines(sandbox, repository))
        #expect(index.entry(atPath: "both.txt") == nil)
        #expect(index.entry(atPath: "both.txt", stage: 2)?.id == GitObjectID.hash(.blob, Data("ours\n".utf8)))
    }

    @Test func mergesASplitIndexWithItsSharedIndex() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for number in 0..<30 {
            try sandbox.write("file \(number)\n", to: "dir\(number % 3)/file\(number).txt", in: repository)
        }
        try sandbox.commitAll("files", in: repository)
        try sandbox.git("config", "splitIndex.maxPercentChange", "100", in: repository)
        try sandbox.git("update-index", "--split-index", in: repository)
        // Replace, delete and add entries relative to the shared index.
        try sandbox.write("changed\n", to: "dir0/file3.txt", in: repository)
        try sandbox.git("add", "dir0/file3.txt", in: repository)
        try sandbox.git("rm", "-q", "--cached", "dir1/file4.txt", in: repository)
        try sandbox.write("added\n", to: "dir1/new.txt", in: repository)
        try sandbox.write("added\n", to: "aaa.txt", in: repository)
        try sandbox.git("add", "dir1/new.txt", "aaa.txt", in: repository)

        let gitDirectory = repository.appendingPathComponent(".git")
        let shared = try FileManager.default.contentsOfDirectory(atPath: gitDirectory.path).filter { $0.hasPrefix("sharedindex.") }
        #expect(!shared.isEmpty)
        let raw = try GitIndex(data: Data(contentsOf: gitDirectory.appendingPathComponent("index")))
        let sharedID = try #require(raw.sharedIndexID)
        let sharedIndex = try GitIndex(data: Data(contentsOf: gitDirectory.appendingPathComponent("sharedindex.\(sharedID.hex)")))
        #expect(sharedIndex.entries.count >= 29)
        // A changed shared entry is stored as a replacement with an empty path.
        // (git may also store refreshed, racily clean entries that way.)
        #expect(raw.entries.contains { $0.path.isEmpty })

        let opened = try GitRepository.opened(repository)
        let index = try opened.index()
        #expect(try index.entries.map(Self.stageLine) == Self.gitStageLines(sandbox, repository))
        #expect(try opened.status().porcelainLines == sandbox.porcelainStatus(repository))
    }

    @Test func expandsSparseIndexDirectories() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for directory in ["kept", "sparse/one", "sparse/two"] {
            for number in 0..<3 {
                try sandbox.write("\(directory) \(number)\n", to: "\(directory)/file\(number).txt", in: repository)
            }
        }
        try sandbox.write("root\n", to: "root.txt", in: repository)
        try sandbox.commitAll("tree", in: repository)
        try sandbox.git("sparse-checkout", "set", "--cone", "--sparse-index", "kept", in: repository)

        let raw = try GitIndex(data: Data(contentsOf: repository.appendingPathComponent(".git/index")))
        #expect(raw.isSparse)
        #expect(raw.entries.contains { $0.mode.isTree && $0.path == "sparse/" })

        let opened = try GitRepository.opened(repository)
        let index = try opened.index()
        #expect(!index.isSparse)
        #expect(try index.entries.map(Self.stageLine) == Self.gitStageLines(sandbox, repository))
        #expect(index.entries.filter { $0.path.hasPrefix("sparse/") }.allSatisfy { $0.skipWorktree })
        #expect(opened.contentOfFileInIndex(path: "sparse/two/file1.txt") == Data("sparse/two 1\n".utf8))
        #expect(try opened.status().porcelainLines == sandbox.porcelainStatus(repository))
    }

    @Test func rejectsHostilePathsAndMalformedFiles() throws {
        #expect(throws: GitError.self) { try GitIndex(data: Self.handmadeIndex(path: "../escape")) }
        #expect(throws: GitError.self) { try GitIndex(data: Self.handmadeIndex(path: ".git/config")) }
        #expect(throws: GitError.self) { try GitIndex(data: Self.handmadeIndex(path: "a//b")) }
        #expect(throws: GitError.self) { try GitIndex(data: Self.handmadeIndex(path: "")) }
        #expect(try GitIndex(data: Self.handmadeIndex(path: "fine/name.txt")).entries.map(\.path) == ["fine/name.txt"])
        #expect(throws: GitError.self) { try GitIndex(data: Data("DIRC".utf8)) }
        var unknown = Self.handmadeIndex(path: "x", extensions: [("Zzzz", Data([1, 2, 3]))])
        #expect(try GitIndex(data: unknown).entries.count == 1)
        unknown = Self.handmadeIndex(path: "x", extensions: [("zzzz", Data([1, 2, 3]))])
        #expect(throws: GitError.unsupported("index extension zzzz")) { try GitIndex(data: unknown) }
    }

    @Test func missingIndexReadsAsEmpty() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        #expect(try GitRepository.opened(repository).index().entries.isEmpty)
    }

    // MARK: Helpers

    static func stageLine(_ entry: GitIndexEntry) -> String {
        "\(entry.mode) \(entry.id.hex) \(entry.stage)\t\(entry.path)"
    }

    /// `git ls-files --stage -z`, which prints `<mode> <id> <stage>\t<path>`.
    static func gitStageLines(_ sandbox: GitSandbox, _ repository: URL) throws -> [String] {
        try sandbox.gitData(["ls-files", "--stage", "-z"], in: repository)
            .split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// A version 2 index with one entry, built byte by byte.
    static func handmadeIndex(path: String, extensions: [(String, Data)] = []) -> Data {
        var data = Data("DIRC".utf8)
        data += bigEndian(UInt32(2)) + bigEndian(UInt32(1))
        let start = data.count
        data += Data(count: 24)
        data += bigEndian(UInt32(0o100644))
        data += Data(count: 12)
        data += Data(GitObjectID.emptyBlob.bytes)
        data += bigEndian(UInt16(path.utf8.count))
        data += Data(path.utf8)
        let length = (62 + path.utf8.count + 8) & ~7
        data += Data(count: start + length - data.count)
        for (signature, content) in extensions {
            data += Data(signature.utf8) + bigEndian(UInt32(content.count)) + content
        }
        return data + Data(count: 20)
    }

    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
