import Foundation
import Testing
@testable import TideCore

struct GitRepositoryTests {
    @Test func opensOnlyRepositories() throws {
        let sandbox = try GitSandbox()
        #expect(GitRepository(workTree: sandbox.root) == nil)
        let repository = try sandbox.makeRepository()
        let opened = try GitRepository.opened(repository)
        #expect(opened.gitDirectory.path == repository.appendingPathComponent(".git").path)
        #expect(opened.commonDirectory == opened.gitDirectory)

        // discover walks up from a subdirectory; the initializer does not.
        let nested = repository.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(GitRepository(workTree: nested) == nil)
        #expect(GitRepository.discover(from: nested)?.workTree.path == repository.path)
        #expect(GitRepository.discover(from: sandbox.root) == nil)

        // A .git that is not a repository is not mistaken for one.
        let fake = sandbox.root.appendingPathComponent("fake", isDirectory: true)
        try FileManager.default.createDirectory(at: fake.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(GitRepository(workTree: fake) == nil)
        let gitFile = sandbox.root.appendingPathComponent("gitfile", isDirectory: true)
        try FileManager.default.createDirectory(at: gitFile, withIntermediateDirectories: true)
        try "gitdir: nowhere\n".write(to: gitFile.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(GitRepository(workTree: gitFile) == nil)
    }

    @Test func readsUnbornBranchCommitsAndDetachedHead() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        let opened = try GitRepository.opened(repository)
        #expect(try opened.head() == GitHead(referenceName: "refs/heads/main", commit: nil))
        #expect(try opened.head().isUnborn)
        #expect(try opened.status().entries.isEmpty)

        try sandbox.write("one\n", to: "a.txt", in: repository)
        try sandbox.commitAll("one", in: repository)
        let first = try Self.revParse(sandbox, repository, "HEAD")
        #expect(try opened.head() == GitHead(referenceName: "refs/heads/main", commit: first))
        #expect(try opened.currentBranch() == "main")

        try sandbox.write("two\n", to: "a.txt", in: repository)
        try sandbox.commitAll("two", in: repository)
        try sandbox.git("switch", "-q", "--detach", "HEAD~1", in: repository)
        let head = try opened.head()
        #expect(head.isDetached)
        #expect(head.branchName == nil)
        #expect(head.commit == first)
        #expect(try opened.status().head == head)
        #expect(opened.contentOfFileInHEAD(path: "a.txt") == Data("one\n".utf8))

        try sandbox.git("switch", "-q", "--orphan", "fresh", in: repository)
        #expect(try opened.head() == GitHead(referenceName: "refs/heads/fresh", commit: nil))
    }

    @Test func readsLooseAndPackedReferencesLikeForEachRef() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("one\n", to: "a.txt", in: repository)
        try sandbox.commitAll("one", in: repository)
        for branch in ["feature/login", "release", "zeta"] {
            try sandbox.git("branch", branch, in: repository)
        }
        try sandbox.git("tag", "light", in: repository)
        try sandbox.git("tag", "-a", "annotated", "-m", "note", in: repository)
        try sandbox.git("pack-refs", "--all", in: repository)
        #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/refs/heads/release").path))

        // A loose reference written after packing overrides the packed one.
        try sandbox.write("two\n", to: "a.txt", in: repository)
        try sandbox.commitAll("two", in: repository)
        try sandbox.git("branch", "-f", "release", "HEAD", in: repository)
        try sandbox.git("branch", "loose-only", in: repository)

        let opened = try GitRepository.opened(repository)
        let branches = try opened.localBranches()
        let expected = try sandbox.git("for-each-ref", "refs/heads", "--format=%(refname) %(objectname)", in: repository)
            .split(separator: "\n").map(String.init)
        #expect(branches.map { "\($0.referenceName) \($0.commit.hex)" } == expected)
        #expect(branches.map(\.name).contains("feature/login"))
        #expect(try opened.head().commit == Self.revParse(sandbox, repository, "HEAD"))

        let tags = try opened.tags()
        let expectedTags = try sandbox.git("for-each-ref", "refs/tags", "--format=%(refname) %(objectname) %(*objectname)", in: repository)
            .split(separator: "\n").map(String.init)
        #expect(tags.map { "\($0.name) \($0.target?.hex ?? "") \($0.peeledTarget?.hex ?? "")".trimmingCharacters(in: .whitespaces) }
            == expectedTags.map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(try opened.resolveReference("refs/heads/release") == Self.revParse(sandbox, repository, "release"))
        #expect(try opened.resolveReference("refs/heads/missing") == nil)
        #expect(try opened.resolveReference("refs/heads/../../config") == nil)
    }

