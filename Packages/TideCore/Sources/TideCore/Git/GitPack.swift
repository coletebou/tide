import Foundation

/// One pack: a `.pack` file of compressed objects plus the `.idx` that maps
/// object ids to offsets in it.
///
/// Both files are memory-mapped and never change after loading, so a pack can
/// be shared between threads.
final class GitPack: @unchecked Sendable {
    let packURL: URL
    let objectCount: Int
    private let index: MappedFile
    private let pack: MappedFile
    private let indexVersion: Int
    /// Byte offsets of the tables inside the index file.
    private let fanoutOffset: Int
    private let namesOffset: Int
    private let offsetsOffset: Int
    private let largeOffsetsOffset: Int
    private let largeOffsetCount: Int

    /// What a pack entry header says about the object stored at an offset.
    enum Entry {
        case object(GitObjectType)
        /// A delta against the object at an earlier offset in this pack.
        case offsetDelta(baseOffset: Int)
        /// A delta against an object named by id, usually in this pack.
        case referenceDelta(base: GitObjectID)
    }

    struct EntryHeader {
        var entry: Entry
        /// Inflated size: of the object itself, or of the delta data.
        var size: Int
        /// Where the zlib stream starts.
        var dataOffset: Int
    }

    init(indexURL: URL) throws {
        packURL = indexURL.deletingPathExtension().appendingPathExtension("pack")
        index = try MappedFile(url: indexURL)
        pack = try MappedFile(url: packURL)

        let idx = index.bytes
        let trailer = 2 * GitObjectID.byteCount
        if idx.count >= 8, idx.bigEndianUInt32(at: 0) == 0xFF74_4F63 {
            indexVersion = Int(idx.bigEndianUInt32(at: 4))
            guard indexVersion == 2 else { throw GitError.unsupported("pack index version \(indexVersion)") }
            fanoutOffset = 8
            guard idx.contains(offset: fanoutOffset, count: 256 * 4) else { throw GitError.corrupt("truncated pack index") }
            objectCount = Int(idx.bigEndianUInt32(at: fanoutOffset + 255 * 4))
            namesOffset = fanoutOffset + 256 * 4
            offsetsOffset = namesOffset + objectCount * (GitObjectID.byteCount + 4)
            largeOffsetsOffset = offsetsOffset + objectCount * 4
            let remaining = idx.count - largeOffsetsOffset - trailer
            guard remaining >= 0, remaining % 8 == 0 else { throw GitError.corrupt("bad pack index size") }
            largeOffsetCount = remaining / 8
        } else {
            // Version 1: the fan-out table, then (4-byte offset, id) pairs.
            indexVersion = 1
            fanoutOffset = 0
            guard idx.contains(offset: 0, count: 256 * 4) else { throw GitError.corrupt("truncated pack index") }
            objectCount = Int(idx.bigEndianUInt32(at: 255 * 4))
            namesOffset = 256 * 4
            offsetsOffset = namesOffset
            largeOffsetsOffset = 0
            largeOffsetCount = 0
            guard idx.count == namesOffset + objectCount * (GitObjectID.byteCount + 4) + trailer else {
                throw GitError.corrupt("bad pack index size")
            }
        }

        let packBytes = pack.bytes
        guard packBytes.count >= 12 + GitObjectID.byteCount, packBytes.bigEndianUInt32(at: 0) == 0x5041_434B else {
            throw GitError.corrupt("\(packURL.lastPathComponent) is not a pack")
        }
        let version = packBytes.bigEndianUInt32(at: 4)
        guard version == 2 || version == 3 else { throw GitError.unsupported("pack version \(version)") }
        guard Int(packBytes.bigEndianUInt32(at: 8)) == objectCount else {
            throw GitError.corrupt("\(packURL.lastPathComponent) does not match its index")
        }
    }

    /// The pack offset of `id`, or nil when the pack does not contain it.
    func offset(of id: GitObjectID) -> Int? {
        let idx = index.bytes
        let bucket = Int(id.firstByte)
        var low = bucket == 0 ? 0 : Int(idx.bigEndianUInt32(at: fanoutOffset + (bucket - 1) * 4))
        var high = Int(idx.bigEndianUInt32(at: fanoutOffset + bucket * 4))
        guard low <= high, high <= objectCount else { return nil }
        let stride = indexVersion == 2 ? GitObjectID.byteCount : GitObjectID.byteCount + 4
        let nameBias = indexVersion == 2 ? 0 : 4
        while low < high {
            let middle = (low + high) / 2
            let comparison = id.compare(toBytes: idx, at: namesOffset + middle * stride + nameBias)
            if comparison == 0 { return objectOffset(at: middle) }
            if comparison < 0 { high = middle } else { low = middle + 1 }
        }
        return nil
    }

    private func objectOffset(at position: Int) -> Int? {
        let idx = index.bytes
        if indexVersion == 1 {
            return Int(idx.bigEndianUInt32(at: namesOffset + position * (GitObjectID.byteCount + 4)))
        }
        let small = idx.bigEndianUInt32(at: offsetsOffset + position * 4)
        guard small & 0x8000_0000 != 0 else { return Int(small) }
        let large = Int(small & 0x7FFF_FFFF)
        guard large < largeOffsetCount else { return nil }
        let value = idx.bigEndianUInt64(at: largeOffsetsOffset + large * 8)
        return value < UInt64(Int.max) ? Int(value) : nil
    }

