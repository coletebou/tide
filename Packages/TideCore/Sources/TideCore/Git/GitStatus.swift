import Foundation

/// One side of a status entry: the letters `git status --porcelain` prints.
public enum GitFileStatus: Character, Sendable {
    case unmodified = " "
    case modified = "M"
    /// The kind of file changed, such as a regular file becoming a symbolic link.
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    /// Part of a merge conflict.
    case unmerged = "U"
    case untracked = "?"
}

/// The kinds of merge conflict, named by git's two-letter codes.
public enum GitConflict: String, Sendable {
    case bothDeleted = "DD"
    case addedByUs = "AU"
    case deletedByThem = "UD"
    case addedByThem = "UA"
    case deletedByUs = "DU"
    case bothAdded = "AA"
    case bothModified = "UU"

    /// Maps the set of conflict stages present in the index (bit 0 = base,
    /// bit 1 = ours, bit 2 = theirs) to its kind, as git does.
    init?(stageMask: Int) {
        switch stageMask {
        case 1: self = .bothDeleted
        case 2: self = .addedByUs
        case 3: self = .deletedByThem
        case 4: self = .addedByThem
        case 5: self = .deletedByUs
        case 6: self = .bothAdded
        case 7: self = .bothModified
        default: return nil
        }
    }
}

/// One path in `git status`.
public struct GitStatusEntry: Equatable, Sendable {
    /// Path relative to the work tree root. An untracked nested repository is
    /// reported as its directory with a trailing `/`, as git does.
    public var path: String
    /// HEAD compared with the index (the staged change).
    public var index: GitFileStatus
    /// The index compared with the work tree (the unstaged change).
    public var workTree: GitFileStatus
    /// Set for unmerged paths; `index` and `workTree` then hold the letters of its code.
    public var conflict: GitConflict?

    public init(path: String, index: GitFileStatus, workTree: GitFileStatus, conflict: GitConflict? = nil) {
        self.path = path
        self.index = index
        self.workTree = workTree
        self.conflict = conflict
    }

    /// The two-letter code of `git status --porcelain=v1`, such as `M `, ` D`, `UU` or `??`.
    public var porcelainCode: String { String([index.rawValue, workTree.rawValue]) }

    public var isUntracked: Bool { index == .untracked }
}

/// The result of `GitRepository.status()`.
public struct GitStatus: Equatable, Sendable {
    public var head: GitHead
    /// The upstream of the current branch, when one is configured.
    public var upstream: GitUpstream?
    /// Commits on HEAD that the upstream does not have, when both exist.
    public var ahead: Int?
    /// Commits on the upstream that HEAD does not have, when both exist.
    public var behind: Int?
    /// Changed tracked paths sorted by path, then untracked paths sorted by
    /// path: the order of `git status --porcelain=v1 -uall`.
    public var entries: [GitStatusEntry]

    public var isClean: Bool { entries.isEmpty }
}

/// What `status` computes.
public struct GitStatusOptions: Sendable {
    /// List untracked files individually, like `git status -uall`.
    public var includeUntracked: Bool
    /// Count commits ahead of and behind the upstream.
    public var includeAheadBehind: Bool
    /// Compare submodule checkouts with their recorded commits and report
    /// submodules with local changes as modified, as git does by default.
    public var inspectSubmodules: Bool

    public init(includeUntracked: Bool = true, includeAheadBehind: Bool = true, inspectSubmodules: Bool = true) {
        self.includeUntracked = includeUntracked
        self.includeAheadBehind = includeAheadBehind
        self.inspectSubmodules = inspectSubmodules
    }
}

extension GitRepository {
    /// Computes the equivalent of `git status --porcelain=v1 -uall --no-renames`:
    /// HEAD against the index, the index against the work tree, and untracked
    /// files that ignore rules do not exclude. Unchanged files are recognized by
    /// the size and timestamps recorded in the index and are only hashed when
    /// those differ. The index is never rewritten.
    public func status(_ options: GitStatusOptions = GitStatusOptions()) throws -> GitStatus {
        let head = try self.head()
        let config = self.config()
        let index = try self.index()
        var headFiles: [String: GitTreeItem] = [:]
        if let commit = head.commit {
            headFiles = try flattenedTree(try peelToCommit(commit).tree)
        }
        var collector = GitStatusCollector(repository: self, config: config, index: index, headFiles: headFiles, options: options)
        let entries = try collector.collect()

        var status = GitStatus(head: head, upstream: nil, ahead: nil, behind: nil, entries: entries)
        if let branch = head.branchName, let upstream = config.upstream(ofBranch: branch) {
            status.upstream = upstream
            if options.includeAheadBehind, let local = head.commit, let tracking = upstream.trackingReference,
               let remote = try referenceStore.resolve(tracking)?.id {
                let counts = try aheadBehind(local: local, upstream: remote)
                status.ahead = counts.ahead
                status.behind = counts.behind
            }
        }
        return status
    }
}