    @Test func readsUpstreamAndCountsAheadAndBehind() throws {
        let sandbox = try GitSandbox()
        let origin = sandbox.root.appendingPathComponent("origin.git")
        try sandbox.gitData(["init", "-q", "--bare", "-b", "main", origin.path], in: sandbox.root)
        let seed = try sandbox.makeRepository("seed")
        try sandbox.write("base\n", to: "base.txt", in: seed)
        try sandbox.commitAll("base", in: seed)
        try sandbox.git("push", "-q", origin.path, "main", in: seed)

        try sandbox.git("clone", "-q", origin.path, sandbox.root.appendingPathComponent("clone").path, in: sandbox.root)
        let clone = sandbox.root.appendingPathComponent("clone")
        try sandbox.git("config", "user.name", "Tide Tests", in: clone)
        try sandbox.git("config", "user.email", "tests@tide.invalid", in: clone)
        for number in 0..<3 {
            try sandbox.write("local \(number)\n", to: "local.txt", in: clone)
            try sandbox.commitAll("local \(number)", in: clone)
        }
        for number in 0..<2 {
            try sandbox.write("remote \(number)\n", to: "remote.txt", in: seed)
            try sandbox.commitAll("remote \(number)", in: seed)
        }
        try sandbox.git("push", "-q", origin.path, "main", in: seed)
        try sandbox.git("fetch", "-q", in: clone)

        let opened = try GitRepository.opened(clone)
        let status = try opened.status()
        #expect(status.upstream == GitUpstream(remote: "origin", mergeReference: "refs/heads/main", trackingReference: "refs/remotes/origin/main"))
        #expect(status.upstream?.name == (try sandbox.git("rev-parse", "--abbrev-ref", "@{u}", in: clone).trimmingCharacters(in: .newlines)))
        let counts = try sandbox.git("rev-list", "--left-right", "--count", "HEAD...@{u}", in: clone)
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        #expect([status.ahead, status.behind] == counts.map { Optional($0) })
        #expect(status.ahead == 3 && status.behind == 2)
        #expect(try opened.localBranches().first?.upstream?.name == "origin/main")
        #expect(try opened.references(withPrefix: "refs/remotes/").contains { $0.name == "refs/remotes/origin/HEAD" && $0.symbolicTarget == "refs/remotes/origin/main" })

        // After merging, HEAD is ahead by the merge commit and its side.
        try sandbox.git("merge", "-q", "--no-edit", "@{u}", in: clone)
        let merged = try opened.status()
        let mergedCounts = try sandbox.git("rev-list", "--left-right", "--count", "HEAD...@{u}", in: clone)
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        #expect([merged.ahead, merged.behind] == mergedCounts.map { Optional($0) })

        // A branch tracking another local branch uses remote ".".
        try sandbox.git("switch", "-q", "-c", "topic", "--track", "main", in: clone)
        #expect(try opened.status().upstream == GitUpstream(remote: ".", mergeReference: "refs/heads/main", trackingReference: "refs/heads/main"))
        #expect(try opened.status().ahead == 0)
    }

