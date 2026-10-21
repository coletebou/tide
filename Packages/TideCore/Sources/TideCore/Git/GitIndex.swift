import Foundation

/// A timestamp from the index: seconds and nanoseconds, truncated to 32 bits as git stores them.
public struct GitIndexTime: Equatable, Sendable {
    public var seconds: UInt32
    public var nanoseconds: UInt32

    public init(seconds: UInt32, nanoseconds: UInt32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

/// One entry of the index (the staging area).
public struct GitIndexEntry: Equatable, Sendable {
    /// Path relative to the work tree root, with `/` separators.
    public var path: String
    public var mode: GitFileMode
    /// The staged blob (or the commit, for a submodule).
    public var id: GitObjectID
    /// 0 for a normal entry; 1, 2 and 3 are the base, ours and theirs of a conflict.
    public var stage: Int
    /// File size in bytes, truncated to 32 bits, as of the last time git looked at the file.
    public var size: UInt32
    public var modificationTime: GitIndexTime
    /// The file's `ctime` (inode change time).
    public var statusChangeTime: GitIndexTime
    public var device: UInt32
    public var inode: UInt32
    public var userID: UInt32
    public var groupID: UInt32
    /// Set by `git update-index --assume-unchanged`.
    public var assumeValid: Bool
    /// Set for paths outside a sparse checkout; git does not look at them in the work tree.
    public var skipWorktree: Bool
    /// Set by `git add -N`: the path is tracked but has no staged content yet.
    public var intentToAdd: Bool
}

/// The parsed `.git/index` file. Versions 2, 3 and 4 are supported.
///
/// Optional extensions (cache tree, resolve-undo, untracked cache, fsmonitor
/// and others) are skipped. A split index (`link` extension) is merged with
/// its shared index by `GitRepository`, which knows where that file lives.
public struct GitIndex: Sendable {
    public var version: Int
    /// Entries sorted by path (byte order), then stage.
    public var entries: [GitIndexEntry]
    /// True when the index contains sparse-directory entries.
    public var isSparse: Bool

    /// The index file's modification time; entries modified at or after it are
    /// "racily clean" and must be compared by content.
    var timestamp: GitIndexTime?
    /// For a split index: the id of the shared index (`sharedindex.<id>`) this one patches.
    var sharedIndexID: GitObjectID?
    /// Raw EWAH bitmaps of the link extension, decoded once the shared index size is known.
    private var linkBitmaps: Data?

    /// An empty index, as in a repository where nothing has been staged.
    public init() {
        version = 2
        entries = []
        isSparse = false
    }

    /// Parses index file content.
    public init(data: Data) throws {
        var version = 0
        var entries: [GitIndexEntry] = []
        var isSparse = false
        var linkID: GitObjectID?
        var linkBitmaps: Data?
        try data.withUnsafeBytes { bytes in
            let checksumLength = GitObjectID.byteCount
            guard bytes.count >= 12 + checksumLength, bytes.bigEndianUInt32(at: 0) == 0x4449_5243 else {
                throw GitError.corrupt("not an index file")
            }
            version = Int(bytes.bigEndianUInt32(at: 4))
            guard (2...4).contains(version) else { throw GitError.unsupported("index version \(version)") }
            let count = Int(bytes.bigEndianUInt32(at: 8))
            let end = bytes.count - checksumLength
            var offset = 12
            var previousPath: [UInt8] = []
            entries.reserveCapacity(min(count, end / 62))
            for _ in 0..<count {
                let entry = try Self.parseEntry(bytes, at: &offset, end: end, version: version, previousPath: &previousPath)
                entries.append(entry)
            }
            while offset + 8 <= end {
                let signature = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + 4)])
                let size = Int(bytes.bigEndianUInt32(at: offset + 4))
                let start = offset + 8
                guard size <= end - start else { throw GitError.corrupt("index extension runs past the end") }
                switch String(decoding: signature, as: UTF8.self) {
                case "link":
                    guard size >= GitObjectID.byteCount else { throw GitError.corrupt("short link extension") }
                    linkID = GitObjectID(raw: bytes, at: start)
                    linkBitmaps = Data(bytes[(start + GitObjectID.byteCount)..<(start + size)])
                case "sdir":
                    isSparse = true
                default:
                    // Lowercase signatures mark extensions a reader must understand.
                    guard ASCII.isUpper(signature[0]) else {
                        throw GitError.unsupported("index extension \(String(decoding: signature, as: UTF8.self))")
                    }
                }
                offset = start + size
            }
        }
        self.version = version
        self.entries = entries
        self.isSparse = isSparse
        if let linkID, !linkID.isZero {
            sharedIndexID = linkID
            self.linkBitmaps = linkBitmaps
        } else if entries.contains(where: { $0.path.isEmpty }) {
            throw GitError.corrupt("index entry without a path")
        }
    }

    /// Reads and parses an index file, returning an empty index when the file does not exist.
    public static func read(contentsOf url: URL) throws -> GitIndex {
        guard let data = try GitFile.readIfExists(url) else { return GitIndex() }
        var index = try GitIndex(data: data)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            index.timestamp = GitIndexTime(
                seconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec),
                nanoseconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec)
            )
        }
        return index
    }

    /// The entry for `path` at `stage`, found by binary search.
    public func entry(atPath path: String, stage: Int = 0) -> GitIndexEntry? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            let candidate = entries[middle]
            if candidate.path == path, candidate.stage == stage { return candidate }
            if candidate.path.precedesInByteOrder(path) || (candidate.path == path && candidate.stage < stage) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return nil
    }

    // MARK: Entries

    private static func parseEntry(
        _ bytes: UnsafeRawBufferPointer,
        at offset: inout Int,
        end: Int,
        version: Int,
        previousPath: inout [UInt8]
    ) throws -> GitIndexEntry {
        let fixedLength = 62
        guard offset <= end - fixedLength else { throw GitError.corrupt("truncated index entry") }
        let flags = bytes.bigEndianUInt16(at: offset + 60)
        var nameStart = offset + fixedLength
        var extendedFlags: UInt16 = 0
        if flags & 0x4000 != 0 {
            guard version >= 3, nameStart + 2 <= end else { throw GitError.corrupt("bad extended index flags") }
            extendedFlags = bytes.bigEndianUInt16(at: nameStart)
            guard extendedFlags & ~0x6000 == 0 else { throw GitError.unsupported("index entry flags \(extendedFlags)") }
            nameStart += 2
        }
        let nameLength = Int(flags & 0x0FFF)
        let path: [UInt8]
        let nextOffset: Int
        if version == 4 {
            var cursor = nameStart
            let strip = try GitVarint.readOffsetEncoding(bytes, at: &cursor)
            guard strip <= previousPath.count, let nul = bytes.firstIndex(of: ASCII.nul, from: cursor), nul < end else {
                throw GitError.corrupt("bad path in index entry")
            }
            path = Array(previousPath.prefix(previousPath.count - strip)) + bytes[cursor..<nul]
            nextOffset = nul + 1
        } else {
            let nameEnd: Int
            if nameLength < 0x0FFF {
                nameEnd = nameStart + nameLength
                guard nameEnd < end else { throw GitError.corrupt("truncated index path") }
            } else {
                guard let nul = bytes.firstIndex(of: ASCII.nul, from: nameStart), nul < end else {
                    throw GitError.corrupt("truncated index path")
                }
                nameEnd = nul
            }
            path = Array(bytes[nameStart..<nameEnd])
            // Entries are padded with 1-8 NUL bytes to a multiple of eight.
            nextOffset = offset + ((nameStart - offset + path.count + 8) & ~7)
            guard nextOffset <= end else { throw GitError.corrupt("truncated index entry") }
        }
        let mode = GitFileMode(rawValue: bytes.bigEndianUInt32(at: offset + 24))
        guard Self.isSafePath(path, allowTrailingSlash: mode.isTree) else {
            throw GitError.corrupt("unsafe path in index: \(String(decoding: path, as: UTF8.self))")
        }
        let entry = GitIndexEntry(
            path: String(decoding: path, as: UTF8.self),
            mode: mode,
            id: GitObjectID(raw: bytes, at: offset + 40),
            stage: Int(flags >> 12) & 0x3,
            size: bytes.bigEndianUInt32(at: offset + 36),
            modificationTime: GitIndexTime(seconds: bytes.bigEndianUInt32(at: offset + 8), nanoseconds: bytes.bigEndianUInt32(at: offset + 12)),
            statusChangeTime: GitIndexTime(seconds: bytes.bigEndianUInt32(at: offset), nanoseconds: bytes.bigEndianUInt32(at: offset + 4)),
            device: bytes.bigEndianUInt32(at: offset + 16),
            inode: bytes.bigEndianUInt32(at: offset + 20),
            userID: bytes.bigEndianUInt32(at: offset + 28),
            groupID: bytes.bigEndianUInt32(at: offset + 32),
            assumeValid: flags & 0x8000 != 0,
            skipWorktree: extendedFlags & 0x4000 != 0,
            intentToAdd: extendedFlags & 0x2000 != 0
        )
        previousPath = path
        offset = nextOffset
        return entry
    }

    /// Rejects paths that would escape the work tree or touch `.git`, so a
    /// hostile index cannot make status read files elsewhere. A split index
    /// stores replacement entries with empty paths, which are allowed here.
    static func isSafePath(_ path: [UInt8], allowTrailingSlash: Bool) -> Bool {
        if path.isEmpty { return true }
        var components = path.split(separator: ASCII.slash, omittingEmptySubsequences: false)
        if allowTrailingSlash, components.count > 1, components.last?.isEmpty == true { components.removeLast() }
        for component in components {
            if component.isEmpty { return false }
            if component.elementsEqual([UInt8(ascii: ".")]) || component.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")]) {
                return false
            }
            if ASCII.equal(component, Array(".git".utf8), ignoringCase: true) { return false }
        }
        return true
    }

    // MARK: Split index

    /// Applies this split index to the shared index it links to. Replacement
    /// entries patch shared entries in place, deleted ones are dropped, and the
    /// remaining entries are added on top.
    func merged(withShared shared: GitIndex) throws -> GitIndex {
        guard sharedIndexID != nil else { return self }
        let limit = shared.entries.count
        var deletions: [Int] = []
        var replacements: [Int] = []
        if let linkBitmaps, !linkBitmaps.isEmpty {
            try linkBitmaps.withUnsafeBytes { bytes in
                var offset = 0
                deletions = try EWAHBitmap.setBits(bytes, at: &offset, limit: limit)
                replacements = try EWAHBitmap.setBits(bytes, at: &offset, limit: limit)
                guard offset == bytes.count else { throw GitError.corrupt("garbage after link extension") }
            }
        }
        var base = shared.entries
        var used = 0
        for position in replacements {
            guard used < entries.count, entries[used].path.isEmpty else { throw GitError.corrupt("bad split index replacement") }
            var replacement = entries[used]
            replacement.path = base[position].path
            base[position] = replacement
            used += 1
        }
        let deleted = Set(deletions)
        var result = base.enumerated().filter { !deleted.contains($0.offset) }.map(\.element)
        for addition in entries[used...] {
            guard !addition.path.isEmpty else { throw GitError.corrupt("split index entry without a path") }
            // A stage-0 entry replaces every stage of its path; others replace their own stage.
            result.removeAll { $0.path == addition.path && (addition.stage == 0 || $0.stage == addition.stage) }
            result.append(addition)
        }
        result.sort { lhs, rhs in
            lhs.path == rhs.path ? lhs.stage < rhs.stage : lhs.path.precedesInByteOrder(rhs.path)
        }
        var index = self
        index.entries = result
        index.isSparse = isSparse || shared.isSparse
        index.sharedIndexID = nil
        index.linkBitmaps = nil
        return index
    }
}

