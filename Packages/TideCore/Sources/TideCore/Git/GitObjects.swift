import Foundation

/// An object's type and raw content, without the `"<type> <size>\0"` header.
public struct GitObject: Equatable, Sendable {
    public var type: GitObjectType
    public var data: Data

    public init(type: GitObjectType, data: Data) {
        self.type = type
        self.data = data
    }
}

/// A person and time from a commit's `author` or `committer` line, or a tag's `tagger` line.
public struct GitSignature: Equatable, Sendable {
    public var name: String
    public var email: String
    /// Seconds since 1970, as git records them.
    public var time: Int64
    /// The recorded UTC offset in minutes; `+0130` is 90.
    public var timeZoneOffset: Int

    public init(name: String, email: String, time: Int64, timeZoneOffset: Int) {
        self.name = name
        self.email = email
        self.time = time
        self.timeZoneOffset = timeZoneOffset
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }

    /// Parses `Name <email> 1700000000 +0100`. Like git, the name ends at the
    /// first `<`, the email at the next `>`, and the time follows the last `>`.
    init?(line: some Collection<UInt8>) {
        let bytes = Array(line)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "<")),
              let close = bytes[open...].firstIndex(of: UInt8(ascii: ">")),
              let last = bytes.lastIndex(of: UInt8(ascii: ">")) else { return nil }
        var nameEnd = open
        while nameEnd > 0, bytes[nameEnd - 1] == ASCII.space { nameEnd -= 1 }
        name = String(decoding: bytes[..<nameEnd], as: UTF8.self)
        email = String(decoding: bytes[(open + 1)..<close], as: UTF8.self)

        let fields = bytes[(last + 1)...].split(separator: ASCII.space)
        if let first = fields.first, let seconds = Int64(String(decoding: first, as: UTF8.self)) {
            time = seconds
        } else {
            time = 0
        }
        timeZoneOffset = 0
        if fields.count > 1 {
            let zone = Array(fields[1])
            if zone.count == 5, zone[0] == UInt8(ascii: "+") || zone[0] == UInt8(ascii: "-"),
               let value = Int(String(decoding: zone[1...], as: UTF8.self)) {
                let minutes = (value / 100) * 60 + value % 100
                timeZoneOffset = zone[0] == UInt8(ascii: "-") ? -minutes : minutes
            }
        }
    }
}

/// A parsed commit object.
public struct GitCommit: Equatable, Sendable {
    public var id: GitObjectID
    public var tree: GitObjectID
    /// Parent commits in order; the first parent is the branch that was merged into.
    public var parents: [GitObjectID]
    public var author: GitSignature?
    public var committer: GitSignature?
    /// The full message, including the summary line.
    public var message: String

    /// The first line of the message.
    public var summary: String {
        String(message.prefix { $0 != "\n" })
    }

    /// Parses commit content (the object data without its header).
    public init(id: GitObjectID, data: Data) throws {
        self.id = id
        var tree: GitObjectID?
        var parents: [GitObjectID] = []
        var author: GitSignature?
        var committer: GitSignature?
        var encoding: String?
        let headers = GitHeaderParser(data)
        for (key, value) in headers.fields {
            switch key {
            case "tree": tree = GitObjectID(hexUTF8: value)
            case "parent":
                guard let parent = GitObjectID(hexUTF8: value) else { throw GitError.corrupt("bad parent in commit \(id)") }
                parents.append(parent)
            case "author": author = GitSignature(line: value)
            case "committer": committer = GitSignature(line: value)
            case "encoding": encoding = String(decoding: value, as: UTF8.self)
            default: break
            }
        }
        guard let tree else { throw GitError.corrupt("commit \(id) has no tree") }
        self.tree = tree
        self.parents = parents
        self.author = author
        self.committer = committer
        message = GitHeaderParser.decode(headers.body, encoding: encoding)
    }
}

/// One entry of a tree object.
public struct GitTreeEntry: Equatable, Sendable {
    public var name: String
    public var mode: GitFileMode
    public var id: GitObjectID

    public init(name: String, mode: GitFileMode, id: GitObjectID) {
        self.name = name
        self.mode = mode
        self.id = id
    }
}

/// A parsed tree object: one directory level.
public struct GitTree: Equatable, Sendable {
    public var id: GitObjectID
    /// Entries in git's tree order.
    public var entries: [GitTreeEntry]

