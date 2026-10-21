import Foundation

/// A named pointer into history, such as a branch, tag or remote-tracking branch.
public struct GitReference: Equatable, Sendable {
    /// The full name, such as `refs/heads/main`.
    public var name: String
    /// The object the reference resolves to after following symbolic references;
    /// nil when it points at a reference that does not exist.
    public var target: GitObjectID?
    /// For a symbolic reference (like `refs/remotes/origin/HEAD`), the reference it points at.
    public var symbolicTarget: String?
    /// For an annotated tag, the object the tag points at, when `packed-refs` records it.
    public var peeledTarget: GitObjectID?

    public init(name: String, target: GitObjectID?, symbolicTarget: String? = nil, peeledTarget: GitObjectID? = nil) {
        self.name = name
        self.target = target
        self.symbolicTarget = symbolicTarget
        self.peeledTarget = peeledTarget
    }

    /// The name without `refs/heads/`, `refs/tags/` or `refs/remotes/`, as git shows it.
    public var shortName: String { GitReference.shorten(name) }

    static func shorten(_ name: String) -> String {
        for prefix in ["refs/heads/", "refs/tags/", "refs/remotes/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        if name.hasPrefix("refs/") { return String(name.dropFirst(5)) }
        return name
    }
}

/// A local branch and the remote branch it integrates with.
public struct GitBranch: Equatable, Sendable {
    /// The short name, such as `main` or `feature/login`.
    public var name: String
    /// The full name, such as `refs/heads/main`.
    public var referenceName: String
    public var commit: GitObjectID
    /// The configured upstream, from `branch.<name>.remote` and `branch.<name>.merge`.
    public var upstream: GitUpstream?

    public init(name: String, referenceName: String, commit: GitObjectID, upstream: GitUpstream?) {
        self.name = name
        self.referenceName = referenceName
        self.commit = commit
        self.upstream = upstream
    }
}

/// The branch a local branch pulls from.
public struct GitUpstream: Equatable, Sendable {
    /// The remote name, or `.` when the upstream is another local branch.
    public var remote: String
    /// The branch on the remote, such as `refs/heads/main`.
    public var mergeReference: String
    /// The local reference that mirrors it, such as `refs/remotes/origin/main`,
    /// when the remote's fetch refspecs map the branch.
    public var trackingReference: String?

    public init(remote: String, mergeReference: String, trackingReference: String?) {
        self.remote = remote
        self.mergeReference = mergeReference
        self.trackingReference = trackingReference
    }

    /// The name git shows for the upstream, such as `origin/main`.
    public var name: String {
        if let trackingReference { return GitReference.shorten(trackingReference) }
        return "\(remote)/\(GitReference.shorten(mergeReference))"
    }
}

/// Where HEAD points.
public struct GitHead: Equatable, Sendable {
    /// The reference HEAD points at, such as `refs/heads/main`; nil when HEAD is detached.
    public var referenceName: String?
    /// The commit HEAD resolves to; nil on an unborn branch (a new repository or orphan branch).
    public var commit: GitObjectID?

    public init(referenceName: String?, commit: GitObjectID?) {
        self.referenceName = referenceName
        self.commit = commit
    }

    /// The current branch, such as `main`, or nil when HEAD is detached.
    public var branchName: String? {
        guard let referenceName else { return nil }
        return referenceName.hasPrefix("refs/heads/") ? String(referenceName.dropFirst(11)) : referenceName
    }

    public var isDetached: Bool { referenceName == nil }
    public var isUnborn: Bool { referenceName != nil && commit == nil }
}

/// Reads references stored as loose files and in `packed-refs`.
///
/// In a linked worktree, `HEAD`, pseudo-references like `MERGE_HEAD` and the
/// `refs/bisect`, `refs/worktree` and `refs/rewritten` hierarchies belong to
/// the worktree's own git directory; everything else is shared through the
/// common directory.
struct GitReferenceStore {
    let gitDirectory: URL
    let commonDirectory: URL

    enum Value: Equatable {
        case object(GitObjectID)
        case symbolic(String)
    }

    struct PackedReference {
        var id: GitObjectID
        var peeled: GitObjectID?
    }

