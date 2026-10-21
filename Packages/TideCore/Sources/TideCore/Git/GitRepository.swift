import Foundation

/// A read-only view of a git repository and its work tree, implemented in
/// Swift without libgit2 or the git binary.
///
/// It reads HEAD and references (loose and packed), objects (loose and
/// packed, with deltas), the index (versions 2-4, split and sparse), ignore
/// rules and the work tree, which is enough for a Source Control view: the
/// branch, `git status`, and file content for diffs. It never writes to the
/// repository. All methods are synchronous and safe to call from a background
/// task; copies share an internal object cache.
///
/// Status hashes work-tree files after git's built-in end-of-line conversion
/// (the `text`, `eol` and `crlf` attributes and `core.autocrlf`).
///
/// Not supported: SHA-256 repositories, the reftable reference backend,
/// rename detection, and the other `.gitattributes` conversions (clean and
/// smudge filters, `ident`, `working-tree-encoding`), so files using those
/// are compared as they are on disk.
public struct GitRepository: Sendable {
    /// The root of the checked-out files.
    public let workTree: URL
    /// The repository's git directory. For a linked worktree or a submodule
    /// this is the directory named by the `.git` file, not `.git` itself.
    public let gitDirectory: URL
    /// The directory shared by all worktrees: objects, most references and
    /// the config. Equal to `gitDirectory` except in linked worktrees.
    public let commonDirectory: URL

    let objects: GitObjectStore
    let cache: GitRepositoryCache
    /// Set when the repository uses a format this reader cannot handle.
    private let formatProblem: GitError?
    private let referencesUnsupported: GitError?

    /// Opens the repository whose work tree is `workTree`, which must contain
    /// a `.git` directory or a `.git` file (`gitdir: <path>`, as written for
    /// linked worktrees and submodules). Returns nil when there is none.
    public init?(workTree: URL) {
        let root = workTree.standardizedFileURL
        guard let gitDirectory = Self.locateGitDirectory(in: root) else { return nil }
        self.init(workTree: root, gitDirectory: gitDirectory)
    }

    init(workTree: URL, gitDirectory: URL) {
        self.workTree = workTree
        self.gitDirectory = gitDirectory
        commonDirectory = Self.commonDirectory(for: gitDirectory)
        objects = GitObjectStore(directory: commonDirectory.appendingPathComponent("objects", isDirectory: true))
        cache = GitRepositoryCache()

        let config = GitConfig.read(contentsOf: commonDirectory.appendingPathComponent("config"))
        let version = Int(config.string("core.repositoryformatversion") ?? "0") ?? 0
        let objectFormat = config.string("extensions.objectformat")?.lowercased() ?? "sha1"
        if version > 1 {
            formatProblem = .unsupported("repository format version \(version)")
        } else if objectFormat != "sha1" {
            formatProblem = .unsupported("\(objectFormat) object ids")
        } else {
            formatProblem = nil
        }
        let referenceFormat = config.string("extensions.refstorage")?.lowercased() ?? "files"
        referencesUnsupported = referenceFormat == "files" ? nil : .unsupported("\(referenceFormat) reference storage")
    }

    /// Finds the repository containing `url`, checking `url` and then each parent directory.
    public static func discover(from url: URL) -> GitRepository? {
        // Walk path strings: for some URLs (such as ones built with
        // `resolvingSymlinksInPath()`), `deletingLastPathComponent()` turns `/`
        // into `/..` and the walk would never reach a fixed point.
        var path = url.standardizedFileURL.path
        for _ in 0..<4096 {
            if let repository = GitRepository(workTree: URL(fileURLWithPath: path, isDirectory: true)) { return repository }
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == path { return nil }
            path = parent
        }
        return nil
    }

    // MARK: Discovery

