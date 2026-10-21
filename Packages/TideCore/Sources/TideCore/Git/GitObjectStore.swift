import Foundation

/// Reads objects from an `objects/` directory: packs, loose files and alternates.
///
/// Lookups check packs first, then loose files, then the object directories
/// listed in `objects/info/alternates`. When an object is missing, the pack
/// directory is rescanned once, because `git gc` may have moved it into a new
/// pack since the last scan. Safe to use from several threads.
final class GitObjectStore: @unchecked Sendable {
    let directory: URL
    private let alternateDepth: Int
    private let lock = NSLock()
    private var packs: [(serial: Int, pack: GitPack)]?
    private var packNames: Set<String> = []
    private var nextSerial = 0
    private var alternates: [GitObjectStore]?
    private var cache = DeltaBaseCache(byteLimit: 32 << 20, entryLimit: 4 << 20)

    /// Git refuses alternates nested deeper than this.
    private static let maximumAlternateDepth = 5
    /// Guards against delta cycles in corrupt packs.
    private static let maximumDeltaChain = 10_000

    init(directory: URL, alternateDepth: Int = 0) {
        self.directory = directory
        self.alternateDepth = alternateDepth
    }

    /// Reads an object, throwing `GitError.notFound` when no store has it.
    func read(_ id: GitObjectID) throws -> GitObject {
        if let object = try readIfPresent(id, depth: 0) { return object }
        throw GitError.notFound("object \(id)")
    }

    /// Reads an object, or returns nil when it does not exist.
    func readIfPresent(_ id: GitObjectID, depth: Int) throws -> GitObject? {
        guard depth < 64 else { throw GitError.corrupt("delta bases loop through \(id)") }
        if let object = try readFromPacks(id, depth: depth) { return object }
        if let object = try readLoose(id) { return object }
        for alternate in loadedAlternates() {
            if let object = try alternate.readIfPresent(id, depth: depth + 1) { return object }
        }
        if rescanPacks(), let object = try readFromPacks(id, depth: depth) { return object }
        return nil
    }

    private func readFromPacks(_ id: GitObjectID, depth: Int) throws -> GitObject? {
        for (serial, pack) in loadedPacks() {
            if let offset = pack.offset(of: id) {
                return try readPacked(pack, serial: serial, offset: offset, depth: depth)
            }
        }
        return nil
    }

    // MARK: Loose objects