/// Builds the status entries for one repository.
struct GitStatusCollector {
    let repository: GitRepository
    let index: GitIndex
    let headFiles: [String: GitTreeItem]
    let options: GitStatusOptions
    private let rootPath: String
    private let ignoreCase: Bool
    private let trustExecutableBit: Bool
    private let hasSymlinks: Bool
    private let trustChangeTime: Bool
    private let checkAllStat: Bool
    private let precomposeUnicode: Bool
    /// `core.autocrlf` is `true` or `input`.
    private let autoCRLF: Bool
    private let rules: GitIgnoreRules
    private let attributes: GitAttributes
    /// Directories known to be (or not be) symbolic links, for the leading-path check.
    private var symlinkDirectories: [String: Bool] = [:]

    init(repository: GitRepository, config: GitConfig, index: GitIndex, headFiles: [String: GitTreeItem], options: GitStatusOptions) {
        self.repository = repository
        self.index = index
        self.headFiles = headFiles
        self.options = options
        rootPath = repository.workTree.path
        ignoreCase = config.bool("core.ignorecase") ?? false
        trustExecutableBit = config.bool("core.filemode") ?? true
        hasSymlinks = config.bool("core.symlinks") ?? true
        trustChangeTime = config.bool("core.trustctime") ?? true
        checkAllStat = config.string("core.checkstat")?.lowercased() != "minimal"
        precomposeUnicode = config.bool("core.precomposeunicode") ?? false
        autoCRLF = config.string("core.autocrlf")?.lowercased() == "input" || config.bool("core.autocrlf") == true
        rules = repository.ignoreRules(config: config, index: index)
        attributes = repository.attributes(config: config, index: index)
    }

    mutating func collect() throws -> [GitStatusEntry] {
        var stageZero: [String: GitIndexEntry] = [:]
        var stageMasks: [String: Int] = [:]
        for entry in index.entries {
            if entry.stage == 0 {
                stageZero[entry.path] = entry
            } else {
                stageMasks[entry.path, default: 0] |= 1 << (entry.stage - 1)
            }
        }

        var changes: [String: (index: GitFileStatus, workTree: GitFileStatus)] = [:]

        // HEAD against the index. Intent-to-add entries count as absent from the index.
        for (path, entry) in stageZero where !entry.intentToAdd {
            guard let committed = headFiles[path] else {
                changes[path, default: (.unmodified, .unmodified)].index = .added
                continue
            }
            if committed.mode.typeBits != entry.mode.typeBits {
                changes[path, default: (.unmodified, .unmodified)].index = .typeChanged
            } else if committed.id != entry.id || committed.mode != entry.mode {
                changes[path, default: (.unmodified, .unmodified)].index = .modified
            }
        }
        for path in headFiles.keys where stageMasks[path] == nil {
            if let entry = stageZero[path], !entry.intentToAdd { continue }
            changes[path, default: (.unmodified, .unmodified)].index = .deleted
        }

        // The index against the work tree.
        for (path, entry) in stageZero {
            let change = try workTreeStatus(of: entry)
            if change != .unmodified {
                changes[path, default: (.unmodified, .unmodified)].workTree = change
            }
        }

        var entries: [GitStatusEntry] = []
        for (path, mask) in stageMasks {
            if let conflict = GitConflict(stageMask: mask) {
                let letters = Array(conflict.rawValue)
                entries.append(GitStatusEntry(
                    path: path,
                    index: GitFileStatus(rawValue: letters[0]) ?? .unmerged,
                    workTree: GitFileStatus(rawValue: letters[1]) ?? .unmerged,
                    conflict: conflict
                ))
            }
        }
        for (path, change) in changes where stageMasks[path] == nil {
            if change.index != .unmodified || change.workTree != .unmodified {
                entries.append(GitStatusEntry(path: path, index: change.index, workTree: change.workTree))
            }
        }
        entries.sort { $0.path.precedesInByteOrder($1.path) }

        if options.includeUntracked {
            entries.append(contentsOf: untrackedPaths().map {
                GitStatusEntry(path: $0, index: .untracked, workTree: .untracked)
            })
        }
        return entries
    }

    // MARK: Index against work tree

