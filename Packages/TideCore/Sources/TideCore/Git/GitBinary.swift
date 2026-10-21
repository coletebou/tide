import Foundation

/// A read-only file mapped into memory.
///
/// Git never rewrites pack files or pack indexes in place (it writes new
/// files and deletes old ones, which leaves existing mappings valid), so
/// mapping them is safe and lets lookups touch only the pages they need.
final class MappedFile: @unchecked Sendable {
    /// The file's bytes. Immutable for the lifetime of the object.
    let bytes: UnsafeRawBufferPointer
    private let mapped: Bool

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw GitError.io("cannot open \(url.path)") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw GitError.io("cannot stat \(url.path)") }
        let size = Int(info.st_size)
        guard size > 0 else {
            bytes = UnsafeRawBufferPointer(start: nil, count: 0)
            mapped = false
            return
        }
        if let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), address != MAP_FAILED {
            bytes = UnsafeRawBufferPointer(start: address, count: size)
            mapped = true
            return
        }
        // Some file providers refuse mmap; fall back to reading the file.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16)
        var total = 0
        while total < size {
            let count = read(descriptor, buffer.baseAddress! + total, size - total)
            if count <= 0 { break }
            total += count
        }
        guard total == size else {
            buffer.deallocate()
            throw GitError.io("short read from \(url.path)")
        }
        bytes = UnsafeRawBufferPointer(buffer)
        mapped = false
    }

    deinit {
        guard let base = bytes.baseAddress else { return }
        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: base), bytes.count)
        } else {
            UnsafeMutableRawPointer(mutating: base).deallocate()
        }
    }
}

extension UnsafeRawBufferPointer {
    /// Big-endian 32-bit integer at `offset`. The caller checks bounds.
    @inline(__always)
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    /// Big-endian 16-bit integer at `offset`. The caller checks bounds.
    @inline(__always)
    func bigEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    /// Big-endian 64-bit integer at `offset`. The caller checks bounds.
    @inline(__always)
    func bigEndianUInt64(at offset: Int) -> UInt64 {
        UInt64(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    /// True when `count` bytes starting at `offset` lie inside the buffer.
    @inline(__always)
    func contains(offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= self.count && count <= self.count - offset
    }

    /// The slice from `offset` to the end, or an empty buffer when out of range.
    func suffix(from offset: Int) -> UnsafeRawBufferPointer {
        guard offset >= 0, offset <= count, let base = baseAddress else {
            return UnsafeRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeRawBufferPointer(start: base + offset, count: count - offset)
    }

    /// Index of the first `byte` at or after `offset`, if any.
    func firstIndex(of byte: UInt8, from offset: Int) -> Int? {
        var index = offset
        while index < count {
            if self[index] == byte { return index }
            index += 1
        }
        return nil
    }
}

/// Git's two variable-length integer encodings.
enum GitVarint {
    /// Little-endian base-128, used for the sizes at the start of delta data.
    static func readLittleEndian(_ bytes: UnsafeRawBufferPointer, at offset: inout Int) throws -> Int {
        var value = 0
        var shift = 0
        while true {
            guard offset < bytes.count, shift < 63 else { throw GitError.corrupt("bad delta size") }
            let byte = bytes[offset]
            offset += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    /// The "offset" encoding of OFS_DELTA base offsets and index v4 path
    /// prefixes: big-endian base-128 where each continuation adds one, so no
    /// value has two encodings.
    static func readOffsetEncoding(_ bytes: UnsafeRawBufferPointer, at offset: inout Int) throws -> Int {
        guard offset < bytes.count else { throw GitError.corrupt("truncated offset") }
        var byte = bytes[offset]
        offset += 1
        var value = Int(byte & 0x7F)
        while byte & 0x80 != 0 {
            guard offset < bytes.count, value < Int.max >> 8 else { throw GitError.corrupt("bad offset encoding") }
            byte = bytes[offset]
            offset += 1
            value = ((value + 1) << 7) | Int(byte & 0x7F)
        }
        return value
    }
}

/// ASCII helpers for byte-level parsing.
enum ASCII {
    static let nul: UInt8 = 0
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let slash = UInt8(ascii: "/")
    static let backslash = UInt8(ascii: "\\")

    @inline(__always)
    static func isUpper(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }

    @inline(__always)
    static func isLower(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }

    @inline(__always)
    static func lowercased(_ byte: UInt8) -> UInt8 { isUpper(byte) ? byte | 0x20 : byte }

    @inline(__always)
    static func uppercased(_ byte: UInt8) -> UInt8 { isLower(byte) ? byte & ~0x20 : byte }

    /// Compares two byte sequences, optionally ignoring ASCII case, the way
    /// git's `fspathncmp` does when `core.ignoreCase` is set.
    static func equal(_ lhs: some Collection<UInt8>, _ rhs: some Collection<UInt8>, ignoringCase: Bool) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if !ignoringCase { return lhs.elementsEqual(rhs) }
        return zip(lhs, rhs).allSatisfy { lowercased($0) == lowercased($1) }
    }

    /// Byte-wise lowercase, used as a key for case-insensitive lookups.
    static func lowercased(_ text: String) -> String {
        guard text.utf8.contains(where: isUpper) else { return text }
        return String(decoding: text.utf8.map(lowercased), as: UTF8.self)
    }
}

extension String {
    /// Orders strings by their UTF-8 bytes, the order git uses for paths and refs.
    func precedesInByteOrder(_ other: String) -> Bool {
        utf8.lexicographicallyPrecedes(other.utf8)
    }
}