    /// git stops following symbolic references after this many hops.
    static let maximumSymbolicDepth = 5

    private static let perWorktreePrefixes = ["refs/bisect/", "refs/worktree/", "refs/rewritten/"]

    func baseDirectory(for name: String) -> URL {
        if !name.contains("/") || Self.perWorktreePrefixes.contains(where: name.hasPrefix) { return gitDirectory }
        return commonDirectory
    }

    /// The raw value of `name`: the loose file if present, else its `packed-refs` line.
    func read(_ name: String) throws -> Value? {
        guard Self.isValidName(name) else { return nil }
        if let loose = try readLoose(name) { return loose }
        return try packedReferences()[name].map { .object($0.id) }
    }

    private func readLoose(_ name: String) throws -> Value? {
        let url = baseDirectory(for: name).appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFLNK {
            // Very old repositories made HEAD a symbolic link into refs/.
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(url.path, &buffer, buffer.count - 1)
            guard length > 0 else { return nil }
            let target = String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return target.hasPrefix("refs/") ? .symbolic(target) : nil
        }
        guard info.st_mode & S_IFMT == S_IFREG, let data = try GitFile.readIfExists(url) else { return nil }
        return try Self.parse(data, name: name)
    }

    static func parse(_ data: Data, name: String) throws -> Value {
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("ref:") {
            let target = text.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidName(target) else { throw GitError.corrupt("bad symbolic reference \(name)") }
            return .symbolic(target)
        }
        let hex = text.prefix { !$0.isWhitespace }
        guard let id = GitObjectID(hex: hex) else { throw GitError.corrupt("bad reference \(name)") }
        return .object(id)
    }

    /// Parses `packed-refs`: `<id> <name>` lines, each optionally followed by a
    /// `^<id>` line with the peeled target of an annotated tag.
    func packedReferences() throws -> [String: PackedReference] {
        guard let data = try GitFile.readIfExists(commonDirectory.appendingPathComponent("packed-refs")) else { return [:] }
        var references: [String: PackedReference] = [:]
        var lastName: String?
        for line in data.split(separator: ASCII.lf, omittingEmptySubsequences: true) {
            var line = line
            if line.last == ASCII.cr { line = line.dropLast() }
            guard let first = line.first else { continue }
            if first == UInt8(ascii: "#") { continue }
            if first == UInt8(ascii: "^") {
                if let lastName, let peeled = GitObjectID(hexUTF8: line.dropFirst()) {
                    references[lastName]?.peeled = peeled
                }
                continue
            }
            guard line.count > 41, line[line.startIndex + 40] == ASCII.space,
                  let id = GitObjectID(hexUTF8: line.prefix(40)) else {
                throw GitError.corrupt("bad packed-refs line")
            }
            let name = String(decoding: line.dropFirst(41), as: UTF8.self)
            references[name] = PackedReference(id: id, peeled: nil)
            lastName = name
        }
        return references
    }

    /// Follows symbolic references from `name`. Returns the last reference
    /// name in the chain and the object it points at (nil if that reference
    /// does not exist), or nil when `name` itself does not exist.
    func resolve(_ name: String) throws -> (name: String, id: GitObjectID?)? {
        var current = name
        for depth in 0...Self.maximumSymbolicDepth {
            switch try read(current) {
            case .object(let id)?:
                return (current, id)
            case .symbolic(let target)?:
                guard depth < Self.maximumSymbolicDepth else { throw GitError.corrupt("symbolic reference loop at \(name)") }
                current = target
            case nil:
                return current == name ? nil : (current, nil)
            }
        }
        return nil
    }