    /// The walk follows each side's own commits to the end however long they
    /// run: a branch the upstream merged and then moved past, and unrelated
    /// histories, count like `git rev-list --left-right --count`.
    @Test func countsLongOneSidedHistoriesLikeRevList() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        func commit(_ message: String, at seconds: Int, merging branch: String? = nil) throws {
            let date = "\(1_700_000_000 + seconds) +0000"
            let dates = ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
            if let branch {
                try sandbox.git("merge", "-q", "--no-ff", "-m", message, branch, in: repository, environment: dates)
            } else {
                try sandbox.git("commit", "-q", "--allow-empty", "-m", message, in: repository, environment: dates)
            }
        }
        try commit("base", at: 0)
        try sandbox.git("switch", "-q", "-c", "feature", in: repository)
        try commit("feature", at: 5_000)
        try sandbox.git("switch", "-q", "main", in: repository)
        // Commits made on main while the feature was in progress, so older than it.
        for number in 1...40 { try commit("main \(number)", at: 1_000 + number) }
        try commit("merge feature", at: 6_000, merging: "feature")
        try sandbox.git("switch", "-q", "--orphan", "unrelated", in: repository)
        try commit("unrelated", at: 9_000)

        let opened = try GitRepository.opened(repository)
        for (local, upstream) in [("feature", "main"), ("unrelated", "main~1"), ("main~1", "unrelated"), ("unrelated", "main")] {
            let counts = try sandbox.git("rev-list", "--left-right", "--count", "\(local)...\(upstream)", in: repository)
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            let ours = try opened.aheadBehind(local: Self.revParse(sandbox, repository, local), upstream: Self.revParse(sandbox, repository, upstream))
            #expect([ours.ahead, ours.behind] == counts, "\(local)...\(upstream)")
        }
    }

    @Test func opensLinkedWorktrees() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("main\n", to: "file.txt", in: repository)
        try sandbox.write("ignored.tmp\n", to: ".git/info/exclude", in: repository)
        try sandbox.commitAll("main", in: repository)
        let worktree = sandbox.root.appendingPathComponent("linked")
        try sandbox.git("worktree", "add", "-q", "-b", "feature", worktree.path, in: repository)

        let opened = try GitRepository.opened(worktree)
        #expect(opened.gitDirectory.path == repository.appendingPathComponent(".git/worktrees/linked").path)
        #expect(opened.commonDirectory.path == repository.appendingPathComponent(".git").path)
        #expect(try opened.head().branchName == "feature")

        try sandbox.write("changed in worktree\n", to: "file.txt", in: worktree)
        try sandbox.write("new\n", to: "new.txt", in: worktree)
        try sandbox.write("skip me\n", to: "ignored.tmp", in: worktree)
        try sandbox.write("staged\n", to: "staged.txt", in: worktree)
        try sandbox.git("add", "staged.txt", in: worktree)
        #expect(try opened.status().porcelainLines == sandbox.porcelainStatus(worktree))
        #expect(try GitRepository.opened(repository).status().porcelainLines == sandbox.porcelainStatus(repository))
        #expect(try opened.localBranches().map(\.name) == ["feature", "main"])

        // Commits made in the worktree are visible through the shared object store.
        try sandbox.git("commit", "-q", "-m", "in worktree", in: worktree)
        #expect(try opened.head().commit == Self.revParse(sandbox, worktree, "HEAD"))
        #expect(opened.contentOfFileInHEAD(path: "staged.txt") == Data("staged\n".utf8))
    }

    @Test func opensSubmoduleCheckoutsThroughTheirGitFile() throws {
        let sandbox = try GitSandbox()
        let library = try sandbox.makeRepository("library")
        try sandbox.write("library\n", to: "lib.txt", in: library)
        try sandbox.commitAll("library", in: library)
        let app = try sandbox.makeRepository("app")
        try sandbox.write("app\n", to: "app.txt", in: app)
        try sandbox.commitAll("app", in: app)
        try sandbox.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "vendor/library", in: app)
        try sandbox.git("commit", "-q", "-m", "add submodule", in: app)

        let checkout = app.appendingPathComponent("vendor/library")
        let dotGit = try String(contentsOf: checkout.appendingPathComponent(".git"), encoding: .utf8)
        #expect(dotGit.hasPrefix("gitdir: "))
        let submodule = try GitRepository.opened(checkout)
        #expect(submodule.gitDirectory.path == app.appendingPathComponent(".git/modules/vendor/library").path)
        #expect(try submodule.head().commit == Self.revParse(sandbox, library, "HEAD"))
        #expect(try submodule.status().entries.isEmpty)

        let parent = try GitRepository.opened(app)
        #expect(try parent.status().porcelainLines == sandbox.porcelainStatus(app))
        #expect(try parent.index().entry(atPath: "vendor/library")?.mode == .gitlink)

        // Local changes, untracked files and new commits all mark the submodule modified.
        try sandbox.write("dirty\n", to: "lib.txt", in: checkout)
        #expect(try parent.status().porcelainLines == sandbox.porcelainStatus(app))
        try sandbox.git("checkout", "-q", "--", "lib.txt", in: checkout)
        try sandbox.write("untracked\n", to: "extra.txt", in: checkout)
        #expect(try parent.status().porcelainLines == sandbox.porcelainStatus(app))
        try sandbox.remove("extra.txt", in: checkout)
        try sandbox.git("config", "user.name", "Tide Tests", in: checkout)
        try sandbox.git("config", "user.email", "tests@tide.invalid", in: checkout)
        try sandbox.git("commit", "-q", "--allow-empty", "-m", "moved", in: checkout)
        #expect(try parent.status().porcelainLines == sandbox.porcelainStatus(app))
        #expect(try parent.status().porcelainLines == [" M vendor/library"])
    }

    @Test func providesHeadAndIndexContentForDiffs() throws {
        let sandbox = try GitSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.write("committed\n", to: "src/deep/file.txt", in: repository)
        try sandbox.write(Data([0, 1, 2, 255]), to: "binary.bin", in: repository)
        try sandbox.symlink("link", to: "src/deep/file.txt", in: repository)
        try sandbox.commitAll("files", in: repository)
        try sandbox.write("staged\n", to: "src/deep/file.txt", in: repository)
        try sandbox.git("add", "src/deep/file.txt", in: repository)
        try sandbox.write("work tree only\n", to: "src/deep/file.txt", in: repository)

        let opened = try GitRepository.opened(repository)
        for path in ["src/deep/file.txt", "binary.bin", "link"] {
            #expect(opened.contentOfFileInHEAD(path: path) == (try sandbox.gitData(["show", "HEAD:\(path)"], in: repository)))
            #expect(opened.contentOfFileInIndex(path: path) == (try sandbox.gitData(["show", ":\(path)"], in: repository)))
        }
        #expect(opened.contentOfFileInHEAD(path: "src/deep/file.txt") == Data("committed\n".utf8))
        #expect(opened.contentOfFileInIndex(path: "src/deep/file.txt") == Data("staged\n".utf8))
        #expect(opened.contentOfFileInHEAD(path: "link") == Data("src/deep/file.txt".utf8))
        #expect(opened.contentOfFileInHEAD(path: "src") == nil)
        #expect(opened.contentOfFileInHEAD(path: "missing.txt") == nil)
        #expect(opened.contentOfFileInHEAD(path: "src/deep/file.txt/below") == nil)
        #expect(opened.contentOfFileInIndex(path: "missing.txt") == nil)
        let headCommit = try #require(try opened.head().commit)
        let entry = try #require(try opened.treeEntry(atPath: "src/deep", inCommit: headCommit))
        #expect(entry.mode == .tree)
    }

    @Test func reportsUnsupportedRepositoryFormats() throws {
        let sandbox = try GitSandbox()
        let sha256 = try sandbox.makeRepository("sha256", arguments: ["--object-format=sha256"])
        let opened = try GitRepository.opened(sha256)
        #expect(throws: GitError.unsupported("sha256 object ids")) { try opened.head() }
        #expect(throws: GitError.unsupported("sha256 object ids")) { try opened.status() }

        // Creating a reftable repository needs git 2.45 or later; Xcode 16 ships git 2.39.
        guard let reftable = try? sandbox.makeRepository("reftable", arguments: ["--ref-format=reftable"]) else { return }
        try sandbox.write("x\n", to: "x.txt", in: reftable)
        try sandbox.commitAll("x", in: reftable)
        #expect(throws: GitError.unsupported("reftable reference storage")) { try GitRepository.opened(reftable).head() }
    }

    static func revParse(_ sandbox: GitSandbox, _ repository: URL, _ revision: String) throws -> GitObjectID {
        try #require(GitObjectID(hex: try sandbox.git("rev-parse", revision, in: repository).trimmingCharacters(in: .newlines)))
    }
}
