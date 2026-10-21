import Foundation
import Testing
@testable import TideCore

/// A temporary folder populated with files, removed on deinit.
final class TemporaryWorkspace {
    let url: URL

    init(_ files: [String: String] = [:]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("tide-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, contents) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func read(_ path: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }
}

struct WorkspacePathTests {
    @Test func normalizesAndRefusesEscapes() throws {
        #expect(try WorkspacePath.normalize("a/./b//c/../d") == "a/b/d")
        #expect(try WorkspacePath.normalize("/") == "")
        #expect(throws: WorkspaceError.self) { try WorkspacePath.normalize("../etc/passwd") }
        #expect(throws: WorkspaceError.self) { try WorkspacePath.normalize("a/../../b") }
    }

    @Test func splitsPaths() {
        #expect(WorkspacePath.parent(of: "a/b/c.swift") == "a/b")
        #expect(WorkspacePath.name(of: "a/b/c.swift") == "c.swift")
        #expect(WorkspacePath.fileExtension(of: "a/B.Swift") == "swift")
        #expect(WorkspacePath.fileExtension(of: ".gitignore") == "")
        #expect(WorkspacePath.isDescendant("a/b", of: "a"))
        #expect(!WorkspacePath.isDescendant("ab", of: "a"))
    }

    @Test func ordersFoldersFirstThenNaturally() {
        let entries = [
            FileEntry(path: "file10.txt", isDirectory: false), FileEntry(path: "file2.txt", isDirectory: false),
            FileEntry(path: "Zeta", isDirectory: true), FileEntry(path: "alpha", isDirectory: true), FileEntry(path: "README.md", isDirectory: false),
        ]
        #expect(FileOrdering.sorted(entries).map(\.name) == ["alpha", "Zeta", "file2.txt", "file10.txt", "README.md"])
    }
}

struct LocalFileSystemTests {
    @Test func listsReadsWritesMovesAndDeletes() async throws {
        let workspace = try TemporaryWorkspace(["src/main.swift": "print(1)", "README.md": "# Hi"])
        let fs = LocalFileSystem(root: workspace.url)
        let root = FileOrdering.sorted(try await fs.list(""))
        #expect(root.map(\.path) == ["src", "README.md"])
        #expect(root[0].isDirectory)
        #expect(String(decoding: try await fs.read("src/main.swift"), as: UTF8.self) == "print(1)")

        try await fs.write("src/new/file.txt", data: Data("x".utf8))
        #expect(workspace.read("src/new/file.txt") == "x")
        try await fs.move("src/new/file.txt", to: "moved.txt")
        #expect(workspace.read("moved.txt") == "x")
        try await fs.copy("moved.txt", to: "copy.txt")
        #expect(workspace.read("copy.txt") == "x")
        try await fs.delete("moved.txt")
        #expect(await fs.exists("moved.txt") == false)
        await #expect(throws: WorkspaceError.self) { try await fs.createFile("copy.txt") }
        await #expect(throws: WorkspaceError.self) { try await fs.read("../outside") }
        await #expect(throws: WorkspaceError.self) { try await fs.delete("") }
    }
}

struct GlobTests {
    @Test func matchesVSCodeStylePatterns() {
        #expect(Glob("**/node_modules").matches("node_modules"))
        #expect(Glob("**/node_modules").matches("web/node_modules/react/index.js"))
        #expect(Glob("**/.git").matches(".git/config"))
        #expect(!Glob("**/.git").matches(".github/workflows/ci.yml"))
        #expect(Glob("*.log").matches("debug.log"))
        #expect(!Glob("*.log").matches("logs/debug.log"))
        #expect(Glob("*.log", matchAnywhere: true).matches("logs/debug.log"))
        #expect(Glob("src/**/*.{ts,tsx}").matches("src/a/b/c.tsx"))
        #expect(!Glob("src/**/*.{ts,tsx}").matches("src/a/b/c.js"))
        #expect(Glob("file?.txt").matches("file1.txt"))
        #expect(Glob("[abc].md").matches("b.md"))
        #expect(!Glob("[!abc].md").matches("b.md"))
        #expect(Glob("build/").matches("build/out/app"))
    }
}

struct TextFileCodecTests {
    @Test func detectsEncodingsAndLineEndings() throws {
        let crlf = try #require(TextFileCodec.decode(Data("a\r\nb\r\n".utf8)))
        #expect(crlf.format == TextFileFormat(encoding: .utf8, lineEnding: .crlf))
        let bom = try #require(TextFileCodec.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hé".utf8)))
        #expect(bom.text == "hé")
        #expect(bom.format.encoding == .utf8BOM)
        let utf16 = TextFileCodec.encode("hi\n", format: TextFileFormat(encoding: .utf16LE, lineEnding: .lf))
        #expect(TextFileCodec.decode(utf16)?.text == "hi\n")
        #expect(TextFileCodec.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == nil)
        #expect(TextFileCodec.decode(Data([0xE9, 0x74, 0xE9]))?.format.encoding == .windows1252)
    }

    @Test func roundTripsEveryEncoding() {
        for encoding in TextEncoding.allCases {
            let format = TextFileFormat(encoding: encoding, lineEnding: .lf)
            let text = encoding == .windows1252 ? "caf\u{E9}\n" : "caf\u{E9} \u{1F30A}\n"
            #expect(TextFileCodec.decode(TextFileCodec.encode(text, format: format))?.text == text, "\(encoding)")
        }
    }

    @Test func normalizesLineEndings() {
        #expect(LineEnding.crlf.normalize("a\nb\r\nc\rd") == "a\r\nb\r\nc\r\nd")
        #expect(LineEnding.lf.normalize("a\r\nb") == "a\nb")
        #expect(LineEnding.detect(in: "no newline") == .lf)
    }
}

struct WorkspaceSearchTests {
    @Test func findsMatchesWithOptions() throws {
        let text = "let Value = 1\nlet value2 = value + 1\n"
        let insensitive = try WorkspaceSearch.regex(for: SearchQuery(pattern: "value"))
        #expect(WorkspaceSearch.matches(in: text, regex: insensitive).count == 3)
        let caseSensitive = try WorkspaceSearch.regex(for: SearchQuery(pattern: "value", matchCase: true))
        #expect(WorkspaceSearch.matches(in: text, regex: caseSensitive).count == 2)
        let whole = try WorkspaceSearch.regex(for: SearchQuery(pattern: "value", wholeWord: true))
        let wholeMatches = WorkspaceSearch.matches(in: text, regex: whole)
        #expect(wholeMatches.map(\.line) == [0, 1])
        #expect(wholeMatches[1].range == NSRange(location: 13, length: 5))
        let regex = try WorkspaceSearch.regex(for: SearchQuery(pattern: "value\\d", isRegex: true))
        #expect(WorkspaceSearch.matches(in: text, regex: regex).count == 1)
        #expect(throws: WorkspaceSearch.SearchError.self) { try WorkspaceSearch.regex(for: SearchQuery(pattern: "(", isRegex: true)) }
    }

    @Test func literalSearchEscapesRegexCharacters() throws {
        let regex = try WorkspaceSearch.regex(for: SearchQuery(pattern: "a.b(c)"))
        #expect(WorkspaceSearch.matches(in: "a.b(c) axb(c)", regex: regex).count == 1)
    }

    @Test func replacesWithTemplates() throws {
        let regex = try WorkspaceSearch.regex(for: SearchQuery(pattern: "(\\w+)@(\\w+)", isRegex: true))
        #expect(WorkspaceSearch.replaceAll(in: "me@home you@work", regex: regex, replacement: "$2:$1", isRegex: true) == ("home:me work:you", 2))
        let literal = try WorkspaceSearch.regex(for: SearchQuery(pattern: "x"))
        #expect(WorkspaceSearch.replaceAll(in: "x x", regex: literal, replacement: "$1", isRegex: false).text == "$1 $1")
    }

    @Test func searchesFilesHonoringIncludesAndExcludes() async throws {
        let workspace = try TemporaryWorkspace([
            "src/a.swift": "let needle = 1\n",
            "src/b.ts": "const needle = 2\n",
            "node_modules/pkg/index.js": "needle\n",
            ".git/HEAD": "needle\n",
            "docs/readme.md": "no match here\n",
        ])
        var results: [FileSearchResult] = []
        for try await result in WorkspaceSearch.search(root: workspace.url, query: SearchQuery(pattern: "needle")) {
            results.append(result)
        }
        #expect(results.map(\.path).sorted() == ["src/a.swift", "src/b.ts"])

        results = []
        for try await result in WorkspaceSearch.search(root: workspace.url, query: SearchQuery(pattern: "needle", include: "*.swift")) {
            results.append(result)
        }
        #expect(results.map(\.path) == ["src/a.swift"])
        #expect(results.first?.matches.first?.preview == "let needle = 1")
    }
}