    private mutating func workTreeStatus(of entry: GitIndexEntry) throws -> GitFileStatus {
        if entry.skipWorktree || entry.assumeValid { return .unmodified }
        let path = rootPath + "/" + entry.path
        guard let stat = GitFileStat.read(path), !leadingPathHasSymlink(entry.path) else { return .deleted }

        // A file replaced by a directory is gone, unless the directory is a
        // repository, which git sees as the file turning into a submodule.
        var replacedByRepository = false
        if stat.isDirectory, !entry.mode.isGitlink {
            guard GitRepository.locateGitDirectory(in: URL(fileURLWithPath: path, isDirectory: true)) != nil else { return .deleted }
            replacedByRepository = true
        }
        if entry.intentToAdd { return .added }
        if replacedByRepository { return .typeChanged }
        if entry.mode.isGitlink { return try submoduleStatus(of: entry, at: path, stat: stat) }

        if entry.mode.isRegularFile {
            if stat.isSymlink { return .typeChanged }
            // A FIFO or socket where a file was: changed, and not something to read.
            guard stat.isRegularFile else { return .modified }
            if trustExecutableBit, (entry.mode.rawValue ^ UInt32(stat.mode)) & 0o100 != 0 { return .modified }
        } else if entry.mode.isSymlink, !stat.isSymlink {
            if hasSymlinks || !stat.isRegularFile { return .typeChanged }
        }

        if statMatches(entry, stat), !isRacy(entry), !(entry.size == 0 && entry.id != .emptyBlob) {
            return .unmodified
        }
        // A size change proves a regular file changed; git records size 0 only
        // for entries whose size it has not looked at yet.
        if stat.isRegularFile, entry.size != 0, entry.size != UInt32(truncatingIfNeeded: stat.size) {
            return .modified
        }
        return contentID(of: entry, absolutePath: path, stat: stat) == entry.id ? .unmodified : .modified
    }

    /// The blob id git would compute for the file now on disk, after its
    /// line-ending conversion, from the hash cache when nothing it depends on changed.
    private func contentID(of entry: GitIndexEntry, absolutePath: String, stat: GitFileStat) -> GitObjectID? {
        let conversion = stat.isSymlink
            ? GitTextConversion.none
            : GitTextConversion(attributes.states(forFile: entry.path), autoCRLF: autoCRLF, indexBlob: entry.id)
        if let cached = repository.cache.hash(forPath: entry.path, stat: stat, conversion: conversion) { return cached }
        let id = stat.isSymlink
            ? GitWorkTreeIO.hashSymlink(atPath: absolutePath)
            : GitWorkTreeIO.hashFile(atPath: absolutePath, converting: conversion) { try? repository.blob($0) }
        if let id { repository.cache.storeHash(id, forPath: entry.path, stat: stat, conversion: conversion) }
        return id
    }

    /// git's stat comparison (`match_stat_data`), honoring `core.trustCtime` and `core.checkStat`.
    private func statMatches(_ entry: GitIndexEntry, _ stat: GitFileStat) -> Bool {
        let recorded = entry.modificationTime
        guard recorded.seconds == stat.modificationTime.seconds else { return false }
        if checkAllStat, recorded.nanoseconds != stat.modificationTime.nanoseconds { return false }
        if trustChangeTime {
            guard entry.statusChangeTime.seconds == stat.statusChangeTime.seconds else { return false }
            if checkAllStat, entry.statusChangeTime.nanoseconds != stat.statusChangeTime.nanoseconds { return false }
        }
        if checkAllStat {
            guard entry.userID == stat.userID, entry.groupID == stat.groupID,
                  entry.inode == UInt32(truncatingIfNeeded: stat.inode) else { return false }
        }
        return entry.size == UInt32(truncatingIfNeeded: stat.size)
    }

    /// An entry written in the same instant as the index may have changed
    /// again without its timestamp changing, so its content must be checked.
    private func isRacy(_ entry: GitIndexEntry) -> Bool {
        guard let timestamp = index.timestamp, timestamp.seconds != 0 else { return false }
        let modified = entry.modificationTime
        return timestamp.seconds < modified.seconds
            || (timestamp.seconds == modified.seconds && timestamp.nanoseconds <= modified.nanoseconds)
    }

    /// True when a directory above `path` is a symbolic link, which git treats
    /// as the file being gone.
    private mutating func leadingPathHasSymlink(_ path: String) -> Bool {
        guard let slash = path.lastIndex(of: "/") else { return false }
        return isOrIsInsideSymlink(String(path[..<slash]))
    }