    /// The git directory for a work tree root: `.git` itself, or the target of a `.git` file.
    static func locateGitDirectory(in directory: URL) -> URL? {
        let dotGit = directory.appendingPathComponent(".git")
        var info = stat()
        guard stat(dotGit.path, &info) == 0 else { return nil }
        let candidate: URL
        if info.st_mode & S_IFMT == S_IFDIR {
            candidate = dotGit
        } else if info.st_mode & S_IFMT == S_IFREG {
            guard let line = GitFile.readLine(dotGit), line.hasPrefix("gitdir:") else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            candidate = path.hasPrefix("/")
                ? URL(fileURLWithPath: path, isDirectory: true)
                : directory.appendingPathComponent(path, isDirectory: true)
        } else {
            return nil
        }
        let standardized = candidate.standardizedFileURL
        return isGitDirectory(standardized) ? standardized : nil
    }

    /// git's test for a repository directory: a valid HEAD, plus `objects`
    /// and `refs` directories in the common directory.
    static func isGitDirectory(_ url: URL) -> Bool {
        guard let head = GitFile.readLine(url.appendingPathComponent("HEAD")) else {
            // HEAD may be a symbolic link into refs/ in very old repositories.
            guard let target = GitWorkTreeIO.symlinkTarget(atPath: url.appendingPathComponent("HEAD").path) else { return false }
            return String(decoding: target, as: UTF8.self).hasPrefix("refs/") && hasObjectsAndRefs(commonDirectory(for: url))
        }
        if head.hasPrefix("ref:") {
            guard head.dropFirst(4).trimmingCharacters(in: .whitespaces).hasPrefix("refs/") else { return false }
        } else if GitObjectID(hex: head.prefix { !$0.isWhitespace }) == nil {
            return false
        }
        return hasObjectsAndRefs(commonDirectory(for: url))
    }

    private static func hasObjectsAndRefs(_ directory: URL) -> Bool {
        var info = stat()
        for name in ["objects", "refs"] {
            guard stat(directory.appendingPathComponent(name).path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                return false
            }
        }
        return true
    }

    /// Follows `commondir`, which linked worktrees use to point at the main repository.
    static func commonDirectory(for gitDirectory: URL) -> URL {
        guard let path = GitFile.readLine(gitDirectory.appendingPathComponent("commondir")), !path.isEmpty else {
            return gitDirectory
        }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : gitDirectory.appendingPathComponent(path, isDirectory: true)
        return url.standardizedFileURL
    }

    // MARK: Configuration

    /// The repository configuration: `config` in the common directory, plus
    /// `config.worktree` when `extensions.worktreeConfig` is enabled. System and
    /// user-level configuration files are not read.
    public func config() -> GitConfig {
        var config = GitConfig.read(contentsOf: commonDirectory.appendingPathComponent("config"))
        if config.bool("extensions.worktreeconfig") == true {
            config.append(GitConfig.read(contentsOf: gitDirectory.appendingPathComponent("config.worktree")))
        }
        return config
    }

    func checkObjectFormat() throws {
        if let formatProblem { throw formatProblem }
    }

