import Compression
import Foundation
import Testing
@testable import TideCore

struct GitObjectTests {
    @Test func objectIDsRoundTripAndOrderByBytes() throws {
        let hex = "0123456789abcdef0123456789abcdef01234567"
        let id = try #require(GitObjectID(hex: hex))
        #expect(id.hex == hex)
        #expect(GitObjectID(hex: hex.uppercased()) == id)
        #expect(id.abbreviated() == "0123456")
        #expect(GitObjectID(bytes: id.bytes) == id)
        #expect(GitObjectID(hex: "0123") == nil)
        #expect(GitObjectID(hex: String(repeating: "g", count: 40)) == nil)
        let low = try #require(GitObjectID(hex: "00" + String(repeating: "f", count: 38)))
        let high = try #require(GitObjectID(hex: "01" + String(repeating: "0", count: 38)))
        #expect(low < high)
        #expect(GitObjectID.hash(.blob, Data()) == .emptyBlob)
        #expect(GitObjectID.hash(.tree, Data()) == .emptyTree)
    }

    @Test func blobHashesMatchGitHashObject() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        var rng = SeededGenerator(seed: 7)
        for length in [0, 1, 55, 4096, 70_000] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let expected = try sandbox.gitData(["hash-object", "--stdin"], in: repository, input: data)
            #expect(GitObjectID.hash(.blob, data).hex == String(decoding: expected, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
    }

    /// Apple's `COMPRESSION_ZLIB` is raw DEFLATE: real git objects only decode
    /// once the two-byte zlib header is skipped, which `Inflate` does.
    @Test func looseObjectsAreZlibStreamsThatAppleDecodesAsRawDeflate() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        let text = String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 50)
        try sandbox.write(text, to: "fox.txt", in: repository)
        let hex = try sandbox.git("hash-object", "-w", "fox.txt", in: repository).trimmingCharacters(in: .newlines)
        let objectURL = repository.appendingPathComponent(".git/objects/\(hex.prefix(2))/\(hex.dropFirst(2))")
        let compressed = try Data(contentsOf: objectURL)
        #expect(compressed[0] & 0x0F == 8, "zlib header names DEFLATE")

        let header = Data("blob \(text.utf8.count)\0".utf8)
        let inflated = try compressed.withUnsafeBytes { try Inflate.zlib($0) }
        #expect(inflated == header + Data(text.utf8))

        // Feeding the whole zlib stream (header included) to Apple's decoder fails or garbles it.
        let capacity = inflated.count + 64
        var output = Data(count: capacity)
        let decoded = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self), compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        #expect(decoded == 0 || output.prefix(decoded) != inflated)

        // A declared size that disagrees with the stream is rejected.
        #expect(throws: GitError.self) {
            try compressed.withUnsafeBytes { try Inflate.zlib($0, expectedSize: inflated.count + 1) }
        }
        #expect(throws: GitError.self) {
            try compressed.prefix(compressed.count / 2).withUnsafeBytes { try Inflate.zlib($0) }
        }
    }

    @Test func parsesCommitsTreesAndTagsLikeGitCatFile() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("hello\n", to: "a.txt", in: repository)
        try sandbox.write("nested\n", to: "dir/b.txt", in: repository)
        try sandbox.symlink("link", to: "a.txt", in: repository)
        try sandbox.git("add", "-A", in: repository)
        try sandbox.git("update-index", "--chmod=+x", "dir/b.txt", in: repository)
        let dates = ["GIT_AUTHOR_DATE": "1700000000 +0130", "GIT_COMMITTER_DATE": "1700000100 -0700"]
        try sandbox.git("commit", "-q", "-m", "First line\n\nBody text.", in: repository, environment: dates)
        try sandbox.git("commit", "-q", "--allow-empty", "-m", "Second", in: repository, environment: dates)
        try sandbox.git("tag", "-a", "v1.0", "-m", "Release one", in: repository, environment: dates)

        let opened = try GitRepository.opened(repository)
        let headID = try #require(try opened.head().commit)
        #expect(try headID.hex == sandbox.git("rev-parse", "HEAD", in: repository).trimmingCharacters(in: .newlines))

        let second = try opened.commit(headID)
        #expect(second.summary == "Second")
        #expect(second.parents.count == 1)
        let first = try opened.commit(second.parents[0])
        #expect(first.parents.isEmpty)
        #expect(first.message == "First line\n\nBody text.\n")
        #expect(first.summary == "First line")
        #expect(first.author == GitSignature(name: "Tide Tests", email: "tests@tide.invalid", time: 1_700_000_000, timeZoneOffset: 90))
        #expect(first.committer?.time == 1_700_000_100)
        #expect(first.committer?.timeZoneOffset == -420)
        #expect(try first.tree.hex == sandbox.git("rev-parse", "HEAD~1^{tree}", in: repository).trimmingCharacters(in: .newlines))

        let tree = try opened.tree(first.tree)
        let listing = try sandbox.git("ls-tree", "HEAD", in: repository)
            .split(separator: "\n")
            .map(String.init)
        let ours = tree.entries.map { entry in
            "\(entry.mode) \(entry.mode.isTree ? "tree" : entry.mode.isGitlink ? "commit" : "blob") \(entry.id.hex)\t\(entry.name)"
        }
        #expect(ours == listing)
        #expect(tree.entry(named: "link")?.mode == .symlink)
        #expect(try opened.tree(try #require(tree.entry(named: "dir")).id).entries.first?.mode == .executable)

        let tagID = try #require(try opened.resolveReference("refs/tags/v1.0"))
        let tag = try opened.tag(tagID)
        #expect(tag.name == "v1.0")
        #expect(tag.target == headID)
        #expect(tag.targetType == .commit)
        #expect(tag.message == "Release one\n")
        #expect(tag.tagger?.time == 1_700_000_100)
        #expect(throws: GitError.self) { try opened.commit(tagID) }
    }

    /// Every object in a repository whose history was packed with deep delta
    /// chains reads back exactly as `git cat-file --batch` prints it.
    @Test(arguments: [true, false])
    func packedObjectsMatchGit(offsetDeltas: Bool) throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        var lines = (0..<200).map { "line \($0) of a file that changes a little each commit" }
        for version in 0..<25 {
            lines[version * 7 % lines.count] = "edited in version \(version)"
            try sandbox.write(lines.joined(separator: "\n") + "\n", to: "notes.txt", in: repository)
            try sandbox.write("version \(version)\n" + lines.prefix(40).joined(separator: "\n"), to: "src/small.txt", in: repository)
            try sandbox.commitAll("version \(version)", in: repository)
        }
        try sandbox.git("tag", "-a", "v1", "-m", "tagged", in: repository)
        if offsetDeltas {
            try sandbox.git("gc", "-q", "--aggressive", "--prune=now", in: repository)
        } else {
            try sandbox.git("-c", "repack.usedeltabaseoffset=false", "repack", "-adfq", "--depth=50", "--window=50", in: repository)
            try sandbox.git("prune-packed", in: repository)
        }
        let opened = try GitRepository.opened(repository)
        let expected = try Self.allObjects(sandbox, repository)
        #expect(expected.count > 100)
        var deltaKinds = Set<String>()
        let pack = try Self.onlyPack(in: repository)
        for (id, object) in expected {
            #expect(try opened.readObject(id) == object, "object \(id)")
            let offset = try #require(pack.offset(of: id))
            switch try pack.entryHeader(at: offset).entry {
            case .object: deltaKinds.insert("whole")
            case .offsetDelta: deltaKinds.insert("ofs")
            case .referenceDelta: deltaKinds.insert("ref")
            }
        }
        #expect(deltaKinds.contains(offsetDeltas ? "ofs" : "ref"))
        #expect(!deltaKinds.contains(offsetDeltas ? "ref" : "ofs"))
        // Loose objects were packed and removed, so everything came from the pack.
        let loose = try FileManager.default.contentsOfDirectory(atPath: repository.appendingPathComponent(".git/objects").path)
            .filter { $0.count == 2 }
        #expect(loose.isEmpty)
    }

    /// Version 1 pack indexes and the 64-bit offset table of version 2 both resolve.
    @Test(arguments: ["1", "2,0x40"])
    func readsAlternativePackIndexFormats(indexVersion: String) throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        for version in 0..<8 {
            try sandbox.write(String(repeating: "content \(version)\n", count: 30 + version), to: "file.txt", in: repository)
            try sandbox.commitAll("v\(version)", in: repository)
        }
        try sandbox.git("repack", "-adq", in: repository)
        try sandbox.git("prune-packed", in: repository)
        let packDirectory = repository.appendingPathComponent(".git/objects/pack")
        let packName = try #require(try FileManager.default.contentsOfDirectory(atPath: packDirectory.path).first { $0.hasSuffix(".pack") })
        let indexURL = packDirectory.appendingPathComponent(packName).deletingPathExtension().appendingPathExtension("idx")
        try FileManager.default.removeItem(at: indexURL)
        try sandbox.git("index-pack", "--index-version=\(indexVersion)", "-o", indexURL.path, packDirectory.appendingPathComponent(packName).path, in: repository)
        let indexBytes = try Data(contentsOf: indexURL)
        #expect((indexBytes.prefix(4) == Data([0xFF, 0x74, 0x4F, 0x63])) == (indexVersion != "1"))

        let opened = try GitRepository.opened(repository)
        for (id, object) in try Self.allObjects(sandbox, repository) {
            #expect(try opened.readObject(id) == object, "object \(id)")
        }
    }

    @Test func readsObjectsThroughAlternates() throws {
        let sandbox = try GitSandbox()
        let source = try sandbox.makeRepository("source")
        try sandbox.write("shared\n", to: "shared.txt", in: source)
        try sandbox.commitAll("shared", in: source)
        try sandbox.git("clone", "-q", "--shared", source.path, sandbox.root.appendingPathComponent("clone").path, in: sandbox.root)
        let clone = sandbox.root.appendingPathComponent("clone")
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git/objects/info/alternates").path))
        let opened = try GitRepository.opened(clone)
        let head = try #require(try opened.head().commit)
        #expect(try opened.commit(head).summary == "shared")
        #expect(opened.contentOfFileInHEAD(path: "shared.txt") == Data("shared\n".utf8))
    }

    /// Objects that `git gc` moves into a new pack after the reader listed the
    /// pack directory are still found.
    @Test func findsObjectsMovedIntoNewPacks() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("one\n", to: "a.txt", in: repository)
        try sandbox.commitAll("one", in: repository)
        try sandbox.git("gc", "-q", in: repository)
        let opened = try GitRepository.opened(repository)
        #expect(opened.contentOfFileInHEAD(path: "a.txt") == Data("one\n".utf8))
        try sandbox.write("two\n", to: "b.txt", in: repository)
        try sandbox.commitAll("two", in: repository)
        try sandbox.git("gc", "-q", "--prune=now", in: repository)
        #expect(opened.contentOfFileInHEAD(path: "b.txt") == Data("two\n".utf8))
        #expect(throws: GitError.self) { try opened.readObject(try #require(GitObjectID(hex: String(repeating: "1", count: 40)))) }
    }

    @Test func deltasApplyCopiesAndInsertsAndRejectCorruption() throws {
        let base = Data("Hello, world! This is the base text.".utf8)
        // Base size 36, result size 18: copy "Hello, " (offset 0, size 7), insert "git", copy "! This" (offset 12, size 6).
        var delta = Data([36, 16])
        delta += Data([0x90, 7])
        delta += Data([3]) + Data("git".utf8)
        delta += Data([0x91, 12, 6])
        delta[1] = 16
        #expect(try GitDelta.apply(delta, to: base) == Data("Hello, git! This".utf8))

        var outOfRange = Data([36, 10, 0x91, 30, 10])
        #expect(throws: GitError.self) { try GitDelta.apply(outOfRange, to: base) }
        outOfRange = Data([35, 1, 1, 0x41])
        #expect(throws: GitError.self) { try GitDelta.apply(outOfRange, to: base) }
        let reserved = Data([36, 1, 0])
        #expect(throws: GitError.self) { try GitDelta.apply(reserved, to: base) }
        let short = Data([36, 5, 0x90, 2])
        #expect(throws: GitError.self) { try GitDelta.apply(short, to: base) }
    }

    // MARK: Helpers

    /// Every object in the repository, from `git cat-file --batch-all-objects --batch`.
    static func allObjects(_ sandbox: GitSandbox, _ repository: URL) throws -> [GitObjectID: GitObject] {
        let data = try sandbox.gitData(["cat-file", "--batch-all-objects", "--batch"], in: repository)
        var objects: [GitObjectID: GitObject] = [:]
        var position = data.startIndex
        while position < data.endIndex {
            let newline = try #require(data[position...].firstIndex(of: 0x0A))
            let header = String(decoding: data[position..<newline], as: UTF8.self).split(separator: " ")
            let id = try #require(GitObjectID(hex: header[0]))
            let type = try #require(GitObjectType(rawValue: String(header[1])))
            let size = try #require(Int(header[2]))
            let content = data[(newline + 1)..<(newline + 1 + size)]
            objects[id] = GitObject(type: type, data: Data(content))
            position = newline + 1 + size + 1
        }
        return objects
    }

    static func onlyPack(in repository: URL) throws -> GitPack {
        let directory = repository.appendingPathComponent(".git/objects/pack")
        let indexes = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".idx") }
        #expect(indexes.count == 1)
        return try GitPack(indexURL: directory.appendingPathComponent(try #require(indexes.first)))
    }
}
