import Foundation
import Testing
@testable import TideCore

struct GitIgnoreTests {
    struct GlobCase: CustomTestStringConvertible, Sendable {
        var pattern: String
        var text: String
        var pathname = true
        var caseFold = false
        var matches: Bool

        var testDescription: String { "\(pattern) ~ \(text)\(pathname ? "" : " (no pathname)")\(caseFold ? " (casefold)" : "")" }
    }

    static let globCases: [GlobCase] = [
        GlobCase(pattern: "*.c", text: "main.c", matches: true),
        GlobCase(pattern: "*.c", text: "src/main.c", matches: false),
        GlobCase(pattern: "*.c", text: "src/main.c", pathname: false, matches: true),
        GlobCase(pattern: "a?c", text: "abc", matches: true),
        GlobCase(pattern: "a?c", text: "a/c", matches: false),
        GlobCase(pattern: "a/**/b", text: "a/b", matches: true),
        GlobCase(pattern: "a/**/b", text: "a/x/y/b", matches: true),
        GlobCase(pattern: "a/**/b", text: "a/xb", matches: false),
        GlobCase(pattern: "**/b", text: "b", matches: true),
        GlobCase(pattern: "**/b", text: "x/y/b", matches: true),
        GlobCase(pattern: "**/b", text: "xb", matches: false),
        GlobCase(pattern: "a/**", text: "a/x/y", matches: true),
        GlobCase(pattern: "a/**", text: "a", matches: false),
        GlobCase(pattern: "a**b", text: "axyb", matches: true),
        GlobCase(pattern: "a**b", text: "a/b", matches: false),
        GlobCase(pattern: "**", text: "any/depth/at/all", matches: true),
        GlobCase(pattern: "[a-c]x", text: "bx", matches: true),
        GlobCase(pattern: "[!a-c]x", text: "dx", matches: true),
        GlobCase(pattern: "[^a-c]x", text: "bx", matches: false),
        GlobCase(pattern: "[]]", text: "]", matches: true),
        GlobCase(pattern: "[!]]", text: "a", matches: true),
        GlobCase(pattern: "[a-]", text: "-", matches: true),
        GlobCase(pattern: "[z-a]", text: "m", matches: false),
        GlobCase(pattern: "[[:upper:]][[:digit:]]", text: "A7", matches: true),
        GlobCase(pattern: "[[:alpha:][:digit:]]", text: "_", matches: false),
        GlobCase(pattern: "[[:bogus:]]", text: "a", matches: false),
        GlobCase(pattern: "[[:abc]", text: ":", matches: true),
        GlobCase(pattern: "a[/]b", text: "a/b", matches: false),
        GlobCase(pattern: "\\*", text: "*", matches: true),
        GlobCase(pattern: "\\*", text: "x", matches: false),
        GlobCase(pattern: "a[", text: "a[", matches: false),
        GlobCase(pattern: "a\\", text: "a", matches: false),
        GlobCase(pattern: "*.TXT", text: "notes.txt", caseFold: true, matches: true),
        GlobCase(pattern: "[A-Z]x", text: "qx", caseFold: true, matches: true),
        // Like git, letters inside sets and escaped letters compare as written under case folding.
        GlobCase(pattern: "[A]", text: "a", caseFold: true, matches: false),
        GlobCase(pattern: "\\A", text: "A", caseFold: true, matches: false),
        GlobCase(pattern: "*a*b*c*d*e*f*g", text: String(repeating: "a", count: 60), matches: false),
    ]

    @Test(arguments: globCases)
    func globFollowsWildmatchRules(_ testCase: GlobCase) {
        let glob = GitGlob(Array(testCase.pattern.utf8), pathname: testCase.pathname, caseFold: testCase.caseFold)
        #expect(glob.matches(Array(testCase.text.utf8)) == testCase.matches)
    }

    /// Random patterns spread over nested `.gitignore` files and
    /// `info/exclude`, checked path by path against `git check-ignore`.
    @Test(arguments: [(UInt64(1), false), (2, false), (3, true), (4, true), (5, false), (6, true)])
    func randomRulesMatchGitCheckIgnore(seed: UInt64, ignoreCase: Bool) throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.git("config", "core.ignorecase", ignoreCase ? "true" : "false", in: repository)
        var rng = SeededGenerator(seed: seed)

        let components = ["a", "b", "A", "ab", "a.c", "x y", "B.txt", "foo", ".hidden", "c[d]"]
        var files = Set<String>()
        while files.count < 70 {
            let depth = Int.random(in: 1...3, using: &rng)
            let path = (0..<depth).map { _ in components.randomElement(using: &rng)! }.joined(separator: "/")
            files.insert(path)
        }
        // A path cannot be both a file and a directory, and the file system may ignore case.
        let directories = Set(files.flatMap { path -> [String] in
            let parts = path.split(separator: "/")
            return (1..<max(parts.count, 1)).map { parts[0..<$0].joined(separator: "/") }
        })
        let folded = Set(directories.map { $0.lowercased() })
        files = files.filter { !folded.contains($0.lowercased()) }
        for file in files {
            try sandbox.write("x", to: file, in: repository)
        }

