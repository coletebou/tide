import Foundation
import Observation
import TideCore

/// Source control state for the workspace: the branch and changed files,
/// read straight from the `.git` folder (iOS apps cannot run the git binary).
@Observable
final class SourceControlModel {
    nonisolated enum ChangeKind: String, Sendable {
        case modified = "M", added = "A", deleted = "D", untracked = "U", renamed = "R", conflicted = "C"
    }

    nonisolated struct Change: Identifiable, Hashable, Sendable {
        var path: String
        var kind: ChangeKind
        var staged: Bool
        var id: String { (staged ? "staged:" : "") + path }
    }

    private(set) var branch: String?
    private(set) var changes: [Change] = []
    private(set) var isRepository = false
    private(set) var lastError: String?
    var commitMessage = ""

    @ObservationIgnored weak var workbench: Workbench?

    var stagedChanges: [Change] { changes.filter(\.staged) }
    var unstagedChanges: [Change] { changes.filter { !$0.staged } }

    /// Re-reads HEAD, the index and the work tree.
    func refresh() async {
        guard let root = workbench?.workspace.localRoot else {
            isRepository = false
            branch = nil
            changes = []
            return
        }
        let snapshot = await Task.detached(priority: .utility) { GitSnapshot.read(root: root) }.value
        isRepository = snapshot.isRepository
        branch = snapshot.branch
        changes = snapshot.changes
        lastError = snapshot.error
    }

    /// The file's text at HEAD, for diffs and gutter change markers.
    func headContent(of path: String) async -> String? {
        guard let root = workbench?.workspace.localRoot else { return nil }
        return await Task.detached(priority: .utility) { GitSnapshot.headContent(root: root, path: path) }.value
    }

    /// The file's staged text, for diffs.
    func indexContent(of path: String) async -> String? {
        guard let root = workbench?.workspace.localRoot else { return nil }
        return await Task.detached(priority: .utility) { GitSnapshot.indexContent(root: root, path: path) }.value
    }
}

extension Workbench {
    var gitBranch: String? { scm.branch }
    var scmChangeCount: Int { scm.changes.count }
}

/// A point-in-time read of the repository, made off the main thread.
nonisolated struct GitSnapshot: Sendable {
    var isRepository = false
    var branch: String?
    var changes: [SourceControlModel.Change] = []
    var error: String?

    static func read(root: URL) -> GitSnapshot {
        guard let repository = GitRepository.discover(from: root) else { return GitSnapshot() }
        var snapshot = GitSnapshot(isRepository: true)
        do {
            let status = try repository.status(GitStatusOptions(includeUntracked: true, includeAheadBehind: false, inspectSubmodules: false))
            snapshot.branch = status.head.branchName ?? status.head.commit.map { $0.abbreviated() }
            let prefix = relativePrefix(root: root, workTree: repository.workTree)
            for entry in status.entries {
                guard prefix.isEmpty || entry.path.hasPrefix(prefix) else { continue }
                let path = String(entry.path.dropFirst(prefix.count))
                if entry.conflict != nil {
                    snapshot.changes.append(.init(path: path, kind: .conflicted, staged: false))
                    continue
                }
                if entry.isUntracked {
                    snapshot.changes.append(.init(path: path, kind: .untracked, staged: false))
                    continue
                }
                if let kind = kind(entry.index) { snapshot.changes.append(.init(path: path, kind: kind, staged: true)) }
                if let kind = kind(entry.workTree) { snapshot.changes.append(.init(path: path, kind: kind, staged: false)) }
            }
        } catch {
            snapshot.error = String(describing: error)
        }
        return snapshot
    }

    static func headContent(root: URL, path: String) -> String? {
        guard let repository = GitRepository.discover(from: root) else { return nil }
        let prefix = relativePrefix(root: root, workTree: repository.workTree)
        guard let data = repository.contentOfFileInHEAD(path: prefix + path) else { return nil }
        return TextFileCodec.decode(data)?.text
    }

    static func indexContent(root: URL, path: String) -> String? {
        guard let repository = GitRepository.discover(from: root) else { return nil }
        let prefix = relativePrefix(root: root, workTree: repository.workTree)
        guard let data = repository.contentOfFileInIndex(path: prefix + path) else { return nil }
        return TextFileCodec.decode(data)?.text
    }

    private static func kind(_ status: GitFileStatus) -> SourceControlModel.ChangeKind? {
        switch status {
        case .unmodified: nil
        case .modified, .typeChanged: .modified
        case .added: .added
        case .deleted: .deleted
        case .unmerged: .conflicted
        case .untracked: .untracked
        }
    }

    /// The workspace folder's path inside the repository ("" when it is the root).
    private static func relativePrefix(root: URL, workTree: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let treePath = workTree.standardizedFileURL.resolvingSymlinksInPath().path
        guard rootPath.count > treePath.count, rootPath.hasPrefix(treePath) else { return "" }
        return String(rootPath.dropFirst(treePath.count + 1)) + "/"
    }
}