    /// Memoized per directory: the directory or one of its parents is a symbolic link.
    private mutating func isOrIsInsideSymlink(_ directory: String) -> Bool {
        if let known = symlinkDirectories[directory] { return known }
        let result: Bool
        if let stat = GitFileStat.read(rootPath + "/" + directory), stat.isSymlink {
            result = true
        } else if let slash = directory.lastIndex(of: "/") {
            result = isOrIsInsideSymlink(String(directory[..<slash]))
        } else {
            result = false
        }
        symlinkDirectories[directory] = result
        return result
    }

    private func submoduleStatus(of entry: GitIndexEntry, at path: String, stat: GitFileStat) throws -> GitFileStatus {
        guard stat.isDirectory else { return .typeChanged }
        guard options.inspectSubmodules,
              let submodule = GitRepository(workTree: URL(fileURLWithPath: path, isDirectory: true)),
              let commit = try? submodule.head().commit else {
            // An empty directory is a submodule that was never checked out.
            return .unmodified
        }
        if commit != entry.id { return .modified }
        let nested = GitStatusOptions(includeUntracked: options.includeUntracked, includeAheadBehind: false, inspectSubmodules: true)
        let dirty = (try? submodule.status(nested).isClean == false) ?? false
        return dirty ? .modified : .unmodified
    }

    // MARK: Untracked files

    private struct TrackedPaths {
        var files = Set<String>()
        var directories = Set<String>()
        var gitlinks = Set<String>()
    }

    private func trackedPaths() -> TrackedPaths {
        var tracked = TrackedPaths()
        for entry in index.entries {
            let path = ignoreCase ? ASCII.lowercased(entry.path) : entry.path
            tracked.files.insert(path)
            if entry.mode.isGitlink { tracked.gitlinks.insert(path) }
            var directory = Substring(path)
            while let slash = directory.lastIndex(of: "/") {
                directory = directory[..<slash]
                if !tracked.directories.insert(String(directory)).inserted { break }
            }
        }
        return tracked
    }

    /// Untracked, non-ignored files, sorted by path, found by walking the work
    /// tree the way git does: ignored directories are not entered, directories
    /// holding another repository are reported whole, and `.git` is skipped.
    private func untrackedPaths() -> [String] {
        let tracked = trackedPaths()
        var result: [String] = []
        walk(relativeDirectory: [], fileSystemDirectory: rootPath, stack: [rules.list(forDirectory: [])], tracked: tracked, into: &result)
        result.sort { $0.precedesInByteOrder($1) }
        return result
    }

    private func walk(
        relativeDirectory prefix: [UInt8],
        fileSystemDirectory: String,
        stack: [GitIgnoreList?],
        tracked: TrackedPaths,
        into result: inout [String]
    ) {
        guard let entries = GitWorkTreeIO.readDirectory(fileSystemDirectory) else { return }
        let dotGit = Array(".git".utf8)
        for entry in entries {
            if ASCII.equal(entry.name, dotGit, ignoringCase: ignoreCase) { continue }
            if entry.kind == .other { continue }
            let name = precomposeUnicode ? Self.precomposed(entry.name) : entry.name
            let path = prefix + name
            let pathString = String(decoding: path, as: UTF8.self)
            let key = ignoreCase ? ASCII.lowercased(pathString) : pathString
            let isDirectory = entry.kind == .directory
            if !isDirectory, tracked.files.contains(key) { continue }
            if rules.isExcluded(path, basenameStart: prefix.count, isDirectory: isDirectory, stack: stack) { continue }
            let childPath = fileSystemDirectory + "/" + String(decoding: entry.name, as: UTF8.self)
            guard isDirectory else {
                result.append(pathString)
                continue
            }
            if !tracked.directories.contains(key) {
                if tracked.gitlinks.contains(key) { continue }
                if GitRepository.locateGitDirectory(in: URL(fileURLWithPath: childPath, isDirectory: true)) != nil {
                    result.append(pathString + "/")
                    continue
                }
            }
            let childPrefix = path + [ASCII.slash]
            walk(
                relativeDirectory: childPrefix,
                fileSystemDirectory: childPath,
                stack: stack + [rules.list(forDirectory: childPrefix)],
                tracked: tracked,
                into: &result
            )
        }
    }

    /// With `core.precomposeUnicode`, git reports decomposed file names in composed (NFC) form.
    private static func precomposed(_ name: [UInt8]) -> [UInt8] {
        guard name.contains(where: { $0 >= 0x80 }) else { return name }
        return Array(String(decoding: name, as: UTF8.self).precomposedStringWithCanonicalMapping.utf8)
    }
}