/// Git's compressed bitmaps ("EWAH"), used by the split index.
enum EWAHBitmap {
    /// Decodes one bitmap at `offset` and returns the positions of its set bits,
    /// each of which must be below `limit`.
    static func setBits(_ bytes: UnsafeRawBufferPointer, at offset: inout Int, limit: Int) throws -> [Int] {
        guard bytes.contains(offset: offset, count: 8) else { throw GitError.corrupt("truncated bitmap") }
        let wordCount = Int(bytes.bigEndianUInt32(at: offset + 4))
        offset += 8
        guard wordCount <= (bytes.count - offset) / 8, bytes.contains(offset: offset + wordCount * 8, count: 4) else {
            throw GitError.corrupt("truncated bitmap")
        }
        let words = (0..<wordCount).map { bytes.bigEndianUInt64(at: offset + $0 * 8) }
        offset += wordCount * 8 + 4
        var positions: [Int] = []
        var position = 0
        var pointer = 0
        while pointer < words.count {
            // A marker word: a run of identical words, then some literal words.
            let marker = words[pointer]
            let runLength = Int((marker >> 1) & 0xFFFF_FFFF) * 64
            let literalCount = Int(marker >> 33)
            if marker & 1 == 1 {
                guard runLength <= limit - position else { throw GitError.corrupt("bitmap bit out of range") }
                positions.append(contentsOf: position..<(position + runLength))
            }
            position += runLength
            pointer += 1
            for _ in 0..<literalCount {
                guard pointer < words.count else { throw GitError.corrupt("truncated bitmap") }
                let literal = words[pointer]
                for bit in 0..<64 where literal >> UInt64(bit) & 1 == 1 {
                    guard position + bit < limit else { throw GitError.corrupt("bitmap bit out of range") }
                    positions.append(position + bit)
                }
                position += 64
                pointer += 1
            }
        }
        return positions
    }
}