    /// Parses the variable-length entry header at `offset`.
    func entryHeader(at offset: Int) throws -> EntryHeader {
        let bytes = pack.bytes
        let dataEnd = bytes.count - GitObjectID.byteCount
        guard offset >= 12, offset < dataEnd else { throw GitError.corrupt("pack offset \(offset) out of range") }
        var position = offset
        var byte = bytes[position]
        position += 1
        let typeNumber = Int(byte >> 4) & 0x07
        var size = Int(byte & 0x0F)
        var shift = 4
        while byte & 0x80 != 0 {
            guard position < dataEnd, shift < 60 else { throw GitError.corrupt("bad pack entry header") }
            byte = bytes[position]
            position += 1
            size |= Int(byte & 0x7F) << shift
            shift += 7
        }
        switch typeNumber {
        case 6:
            var cursor = position
            let distance = try GitVarint.readOffsetEncoding(bytes, at: &cursor)
            guard distance > 0, distance < offset else { throw GitError.corrupt("bad delta base offset") }
            return EntryHeader(entry: .offsetDelta(baseOffset: offset - distance), size: size, dataOffset: cursor)
        case 7:
            guard bytes.contains(offset: position, count: GitObjectID.byteCount) else { throw GitError.corrupt("truncated delta base") }
            let base = GitObjectID(raw: bytes, at: position)
            return EntryHeader(entry: .referenceDelta(base: base), size: size, dataOffset: position + GitObjectID.byteCount)
        default:
            guard let type = GitObjectType(packTypeNumber: typeNumber) else {
                throw GitError.corrupt("unknown pack object type \(typeNumber)")
            }
            return EntryHeader(entry: .object(type), size: size, dataOffset: position)
        }
    }

    /// Inflates the zlib stream of an entry.
    func inflate(_ header: EntryHeader) throws -> Data {
        let dataEnd = pack.bytes.count - GitObjectID.byteCount
        guard header.dataOffset < dataEnd else { throw GitError.corrupt("pack entry runs past the end") }
        let stream = UnsafeRawBufferPointer(rebasing: pack.bytes[header.dataOffset..<dataEnd])
        return try Inflate.zlib(stream, expectedSize: header.size)
    }
}

/// Git's delta format: a base size, a result size, then copy and insert instructions.
enum GitDelta {
    /// The largest result accepted. Git stores objects above
    /// `core.bigFileThreshold` (512 MiB by default) without delta compression,
    /// so a delta that rebuilds more did not come from git; repeated copies of
    /// a small base could otherwise demand any amount of memory.
    static let maximumResultSize = 512 << 20

    /// Rebuilds an object from its delta base and delta data.
    static func apply(_ delta: Data, to base: Data) throws -> Data {
        try delta.withUnsafeBytes { deltaBytes in
            try base.withUnsafeBytes { baseBytes in
                var position = 0
                let baseSize = try GitVarint.readLittleEndian(deltaBytes, at: &position)
                guard baseSize == baseBytes.count else { throw GitError.corrupt("delta base size mismatch") }
                let resultSize = try GitVarint.readLittleEndian(deltaBytes, at: &position)
                guard resultSize <= maximumResultSize else {
                    throw GitError.unsupported("a delta result of \(resultSize) bytes, above core.bigFileThreshold's 512 MiB default")
                }
                // Each instruction byte yields at most a whole base or 127 inserted bytes.
                let bound = (deltaBytes.count - position).multipliedReportingOverflow(by: max(baseBytes.count, 0x7F))
                guard bound.overflow || resultSize <= bound.partialValue else {
                    throw GitError.corrupt("delta result size is impossible")
                }
                var result = Data(count: resultSize)
                try result.withUnsafeMutableBytes { output in
                    var written = 0
                    while position < deltaBytes.count {
                        let instruction = deltaBytes[position]
                        position += 1
                        if instruction & 0x80 != 0 {
                            var copyOffset = 0
                            var copySize = 0
                            for bit in 0..<7 where instruction & (1 << bit) != 0 {
                                guard position < deltaBytes.count else { throw GitError.corrupt("truncated delta copy") }
                                let value = Int(deltaBytes[position])
                                position += 1
                                if bit < 4 {
                                    copyOffset |= value << (8 * bit)
                                } else {
                                    copySize |= value << (8 * (bit - 4))
                                }
                            }
                            if copySize == 0 { copySize = 0x10000 }
                            guard copyOffset <= baseBytes.count - copySize, copySize <= baseBytes.count,
                                  copySize <= resultSize - written else {
                                throw GitError.corrupt("delta copy out of range")
                            }
                            output.baseAddress!.advanced(by: written)
                                .copyMemory(from: baseBytes.baseAddress!.advanced(by: copyOffset), byteCount: copySize)
                            written += copySize
                        } else if instruction != 0 {
                            let count = Int(instruction)
                            guard count <= deltaBytes.count - position, count <= resultSize - written else {
                                throw GitError.corrupt("delta insert out of range")
                            }
                            output.baseAddress!.advanced(by: written)
                                .copyMemory(from: deltaBytes.baseAddress!.advanced(by: position), byteCount: count)
                            position += count
                            written += count
                        } else {
                            throw GitError.corrupt("reserved delta instruction")
                        }
                    }
                    guard written == resultSize else { throw GitError.corrupt("delta result is short") }
                }
                return result
            }
        }
    }
}