        let fragments = ["a", "b", "A", "*", "?", "**", "[ab]", "[!a]", "[a-c]", "[A]", "[[:upper:]]", "\\*", "\\A",
                         ".c", "x y", "foo", "B", "*.txt", "c[d]", "c\\[d]", ".*"]
        func randomPattern() -> String {
            var pattern = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                (0..<Int.random(in: 1...2, using: &rng)).map { _ in fragments.randomElement(using: &rng)! }.joined()
            }.joined(separator: "/")
            if Int.random(in: 0..<4, using: &rng) == 0 { pattern = "/" + pattern }
            if Int.random(in: 0..<4, using: &rng) == 0 { pattern += "/" }
            if Int.random(in: 0..<3, using: &rng) == 0 { pattern = "!" + pattern }
            return pattern
        }
        let ignoreDirectories = [""] + directories.sorted().prefix(4).map { $0 + "/" }
        for directory in ignoreDirectories {
            let lines = (0..<Int.random(in: 3...9, using: &rng)).map { _ in randomPattern() }
            try sandbox.write(lines.joined(separator: "\n") + "\n", to: directory + ".gitignore", in: repository)
        }
        let excludes = (0..<4).map { _ in randomPattern() }.joined(separator: "\n")
        try sandbox.write(excludes + "\n", to: ".git/info/exclude", in: repository)

        let queries = files.sorted() + directories.sorted()
        let output = try sandbox.gitData(
            ["check-ignore", "--no-index", "--verbose", "--non-matching", "-z", "--stdin"],
            in: repository,
            input: Data(queries.joined(separator: "\0").utf8 + [0]),
            allowedStatus: [0, 1]
        )
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var expected: [String: Bool] = [:]
        for start in stride(from: 0, to: fields.count - 3, by: 4) {
            expected[fields[start + 3]] = !fields[start].isEmpty && !fields[start + 2].hasPrefix("!")
        }
        #expect(expected.count == queries.count)

        let rules = try GitRepository.opened(repository).ignoreRules()
        var mismatches: [String] = []
        for path in queries {
            let ours = rules.isIgnored(path, isDirectory: directories.contains(path))
            if ours != expected[path] { mismatches.append("\(path): ours \(ours), git \(expected[path].map(String.init) ?? "?")") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }

    @Test func nestedGitignoresWithNegationMatchGitStatus() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("*.log\n!keep.log\nbuild/\n/root-only.txt\ndocs/**/draft*\n", to: ".gitignore", in: repository)
        try sandbox.write("!*.log\nlocal.txt\n", to: "src/.gitignore", in: repository)
        try sandbox.write("secret*\n", to: ".git/info/exclude", in: repository)
        for path in ["a.log", "keep.log", "build/out.o", "build/keep.log", "root-only.txt", "sub/root-only.txt",
                     "src/debug.log", "src/local.txt", "src/main.swift", "src/inner/local.txt", "docs/x/draft1.md",
                     "docs/draft2.md", "docs/final.md", "secret.key", "src/secret2", "notes.txt"] {
            try sandbox.write("content\n", to: path, in: repository)
        }
        try sandbox.write("tracked even though ignored\n", to: "build/tracked.txt", in: repository)
        try sandbox.git("add", "-f", "build/tracked.txt", in: repository)

        #expect(try sandbox.swiftStatus(repository) == sandbox.porcelainStatus(repository))
        let rules = try GitRepository.opened(repository).ignoreRules()
        #expect(rules.isIgnored("a.log", isDirectory: false))
        #expect(!rules.isIgnored("keep.log", isDirectory: false))
        // Nothing inside an ignored directory can be re-included.
        #expect(rules.isIgnored("build/keep.log", isDirectory: false))
        #expect(!rules.isIgnored("src/debug.log", isDirectory: false))
        #expect(rules.isIgnored("src/inner/local.txt", isDirectory: false))
        #expect(!rules.isIgnored("sub/root-only.txt", isDirectory: false))
        #expect(rules.isIgnored("docs/x/draft1.md", isDirectory: false))
        #expect(rules.isIgnored("docs/draft2.md", isDirectory: false))
        #expect(rules.isIgnored("src/secret2", isDirectory: false))
        #expect(rules.isIgnored(".git", isDirectory: true))
        #expect(rules.isIgnored("src/.git/config", isDirectory: false))

        // Edits to .gitignore are picked up by a new status.
        try sandbox.write("*.log\n", to: ".gitignore", in: repository)
        #expect(try sandbox.swiftStatus(repository) == sandbox.porcelainStatus(repository))
    }

    @Test func linesFollowGitignoreSyntax() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        let rules = GitIgnoreRules(workTree: repository, patterns: [
            "# a comment", "\\#hash", "\\!bang", "trailing   ", "escaped\\ ", "", "   ", "dir/", "!dir/except",
        ].joined(separator: "\r\n"))
        #expect(rules.isIgnored("#hash", isDirectory: false))
        #expect(!rules.isIgnored("# a comment", isDirectory: false))
        #expect(rules.isIgnored("!bang", isDirectory: false))
        #expect(rules.isIgnored("trailing", isDirectory: false))
        #expect(!rules.isIgnored("trailing   ", isDirectory: false))
        #expect(rules.isIgnored("escaped ", isDirectory: false))
        #expect(rules.isIgnored("dir", isDirectory: true))
        #expect(!rules.isIgnored("dir", isDirectory: false))
        #expect(rules.isIgnored("dir/except", isDirectory: false))
        #expect(!rules.isIgnored("other/x", isDirectory: false))
    }
}
