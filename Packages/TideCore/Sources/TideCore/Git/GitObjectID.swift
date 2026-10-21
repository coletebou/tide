import CryptoKit
import Foundation

/// A SHA-1 object name, the 20-byte id git gives every commit, tree, blob and tag.
///
/// Ordering is byte order, which is the order git uses in pack indexes and trees.
public struct GitObjectID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Bytes 0-7, 8-15 and 16-19 of the id, big-endian, so integer order is byte order.
    private let high: UInt64
    private let middle: UInt64
    private let low: UInt32

    /// Number of bytes in a SHA-1 object id.
    public static let byteCount = 20

    /// The id of the empty blob, which `git add -N` records for intent-to-add entries.
    public static let emptyBlob = GitObjectID(hex: "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")!

    /// The id of the empty tree.
    public static let emptyTree = GitObjectID(hex: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")!

    /// Reads 20 raw bytes starting at `offset`. The caller guarantees the bytes exist.
    init(raw bytes: UnsafeRawBufferPointer, at offset: Int = 0) {
        high = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        middle = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
        low = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self))
    }

    /// Creates an id from exactly 20 raw bytes.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        let array = Array(bytes)
        self = array.withUnsafeBytes { GitObjectID(raw: $0) }
    }

    /// Parses 40 hexadecimal digits in either case.
    public init?(hex: some StringProtocol) {
        self.init(hexUTF8: hex.utf8)
    }

    /// Parses 40 hexadecimal digits given as UTF-8 bytes.
    init?(hexUTF8 digits: some Collection<UInt8>) {
        guard digits.count == Self.byteCount * 2 else { return nil }
        var raw = [UInt8](repeating: 0, count: Self.byteCount)
        var index = digits.startIndex
        for position in 0..<Self.byteCount {
            guard let upper = Self.nibble(digits[index]) else { return nil }
            index = digits.index(after: index)
            guard let lower = Self.nibble(digits[index]) else { return nil }
            index = digits.index(after: index)
            raw[position] = upper << 4 | lower
        }
        self = raw.withUnsafeBytes { GitObjectID(raw: $0) }
    }

    /// The 20 raw bytes of the id.
    public var bytes: [UInt8] {
        var raw = [UInt8](repeating: 0, count: Self.byteCount)
        raw.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(of: high.bigEndian, toByteOffset: 0, as: UInt64.self)
            buffer.storeBytes(of: middle.bigEndian, toByteOffset: 8, as: UInt64.self)
            buffer.storeBytes(of: low.bigEndian, toByteOffset: 16, as: UInt32.self)
        }
        return raw
    }

    /// The first byte, which selects the pack index fan-out bucket and the loose object directory.
    var firstByte: UInt8 { UInt8(truncatingIfNeeded: high >> 56) }

    /// True for the all-zero id, which git uses as a placeholder.
    var isZero: Bool { high == 0 && middle == 0 && low == 0 }

    /// Lowercase hexadecimal form, as git prints it.
    public var hex: String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(Self.byteCount * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The first `length` hex digits, the abbreviated form git shows in logs.
    public func abbreviated(_ length: Int = 7) -> String {
        String(hex.prefix(max(0, length)))
    }

    public var description: String { hex }

    public static func < (lhs: GitObjectID, rhs: GitObjectID) -> Bool {
        if lhs.high != rhs.high { return lhs.high < rhs.high }
        if lhs.middle != rhs.middle { return lhs.middle < rhs.middle }
        return lhs.low < rhs.low
    }

    /// Compares this id with 20 raw bytes at `offset`, returning <0, 0 or >0.
    func compare(toBytes bytes: UnsafeRawBufferPointer, at offset: Int) -> Int {
        let otherHigh = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        if high != otherHigh { return high < otherHigh ? -1 : 1 }
        let otherMiddle = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
        if middle != otherMiddle { return middle < otherMiddle ? -1 : 1 }
        let otherLow = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self))
        if low != otherLow { return low < otherLow ? -1 : 1 }
        return 0
    }

    /// The id git assigns to an object: the SHA-1 of `"<type> <size>\0"` followed by the content.
    public static func hash(_ type: GitObjectType, _ content: Data) -> GitObjectID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("\(type.rawValue) \(content.count)\0".utf8))
        hasher.update(data: content)
        return GitObjectID(digest: hasher.finalize())
    }

    init(digest: Insecure.SHA1.Digest) {
        self = digest.withUnsafeBytes { GitObjectID(raw: $0) }
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// The four kinds of objects in a git object database.
public enum GitObjectType: String, Sendable, CaseIterable {
    case commit
    case tree
    case blob
    case tag

    /// The type numbers used in pack entry headers.
    init?(packTypeNumber: Int) {
        switch packTypeNumber {
        case 1: self = .commit
        case 2: self = .tree
        case 3: self = .blob
        case 4: self = .tag
        default: return nil
        }
    }

    init?(name: some Collection<UInt8>) {
        switch String(decoding: name, as: UTF8.self) {
        case "commit": self = .commit
        case "tree": self = .tree
        case "blob": self = .blob
        case "tag": self = .tag
        default: return nil
        }
    }
}

/// A file mode as git records it in trees and the index.
///
/// Git only stores five modes: directories (trees), regular files, executable
/// files, symbolic links and gitlinks (submodule commits).
public struct GitFileMode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// A subdirectory, stored as a tree.
    public static let tree = GitFileMode(rawValue: 0o040000)
    /// A regular, non-executable file.
    public static let regular = GitFileMode(rawValue: 0o100644)
    /// A regular file with the executable bit set.
    public static let executable = GitFileMode(rawValue: 0o100755)
    /// A symbolic link; the blob holds the link target.
    public static let symlink = GitFileMode(rawValue: 0o120000)
    /// A submodule; the id is a commit in another repository.
    public static let gitlink = GitFileMode(rawValue: 0o160000)

    static let typeMask: UInt32 = 0o170000

    /// The file-type bits (`S_IFMT`), which tell regular files, links, gitlinks and trees apart.
    var typeBits: UInt32 { rawValue & Self.typeMask }

    public var isTree: Bool { typeBits == 0o040000 }
    public var isRegularFile: Bool { typeBits == 0o100000 }
    public var isSymlink: Bool { typeBits == 0o120000 }
    public var isGitlink: Bool { typeBits == 0o160000 }
    public var isExecutable: Bool { isRegularFile && rawValue & 0o100 != 0 }

    /// The six-digit octal form git prints, such as `100644`.
    public var description: String {
        let digits = String(rawValue, radix: 8)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// Normalizes a mode the way git does when it reads trees: any regular file
    /// becomes 100644 or 100755 depending on the owner's execute bit.
    init(canonicalizing raw: UInt32) {
        switch raw & Self.typeMask {
        case 0o040000: self = .tree
        case 0o120000: self = .symlink
        case 0o160000: self = .gitlink
        case 0o100000: self = raw & 0o100 != 0 ? .executable : .regular
        default: self = GitFileMode(rawValue: raw)
        }
    }
}

/// Errors from reading a repository.
public enum GitError: Error, Equatable, Sendable, CustomStringConvertible {
    /// An object, reference or file the operation needs does not exist.
    case notFound(String)
    /// Data on disk does not follow git's formats.
    case corrupt(String)
    /// The repository uses a feature this reader does not implement.
    case unsupported(String)
    /// The file system refused a read.
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let detail): return "not found: \(detail)"
        case .corrupt(let detail): return "corrupt repository data: \(detail)"
        case .unsupported(let detail): return "unsupported: \(detail)"
        case .io(let detail): return "I/O error: \(detail)"
        }
    }
}