    /// Parses tree content: repeated `<octal mode> <name>\0<20-byte id>`.
    public init(id: GitObjectID, data: Data) throws {
        self.id = id
        var entries: [GitTreeEntry] = []
        try GitTree.forEachEntry(in: data) { nameBytes, mode, entryID in
            entries.append(GitTreeEntry(name: String(decoding: nameBytes, as: UTF8.self), mode: mode, id: entryID))
        }
        self.entries = entries
    }

    /// The entry called `name`, if any.
    public func entry(named name: String) -> GitTreeEntry? {
        entries.first { $0.name == name }
    }

    /// Walks tree content without building `String`s for names.
    static func forEachEntry(in data: Data, _ body: (UnsafeRawBufferPointer, GitFileMode, GitObjectID) throws -> Void) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                var mode: UInt32 = 0
                var digits = 0
                while offset < bytes.count, bytes[offset] != ASCII.space {
                    let digit = bytes[offset]
                    guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "7"), digits < 7 else {
                        throw GitError.corrupt("bad mode in tree")
                    }
                    mode = mode << 3 | UInt32(digit - UInt8(ascii: "0"))
                    digits += 1
                    offset += 1
                }
                guard digits > 0, offset < bytes.count else { throw GitError.corrupt("truncated tree entry") }
                offset += 1
                guard let nul = bytes.firstIndex(of: ASCII.nul, from: offset), nul > offset,
                      bytes.contains(offset: nul + 1, count: GitObjectID.byteCount) else {
                    throw GitError.corrupt("truncated tree entry")
                }
                let name = UnsafeRawBufferPointer(rebasing: bytes[offset..<nul])
                let entryID = GitObjectID(raw: bytes, at: nul + 1)
                try body(name, GitFileMode(canonicalizing: mode), entryID)
                offset = nul + 1 + GitObjectID.byteCount
            }
        }
    }
}

/// A parsed annotated tag object.
public struct GitTag: Equatable, Sendable {
    public var id: GitObjectID
    /// The tagged object, usually a commit.
    public var target: GitObjectID
    public var targetType: GitObjectType
    public var name: String
    public var tagger: GitSignature?
    public var message: String

    /// Parses tag content (the object data without its header).
    public init(id: GitObjectID, data: Data) throws {
        self.id = id
        var target: GitObjectID?
        var targetType: GitObjectType?
        var name = ""
        var tagger: GitSignature?
        let headers = GitHeaderParser(data)
        for (key, value) in headers.fields {
            switch key {
            case "object": target = GitObjectID(hexUTF8: value)
            case "type": targetType = GitObjectType(name: value)
            case "tag": name = String(decoding: value, as: UTF8.self)
            case "tagger": tagger = GitSignature(line: value)
            default: break
            }
        }
        guard let target, let targetType else { throw GitError.corrupt("tag \(id) has no target") }
        self.target = target
        self.targetType = targetType
        self.name = name
        self.tagger = tagger
        message = GitHeaderParser.decode(headers.body, encoding: nil)
    }
}

/// Splits commit and tag objects into header fields and a message body.
///
/// Headers run until the first empty line. A line that starts with a space
/// continues the previous header (as in `gpgsig`).
struct GitHeaderParser {
    private(set) var fields: [(String, ArraySlice<UInt8>)] = []
    private(set) var body: ArraySlice<UInt8> = []

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let end = bytes[offset...].firstIndex(of: ASCII.lf) ?? bytes.count
            if end == offset {
                body = bytes[min(end + 1, bytes.count)...]
                return
            }
            let line = bytes[offset..<end]
            if line.first == ASCII.space {
                // Continuation lines only matter for multi-line headers we ignore.
            } else if let space = line.firstIndex(of: ASCII.space) {
                fields.append((String(decoding: line[..<space], as: UTF8.self), line[(space + 1)...]))
            } else {
                fields.append((String(decoding: line, as: UTF8.self), []))
            }
            offset = end + 1
        }
    }

    /// Decodes a message, honoring a commit's `encoding` header when it names a
    /// legacy encoding.
    static func decode(_ bytes: ArraySlice<UInt8>, encoding: String?) -> String {
        if let encoding, encoding.lowercased() != "utf-8", encoding.lowercased() != "utf8" {
            let converted = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
            if converted != kCFStringEncodingInvalidId {
                let foundation = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
                if let text = String(data: Data(bytes), encoding: foundation) { return text }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