    var referenceStore: GitReferenceStore {
        get throws {
            try checkObjectFormat()
            if let referencesUnsupported { throw referencesUnsupported }
            return GitReferenceStore(gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        }
    }

    // MARK: HEAD and references

    /// Where HEAD points: a branch (possibly unborn) or a detached commit.
    public func head() throws -> GitHead {
        let store = try referenceStore
        switch try store.read("HEAD") {
        case .symbolic(let target)?:
            let resolved = try store.resolve(target)
            return GitHead(referenceName: resolved?.name ?? target, commit: resolved?.id)
        case .object(let id)?:
            return GitHead(referenceName: nil, commit: id)
        case nil:
            throw GitError.corrupt("HEAD is missing")
        }
    }

    /// The current branch name, such as `main`, or nil when HEAD is detached.
    public func currentBranch() throws -> String? {
        try head().branchName
    }

    /// Resolves a full reference name (such as `refs/heads/main` or `HEAD`) to
    /// an object id, following symbolic references. Returns nil when it does not exist.
    public func resolveReference(_ name: String) throws -> GitObjectID? {
        try referenceStore.resolve(name)?.id
    }

    /// References whose full names start with `prefix`, sorted by name.
    public func references(withPrefix prefix: String = "refs/") throws -> [GitReference] {
        try referenceStore.list(prefix: prefix)
    }

    /// Local branches (`refs/heads/*`) with their configured upstreams, sorted by name.
    public func localBranches() throws -> [GitBranch] {
        let config = config()
        return try references(withPrefix: "refs/heads/").compactMap { reference in
            guard let commit = reference.target else { return nil }
            let name = String(reference.name.dropFirst("refs/heads/".count))
            return GitBranch(name: name, referenceName: reference.name, commit: commit, upstream: config.upstream(ofBranch: name))
        }
    }

    /// Tags (`refs/tags/*`), sorted by name.
    public func tags() throws -> [GitReference] {
        try references(withPrefix: "refs/tags/")
    }

    /// The upstream configured for a local branch (`branch.<name>.remote` and `.merge`).
    public func upstream(ofBranch name: String) -> GitUpstream? {
        config().upstream(ofBranch: name)
    }

    // MARK: Objects

    /// Reads any object by id.
    public func readObject(_ id: GitObjectID) throws -> GitObject {
        try checkObjectFormat()
        return try objects.read(id)
    }

    /// Reads and parses a commit.
    public func commit(_ id: GitObjectID) throws -> GitCommit {
        let object = try readObject(id)
        guard object.type == .commit else { throw GitError.corrupt("\(id) is a \(object.type.rawValue), not a commit") }
        return try GitCommit(id: id, data: object.data)
    }

    /// Reads and parses a tree.
    public func tree(_ id: GitObjectID) throws -> GitTree {
        let object = try readObject(id)
        guard object.type == .tree else { throw GitError.corrupt("\(id) is a \(object.type.rawValue), not a tree") }
        return try GitTree(id: id, data: object.data)
    }

    /// Reads a blob's content.
    public func blob(_ id: GitObjectID) throws -> Data {
        let object = try readObject(id)
        guard object.type == .blob else { throw GitError.corrupt("\(id) is a \(object.type.rawValue), not a blob") }
        return object.data
    }

    /// Reads and parses an annotated tag.
    public func tag(_ id: GitObjectID) throws -> GitTag {
        let object = try readObject(id)
        guard object.type == .tag else { throw GitError.corrupt("\(id) is a \(object.type.rawValue), not a tag") }
        return try GitTag(id: id, data: object.data)
    }

    /// Follows annotated tags until reaching a commit.
    func peelToCommit(_ id: GitObjectID) throws -> GitCommit {
        var current = id
        for _ in 0..<16 {
            let object = try readObject(current)
            switch object.type {
            case .commit: return try GitCommit(id: current, data: object.data)
            case .tag: current = try GitTag(id: current, data: object.data).target
            default: throw GitError.corrupt("\(id) does not point at a commit")
            }
        }
        throw GitError.corrupt("tag chain from \(id) is too long")
    }

    /// The entry at `path` (relative to the root, `/`-separated) in the tree of `commit`.
    public func treeEntry(atPath path: String, inCommit commit: GitObjectID) throws -> GitTreeEntry? {
        var treeID = try peelToCommit(commit).tree
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        for (position, component) in components.enumerated() {
            let wanted = Array(component.utf8)
            var found: (GitFileMode, GitObjectID)?
            let object = try readObject(treeID)
            guard object.type == .tree else { throw GitError.corrupt("\(treeID) is not a tree") }
            try GitTree.forEachEntry(in: object.data) { name, mode, id in
                if found == nil, name.elementsEqual(wanted) { found = (mode, id) }
            }
            guard let match = found else { return nil }
            let (mode, id) = match
            if position == components.count - 1 {
                return GitTreeEntry(name: String(component), mode: mode, id: id)
            }
            guard mode.isTree else { return nil }
            treeID = id
        }
        return nil
    }

    /// Every file in the tree `treeID`, keyed by path. Cached for the most recent tree.
    func flattenedTree(_ treeID: GitObjectID) throws -> [String: GitTreeItem] {
        try cache.flattenedTree(treeID) {
            var result: [String: GitTreeItem] = [:]
            var pending: [(prefix: String, id: GitObjectID)] = [("", treeID)]
            while let next = pending.popLast() {
                let (prefix, id) = next
                let object = try readObject(id)
                guard object.type == .tree else { throw GitError.corrupt("\(id) is not a tree") }
                try GitTree.forEachEntry(in: object.data) { name, mode, entryID in
                    let path = prefix + String(decoding: name, as: UTF8.self)
                    if mode.isTree {
                        pending.append((path + "/", entryID))
                    } else {
                        result[path] = GitTreeItem(mode: mode, id: entryID)
                    }
                }
            }
            return result
        }
    }

    // MARK: Index

    /// Reads the index, merging a split index with its shared index and
    /// expanding the directory entries of a sparse index into files.
    public func index() throws -> GitIndex {
        try checkObjectFormat()
        var index = try GitIndex.read(contentsOf: gitDirectory.appendingPathComponent("index"))
        if let shared = index.sharedIndexID {
            let url = gitDirectory.appendingPathComponent("sharedindex.\(shared.hex)")
            guard let data = try GitFile.readIfExists(url) else { throw GitError.notFound("shared index \(shared)") }
            index = try index.merged(withShared: GitIndex(data: data))
        }
        if index.isSparse {
            index = try expandingSparseDirectories(index)
        }
        return index
    }

    private func expandingSparseDirectories(_ index: GitIndex) throws -> GitIndex {
        var expanded: [GitIndexEntry] = []
        expanded.reserveCapacity(index.entries.count)
        for entry in index.entries {
            guard entry.mode.isTree else {
                expanded.append(entry)
                continue
            }
            let prefix = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
            for (path, item) in try flattenedTree(entry.id) {
                var file = entry
                file.path = prefix + path
                file.mode = item.mode
                file.id = item.id
                file.size = 0
                file.skipWorktree = true
                expanded.append(file)
            }
        }
        expanded.sort { lhs, rhs in lhs.path == rhs.path ? lhs.stage < rhs.stage : lhs.path.precedesInByteOrder(rhs.path) }
        var result = index
        result.entries = expanded
        result.isSparse = false
        return result
    }

    // MARK: Content for diffs

    /// The content of `path` as committed in HEAD, or nil when HEAD has no such
    /// file (or no commits). For a symbolic link this is the link target.
    public func contentOfFileInHEAD(path: String) -> Data? {
        guard let commit = try? head().commit,
              let entry = try? treeEntry(atPath: path, inCommit: commit),
              !entry.mode.isTree, !entry.mode.isGitlink else { return nil }
        return try? blob(entry.id)
    }

    /// The staged content of `path`, or nil when the index has no stage-0 entry for it.
    public func contentOfFileInIndex(path: String) -> Data? {
        guard let entry = try? index().entry(atPath: path), !entry.mode.isGitlink else { return nil }
        return try? blob(entry.id)
    }

    // MARK: Ignore rules

    /// The ignore rules of this work tree: `.gitignore` files, `info/exclude`
    /// and `core.excludesFile`. Create new rules to pick up edits.
    public func ignoreRules() -> GitIgnoreRules {
        ignoreRules(config: config(), index: nil)
    }

    func ignoreRules(config: GitConfig, index: GitIndex?) -> GitIgnoreRules {
        let excludesFile = configuredFile(config, "core.excludesfile")
        // A .gitignore missing from a sparse checkout is read from the index, as git does.
        var fallback: (@Sendable (String) -> Data?)?
        if let index {
            let skipped = Dictionary(
                index.entries.filter { $0.skipWorktree && $0.stage == 0 && $0.path.hasSuffix(".gitignore") }.map { ($0.path, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            if !skipped.isEmpty {
                let store = objects
                fallback = { path in skipped[path].flatMap { try? store.read($0).data } }
            }
        }
        return GitIgnoreRules(
            workTree: workTree,
            infoExclude: commonDirectory.appendingPathComponent("info/exclude"),
            excludesFile: excludesFile,
            ignoreCase: config.bool("core.ignorecase") ?? false,
            fallbackContent: fallback
        )
    }

    /// The attributes `git status` uses: `.gitattributes` files (from the
    /// index when one is missing from the work tree), `info/attributes` and
    /// `core.attributesFile`.
    func attributes(config: GitConfig, index: GitIndex) -> GitAttributes {
        // Stage 0, or "ours" in the middle of a merge, like git's read_blob_data_from_index.
        let indexed = Dictionary(
            index.entries
                .filter { ($0.stage == 0 || $0.stage == 2) && ($0.path == ".gitattributes" || $0.path.hasSuffix("/.gitattributes")) }
                .map { ($0.path, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var fallback: (@Sendable (String) -> Data?)?
        if !indexed.isEmpty {
            let store = objects
            fallback = { path in indexed[path].flatMap { try? store.read($0).data } }
        }
        return GitAttributes(
            workTree: workTree,
            infoAttributes: commonDirectory.appendingPathComponent("info/attributes"),
            attributesFile: configuredFile(config, "core.attributesfile"),
            ignoreCase: config.bool("core.ignorecase") ?? false,
            fallbackContent: fallback
        )
    }

    /// A file named by a path setting such as `core.excludesFile`: `~/` is the
    /// home directory, and a relative path starts at the work tree.
    private func configuredFile(_ config: GitConfig, _ key: String) -> URL? {
        guard let path = config.string(key), !path.isEmpty else { return nil }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return workTree.appendingPathComponent(path)
    }
}

/// A file in a flattened tree.
struct GitTreeItem: Equatable, Sendable {
    var mode: GitFileMode
    var id: GitObjectID
}

/// Caches shared by copies of a repository value.
final class GitRepositoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tree: (id: GitObjectID, files: [String: GitTreeItem])?
    private var hashes: [String: (stat: GitFileStat, conversion: GitTextConversion, id: GitObjectID)] = [:]
    private static let hashLimit = 50_000

    /// The flattened HEAD tree changes rarely, so the last one is kept.
    func flattenedTree(_ id: GitObjectID, build: () throws -> [String: GitTreeItem]) throws -> [String: GitTreeItem] {
        lock.lock()
        if let tree, tree.id == id {
            lock.unlock()
            return tree.files
        }
        lock.unlock()
        let files = try build()
        lock.lock()
        tree = (id, files)
        lock.unlock()
        return files
    }

    /// A content hash computed earlier for a file whose metadata, and line-ending conversion, have not changed since.
    func hash(forPath path: String, stat: GitFileStat, conversion: GitTextConversion) -> GitObjectID? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = hashes[path], entry.stat == stat, entry.conversion == conversion else { return nil }
        return entry.id
    }

    /// Remembers a content hash. Files changed within the last two seconds are
    /// not cached, so a second write in the same timestamp tick cannot be missed.
    func storeHash(_ id: GitObjectID, forPath path: String, stat: GitFileStat, conversion: GitTextConversion) {
        let now = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        guard stat.modificationTime.seconds &+ 2 < now, stat.statusChangeTime.seconds &+ 2 < now else { return }
        lock.lock()
        defer { lock.unlock() }
        if hashes.count >= Self.hashLimit { hashes.removeAll(keepingCapacity: true) }
        hashes[path] = (stat, conversion, id)
    }
}
