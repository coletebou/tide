import Foundation
import Observation
import TideCore

/// A node in the Explorer tree. Children load lazily when a folder expands.
@Observable
final class FileNode: Identifiable {
    let path: String
    private(set) var entry: FileEntry
    var children: [FileNode]?
    var isExpanded = false
    var isLoading = false

    init(entry: FileEntry) {
        path = entry.path
        self.entry = entry
    }

    var id: String { path }
    var name: String { path.isEmpty ? "" : entry.name }
    var isDirectory: Bool { entry.isDirectory }
}

/// The open folder: its file system, Explorer tree, and the file index that
/// powers Quick Open. Local folders and remote SFTP folders look the same here.
@Observable
final class Workspace {
    private(set) var fileSystem: any WorkspaceFileSystem
    private(set) var root: FileNode
    /// Every file path in the workspace (minus excludes), for Quick Open.
    private(set) var allFiles: [String] = []
    private(set) var isIndexing = false
    var excludes: [Glob]
    /// Security-scoped URL for folders opened from the Files app.
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    var name: String { fileSystem.displayName }
    var isRemote: Bool { fileSystem.scheme != "file" }

    /// The local folder backing this workspace, if any.
    var localRoot: URL? { (fileSystem as? LocalFileSystem)?.root }

    init(fileSystem: any WorkspaceFileSystem, excludes: [String] = DefaultExcludes.files, scopedURL: URL? = nil) {
        self.fileSystem = fileSystem
        self.excludes = excludes.map { Glob($0) }
        self.scopedURL = scopedURL
        root = FileNode(entry: FileEntry(path: "", isDirectory: true))
        root.isExpanded = true
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    func isExcluded(_ path: String) -> Bool {
        excludes.contains { $0.matches(path) }
    }

    // MARK: - Tree

    func loadChildren(of node: FileNode) async {
        guard node.isDirectory else { return }
        node.isLoading = true
        defer { node.isLoading = false }
        do {
            let entries = try await fileSystem.list(node.path).filter { !isExcluded($0.path) }
            let existing = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.path, $0) })
            node.children = FileOrdering.sorted(entries).map { entry in
                existing[entry.path] ?? FileNode(entry: entry)
            }
            // Keep expanded folders current too.
            for child in node.children ?? [] where child.isExpanded {
                await loadChildren(of: child)
            }
        } catch {
            node.children = []
        }
    }

    func toggle(_ node: FileNode) async {
        node.isExpanded.toggle()
        if node.isExpanded, node.children == nil { await loadChildren(of: node) }
    }

    func refresh() async {
        await loadChildren(of: root)
        reindex()
    }

    func collapseAll() {
        func collapse(_ node: FileNode) {
            node.isExpanded = false
            node.children?.forEach(collapse)
        }
        root.children?.forEach(collapse)
    }

    /// Expands the folders down to `path` so it shows in the Explorer.
    func reveal(_ path: String) async {
        var current = root
        for component in WorkspacePath.components(of: WorkspacePath.parent(of: path)) {
            if current.children == nil { await loadChildren(of: current) }
            guard let next = current.children?.first(where: { $0.entry.name == component }) else { return }
            if !next.isExpanded {
                next.isExpanded = true
                if next.children == nil { await loadChildren(of: next) }
            }
            current = next
        }
    }

    func node(for path: String) -> FileNode? {
        func find(_ node: FileNode) -> FileNode? {
            if node.path == path { return node }
            for child in node.children ?? [] where WorkspacePath.isDescendant(path, of: child.path) {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(root)
    }

    // MARK: - File operations

    func createFile(named name: String, in folder: String) async throws -> String {
        let path = try WorkspacePath.normalize(WorkspacePath.join(folder, name))
        try await fileSystem.createFile(path)
        await refreshFolder(folder)
        allFiles.append(path)
        return path
    }

    func createFolder(named name: String, in folder: String) async throws -> String {
        let path = try WorkspacePath.normalize(WorkspacePath.join(folder, name))
        try await fileSystem.createDirectory(path)
        await refreshFolder(folder)
        return path
    }

    func rename(_ path: String, to newName: String) async throws -> String {
        let destination = try WorkspacePath.normalize(WorkspacePath.join(WorkspacePath.parent(of: path), newName))
        try await fileSystem.move(path, to: destination)
        await refreshFolder(WorkspacePath.parent(of: path))
        reindex()
        return destination
    }

    func move(_ path: String, toFolder folder: String) async throws -> String {
        let destination = try WorkspacePath.normalize(WorkspacePath.join(folder, WorkspacePath.name(of: path)))
        guard destination != path else { return path }
        try await fileSystem.move(path, to: destination)
        await refreshFolder(WorkspacePath.parent(of: path))
        await refreshFolder(folder)
        reindex()
        return destination
    }

    func duplicate(_ path: String) async throws -> String {
        let parent = WorkspacePath.parent(of: path)
        let name = WorkspacePath.name(of: path)
        let ext = WorkspacePath.fileExtension(of: name)
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var candidate = ""
        for number in 1...99 {
            candidate = WorkspacePath.join(parent, ext.isEmpty ? "\(stem) copy\(number == 1 ? "" : " \(number)")" : "\(stem) copy\(number == 1 ? "" : " \(number)").\(ext)")
            if !(await fileSystem.exists(candidate)) { break }
        }
        try await fileSystem.copy(path, to: candidate)
        await refreshFolder(parent)
        reindex()
        return candidate
    }

    func delete(_ path: String) async throws {
        try await fileSystem.delete(path)
        await refreshFolder(WorkspacePath.parent(of: path))
        allFiles.removeAll { WorkspacePath.isDescendant($0, of: path) }
    }

    func refreshFolder(_ folder: String) async {
        if let node = node(for: folder), node.children != nil {
            await loadChildren(of: node)
        }
    }

    // MARK: - Quick Open index

    /// Rebuilds the list of files, walking the tree in the background.
    func reindex() {
        indexTask?.cancel()
        isIndexing = true
        let fileSystem = fileSystem
        let excludes = excludes
        indexTask = Task { [weak self] in
            var files: [String] = []
            var queue = [""]
            while let folder = queue.popLast(), files.count < 50_000 {
                if Task.isCancelled { return }
                guard let entries = try? await fileSystem.list(folder) else { continue }
                for entry in entries where !excludes.contains(where: { $0.matches(entry.path) }) {
                    if entry.isDirectory {
                        if !Self.heavyFolders.contains(entry.name) { queue.append(entry.path) }
                    } else {
                        files.append(entry.path)
                    }
                }
            }
            files.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            guard let self, !Task.isCancelled else { return }
            self.allFiles = files
            self.isIndexing = false
        }
    }

    /// Folders skipped by Quick Open's index (VS Code excludes them from search by default).
    private static let heavyFolders: Set<String> = ["node_modules", "bower_components", ".build", "DerivedData", "Pods", ".venv", "venv", "__pycache__", "target", "dist"]
}