    /// Every reference whose full name starts with `prefix` (such as `refs/heads/`), sorted by name.
    func list(prefix: String) throws -> [GitReference] {
        var raw: [String: Value] = [:]
        let packed = try packedReferences()
        for (name, reference) in packed where name.hasPrefix(prefix) {
            raw[name] = .object(reference.id)
        }
        var names = Set<String>()
        collectLooseNames(in: commonDirectory, relative: "refs", into: &names)
        if gitDirectory != commonDirectory {
            for perWorktree in Self.perWorktreePrefixes {
                collectLooseNames(in: gitDirectory, relative: String(perWorktree.dropLast()), into: &names)
            }
        }
        for name in names where name.hasPrefix(prefix) {
            if let value = try? readLoose(name) { raw[name] = value }
        }
        return try raw.keys.sorted { $0.precedesInByteOrder($1) }.map { name in
            switch raw[name] {
            case .object(let id)?:
                return GitReference(name: name, target: id, peeledTarget: packed[name]?.peeled)
            case .symbolic(let target)?:
                return GitReference(name: name, target: try resolve(target)?.id, symbolicTarget: target)
            case nil:
                return GitReference(name: name, target: nil)
            }
        }
    }

    private func collectLooseNames(in base: URL, relative: String, into names: inout Set<String>) {
        let directory = base.appendingPathComponent(relative, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for child in children where !child.hasSuffix(".lock") && !child.hasPrefix(".") {
            let name = "\(relative)/\(child)"
            var info = stat()
            guard lstat(directory.appendingPathComponent(child).path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                collectLooseNames(in: base, relative: name, into: &names)
            } else if Self.isValidName(name) {
                names.insert(name)
            }
        }
    }

    /// git's `check-ref-format` rules, plus one-level names (HEAD, MERGE_HEAD) in capitals.
    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, name != "@", bytes.last != UInt8(ascii: "."), bytes.last != ASCII.slash else { return false }
        if !name.contains("/") {
            return bytes.allSatisfy { ASCII.isUpper($0) || $0 == UInt8(ascii: "_") }
        }
        guard name.hasPrefix("refs/") else { return false }
        if name.contains("..") || name.contains("@{") || name.contains("//") { return false }
        for byte in bytes {
            switch byte {
            case 0..<0x20, 0x7F, ASCII.space, UInt8(ascii: "~"), UInt8(ascii: "^"), UInt8(ascii: ":"),
                 UInt8(ascii: "?"), UInt8(ascii: "*"), UInt8(ascii: "["), ASCII.backslash:
                return false
            default:
                continue
            }
        }
        for component in name.split(separator: "/") where component.hasPrefix(".") || component.hasSuffix(".lock") {
            return false
        }
        return true
    }
}

extension GitConfig {
    /// The upstream configured for local branch `branch`, mapped to its
    /// remote-tracking reference through `remote.<remote>.fetch`.
    func upstream(ofBranch branch: String) -> GitUpstream? {
        guard let remote = string("branch.\(branch).remote"), !remote.isEmpty,
              let merge = string("branch.\(branch).merge"), !merge.isEmpty else { return nil }
        let mergeReference = merge.hasPrefix("refs/") ? merge : "refs/heads/\(merge)"
        if remote == "." {
            return GitUpstream(remote: remote, mergeReference: mergeReference, trackingReference: mergeReference)
        }
        var tracking: String?
        for refspec in strings("remote.\(remote).fetch") {
            if let mapped = Self.map(mergeReference, through: refspec) {
                tracking = mapped
                break
            }
        }
        return GitUpstream(remote: remote, mergeReference: mergeReference, trackingReference: tracking)
    }

    /// Applies the source-to-destination mapping of one fetch refspec, such as
    /// `+refs/heads/*:refs/remotes/origin/*`. Negative refspecs never map.
    static func map(_ reference: String, through refspec: String) -> String? {
        var spec = Substring(refspec)
        if spec.hasPrefix("+") { spec = spec.dropFirst() }
        guard !spec.hasPrefix("^"), let colon = spec.firstIndex(of: ":") else { return nil }
        let source = spec[..<colon]
        let destination = spec[spec.index(after: colon)...]
        guard let star = source.firstIndex(of: "*") else {
            return source == reference ? String(destination) : nil
        }
        let head = source[..<star]
        let tail = source[source.index(after: star)...]
        guard reference.hasPrefix(head), reference.hasSuffix(tail), reference.count >= head.count + tail.count,
              let destinationStar = destination.firstIndex(of: "*") else { return nil }
        let matched = reference.dropFirst(head.count).dropLast(tail.count)
        return String(destination[..<destinationStar]) + matched + destination[destination.index(after: destinationStar)...]
    }
}