    private func readLoose(_ id: GitObjectID) throws -> GitObject? {
        let hex = id.hex
        let url = directory
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(hex.dropFirst(2)))
        guard let compressed = try GitFile.readIfExists(url) else { return nil }
        let inflated = try compressed.withUnsafeBytes { try Inflate.zlib($0) }
        return try inflated.withUnsafeBytes { bytes -> GitObject in
            guard let space = bytes.firstIndex(of: ASCII.space, from: 0),
                  let nul = bytes.firstIndex(of: ASCII.nul, from: space),
                  let type = GitObjectType(name: UnsafeRawBufferPointer(rebasing: bytes[0..<space])),
                  let size = Int(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(space + 1)..<nul]), as: UTF8.self)),
                  size == bytes.count - nul - 1 else {
                throw GitError.corrupt("bad loose object header in \(id)")
            }
            return GitObject(type: type, data: Data(bytes[(nul + 1)...]))
        }
    }

    // MARK: Packs

    private func readPacked(_ pack: GitPack, serial: Int, offset: Int, depth: Int) throws -> GitObject {
        var chain: [(offset: Int, header: GitPack.EntryHeader)] = []
        var current = offset
        var base: GitObject?
        while base == nil {
            if let cached = cachedObject(pack: serial, offset: current) {
                base = cached
                break
            }
            let header = try pack.entryHeader(at: current)
            switch header.entry {
            case .object(let type):
                let object = GitObject(type: type, data: try pack.inflate(header))
                if !chain.isEmpty { cacheObject(object, pack: serial, offset: current) }
                base = object
            case .offsetDelta(let baseOffset):
                chain.append((current, header))
                current = baseOffset
            case .referenceDelta(let baseID):
                chain.append((current, header))
                if let baseOffset = pack.offset(of: baseID) {
                    current = baseOffset
                } else if let object = try readIfPresent(baseID, depth: depth + 1) {
                    base = object
                } else {
                    throw GitError.notFound("delta base \(baseID)")
                }
            }
            guard chain.count <= Self.maximumDeltaChain else { throw GitError.corrupt("delta chain is too long") }
        }
        guard var object = base else { throw GitError.corrupt("unresolved delta") }
        for link in chain.reversed() {
            let delta = try pack.inflate(link.header)
            object = GitObject(type: object.type, data: try GitDelta.apply(delta, to: object.data))
            cacheObject(object, pack: serial, offset: link.offset)
        }
        return object
    }

    private func loadedPacks() -> [(serial: Int, pack: GitPack)] {
        lock.lock()
        defer { lock.unlock() }
        if let packs { return packs }
        let loaded = loadPacks(keeping: [])
        packs = loaded
        return loaded
    }

    /// Re-lists `objects/pack`. Returns true when the set of packs changed.
    private func rescanPacks() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let names = Set(Self.indexFileNames(in: directory.appendingPathComponent("pack", isDirectory: true)))
        guard names != packNames else { return false }
        packs = loadPacks(keeping: packs ?? [])
        return true
    }

    /// Opens every pack with an index. Must be called with the lock held.
    private func loadPacks(keeping existing: [(serial: Int, pack: GitPack)]) -> [(serial: Int, pack: GitPack)] {
        let packDirectory = directory.appendingPathComponent("pack", isDirectory: true)
        let names = Self.indexFileNames(in: packDirectory)
        var byName: [String: (serial: Int, pack: GitPack)] = [:]
        for entry in existing {
            byName[entry.pack.packURL.deletingPathExtension().lastPathComponent] = entry
        }
        var result: [(serial: Int, pack: GitPack)] = []
        for name in names {
            let stem = String(name.dropLast(4))
            if let kept = byName[stem] {
                result.append(kept)
            } else if let pack = try? GitPack(indexURL: packDirectory.appendingPathComponent(name)) {
                // A pack that fails to open is skipped; its objects surface as not found.
                nextSerial += 1
                result.append((nextSerial, pack))
            }
        }
        packNames = Set(names)
        return result
    }

    private static func indexFileNames(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".idx") && $0.hasPrefix("pack-") }.sorted()
    }

    // MARK: Alternates

    private func loadedAlternates() -> [GitObjectStore] {
        lock.lock()
        defer { lock.unlock() }
        if let alternates { return alternates }
        var stores: [GitObjectStore] = []
        if alternateDepth < Self.maximumAlternateDepth,
           let data = try? GitFile.readIfExists(directory.appendingPathComponent("info/alternates")) {
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, !path.hasPrefix("#") else { continue }
                let url = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path, isDirectory: true)
                    : directory.appendingPathComponent(path, isDirectory: true)
                stores.append(GitObjectStore(directory: url.standardizedFileURL, alternateDepth: alternateDepth + 1))
            }
        }
        alternates = stores
        return stores
    }

    // MARK: Delta base cache

    private func cachedObject(pack: Int, offset: Int) -> GitObject? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(for: DeltaBaseCache.Key(pack: pack, offset: offset))
    }

    private func cacheObject(_ object: GitObject, pack: Int, offset: Int) {
        lock.lock()
        defer { lock.unlock() }
        cache.insert(object, for: DeltaBaseCache.Key(pack: pack, offset: offset))
    }
}

/// Recently rebuilt pack objects, keyed by pack and offset, so sibling deltas
/// that share a base do not inflate the whole chain again.
struct DeltaBaseCache {
    struct Key: Hashable {
        var pack: Int
        var offset: Int
    }

    let byteLimit: Int
    let entryLimit: Int
    private var entries: [Key: (object: GitObject, lastUse: UInt64)] = [:]
    private var totalBytes = 0
    private var clock: UInt64 = 0

    init(byteLimit: Int, entryLimit: Int) {
        self.byteLimit = byteLimit
        self.entryLimit = entryLimit
    }

    mutating func object(for key: Key) -> GitObject? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.object, clock)
        return entry.object
    }

    mutating func insert(_ object: GitObject, for key: Key) {
        let size = object.data.count
        guard size <= entryLimit else { return }
        if let old = entries[key] { totalBytes -= old.object.data.count }
        clock += 1
        entries[key] = (object, clock)
        totalBytes += size
        guard totalBytes > byteLimit else { return }
        // Evict the least recently used entries down to three quarters of the limit.
        for (key, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard totalBytes > byteLimit * 3 / 4 else { break }
            entries[key] = nil
            totalBytes -= entry.object.data.count
        }
    }
}

/// Small file-reading helpers shared by the git reader.
enum GitFile {
    /// Reads a whole file, returning nil when it does not exist.
    static func readIfExists(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor < 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw GitError.io("cannot open \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw GitError.io("cannot stat \(url.path)") }
        if info.st_mode & S_IFMT == S_IFDIR { return nil }
        var data = Data(count: Int(info.st_size))
        var total = 0
        let complete: Bool = data.withUnsafeMutableBytes { buffer in
            while total < buffer.count {
                let count = read(descriptor, buffer.baseAddress! + total, buffer.count - total)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return false }
                total += count
            }
            return true
        }
        guard complete || total == data.count else { throw GitError.io("short read from \(url.path)") }
        return data
    }

    /// Reads a small text file such as `HEAD` or `commondir`, without the trailing newline.
    static func readLine(_ url: URL) -> String? {
        guard let data = try? readIfExists(url) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        while let last = text.last, last == "\n" || last == "\r" { text.removeLast() }
        return text
    }
}
