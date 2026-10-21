import Foundation

/// A file or folder in a workspace. `path` is workspace-relative POSIX
/// (`"Sources/App.swift"`; `""` is the root), so local folders and remote
/// SFTP workspaces share one model.
public struct FileEntry: Hashable, Identifiable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: Int64
    public var modified: Date?

    public init(path: String, isDirectory: Bool, isSymbolicLink: Bool = false, size: Int64 = 0, modified: Date? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
    }

    public var id: String { path }
    public var name: String { WorkspacePath.name(of: path) }
}

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case outsideWorkspace(String)
    case notFound(String)
    case alreadyExists(String)
    case notADirectory(String)
    case binaryFile(String)
    case unsupported(String)
    /// Text the file's encoding cannot store, such as an emoji in a Windows-1252 file.
    case unrepresentableCharacter(Character, TextEncoding)

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path): "'\(path)' is outside the workspace."
        case .notFound(let path): "'\(path)' does not exist."
        case .alreadyExists(let path): "A file or folder '\(path)' already exists."
        case .notADirectory(let path): "'\(path)' is not a folder."
        case .binaryFile(let path): "'\(path)' is a binary file."
        case .unsupported(let message): message
        case .unrepresentableCharacter(let character, let encoding): "'\(character)' cannot be saved in \(encoding.label)."
        }
    }
}

/// Storage behind a workspace: the app's sandbox, a folder the user granted
/// access to, or a remote host over SFTP.
public protocol WorkspaceFileSystem: Sendable {
    /// Shown in the Explorer header and window title.
    var displayName: String { get }
    /// `file` for local folders, `sftp` for remote ones.
    var scheme: String { get }

    func list(_ path: String) async throws -> [FileEntry]
    func stat(_ path: String) async throws -> FileEntry
    func read(_ path: String) async throws -> Data
    func write(_ path: String, data: Data) async throws
    func createDirectory(_ path: String) async throws
    func delete(_ path: String) async throws
    func move(_ path: String, to destination: String) async throws
    func copy(_ path: String, to destination: String) async throws
}

extension WorkspaceFileSystem {
    public func exists(_ path: String) async -> Bool {
        (try? await stat(path)) != nil
    }

    public func createFile(_ path: String, contents: Data = Data()) async throws {
        if await exists(path) { throw WorkspaceError.alreadyExists(path) }
        try await write(path, data: contents)
    }
}

/// Workspace-relative path helpers. Paths never start with `/` and never
/// contain `.` or `..` segments once normalized.
public enum WorkspacePath {
    public static func normalize(_ path: String) throws -> String {
        var segments: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                guard !segments.isEmpty else { throw WorkspaceError.outsideWorkspace(path) }
                segments.removeLast()
            } else {
                segments.append(segment)
            }
        }
        return segments.joined(separator: "/")
    }

    public static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if component.isEmpty { return base }
        return base + "/" + component
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    public static func fileExtension(of path: String) -> String {
        let name = name(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Path components from the root, for breadcrumbs.
    public static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Whether `path` is `ancestor` or inside it.
    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }
}

/// Explorer ordering: folders first, then files, compared the way Finder
/// does (case-insensitive, numbers by value), like VS Code's default sort.
public enum FileOrdering {
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
        }
    }
}

/// A folder on this device: the app's own Documents directory or a folder
/// opened through the document picker (with security-scoped access).
public struct LocalFileSystem: WorkspaceFileSystem {
    public let root: URL
    public let displayName: String
    public var scheme: String { "file" }

    public init(root: URL, displayName: String? = nil) {
        self.root = root.standardizedFileURL
        self.displayName = displayName ?? root.lastPathComponent
    }

    /// The URL for a workspace path, refusing paths that escape the root.
    public func url(for path: String) throws -> URL {
        let normalized = try WorkspacePath.normalize(path)
        return normalized.isEmpty ? root : root.appendingPathComponent(normalized)
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let directory = try url(for: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        } catch CocoaError.fileReadNoSuchFile {
            throw WorkspaceError.notFound(path)
        }
        let base = try WorkspacePath.normalize(path)
        return urls.map { entry(for: $0, path: WorkspacePath.join(base, $0.lastPathComponent)) }
    }

    public func stat(_ path: String) async throws -> FileEntry {
        let fileURL = try url(for: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw WorkspaceError.notFound(path) }
        return entry(for: fileURL, path: try WorkspacePath.normalize(path))
    }

    public func read(_ path: String) async throws -> Data {
        let fileURL = try url(for: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw WorkspaceError.notFound(path) }
        return try coordinatedRead(fileURL)
    }

    public func write(_ path: String, data: Data) async throws {
        let fileURL = try url(for: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    public func createDirectory(_ path: String) async throws {
        let directory = try url(for: path)
        if FileManager.default.fileExists(atPath: directory.path) { throw WorkspaceError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func delete(_ path: String) async throws {
        let target = try url(for: path)
        guard target != root else { throw WorkspaceError.outsideWorkspace(path) }
        guard FileManager.default.fileExists(atPath: target.path) else { throw WorkspaceError.notFound(path) }
        try FileManager.default.removeItem(at: target)
    }

    public func move(_ path: String, to destination: String) async throws {
        let source = try url(for: path)
        let target = try url(for: destination)
        guard source != root else { throw WorkspaceError.outsideWorkspace(path) }
        if FileManager.default.fileExists(atPath: target.path), source.path.lowercased() != target.path.lowercased() {
            throw WorkspaceError.alreadyExists(destination)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
    }

    public func copy(_ path: String, to destination: String) async throws {
        let source = try url(for: path)
        let target = try url(for: destination)
        if FileManager.default.fileExists(atPath: target.path) { throw WorkspaceError.alreadyExists(destination) }
        try FileManager.default.copyItem(at: source, to: target)
    }

    private func entry(for url: URL, path: String) -> FileEntry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        var isDirectory = values?.isDirectory ?? false
        if values?.isSymbolicLink == true {
            var target: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &target) { isDirectory = target.boolValue }
        }
        return FileEntry(
            path: path,
            isDirectory: isDirectory,
            isSymbolicLink: values?.isSymbolicLink ?? false,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate
        )
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(WorkspaceError.notFound(url.path))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
