import Foundation

/// A parsed git configuration file, such as `.git/config`.
///
/// Section and variable names are case-insensitive; subsection names in the
/// `[section "subsection"]` form are case-sensitive, as in git. Parsing stops at
/// the first malformed line and keeps what came before it, where git would
/// refuse to run. `include` and `includeIf` directives are not followed.
public struct GitConfig: Sendable {
    struct Entry: Sendable {
        var section: String
        var subsection: String?
        var name: String
        /// nil for a bare `name` line, which means boolean true.
        var value: String?
    }

    private(set) var entries: [Entry] = []

    /// An empty configuration.
    public init() {}

    /// Parses configuration text.
    public init(data: Data) {
        var parser = Parser(bytes: [UInt8](data))
        entries = parser.parse()
    }

    /// Reads a configuration file; a missing or unreadable file yields an empty configuration.
    public static func read(contentsOf url: URL) -> GitConfig {
        guard let data = try? GitFile.readIfExists(url) else { return GitConfig() }
        return GitConfig(data: data)
    }

    /// Adds the entries of `other` after this file's, so they take precedence.
    mutating func append(_ other: GitConfig) {
        entries.append(contentsOf: other.entries)
    }

    /// The last value of `key`, written `section.name` or `section.subsection.name`.
    /// A bare `name` line (no `=`) reads as `"true"`.
    public func string(_ key: String) -> String? {
        guard let key = Key(key) else { return nil }
        guard let entry = entries.last(where: key.matches) else { return nil }
        return entry.value ?? "true"
    }

    /// Every value of a multi-valued `key`, in file order.
    public func strings(_ key: String) -> [String] {
        guard let key = Key(key) else { return [] }
        return entries.filter(key.matches).map { $0.value ?? "true" }
    }

    /// The last value of `key` interpreted as a git boolean, or nil when unset or not a boolean.
    public func bool(_ key: String) -> Bool? {
        guard let key = Key(key), let entry = entries.last(where: key.matches) else { return nil }
        guard let value = entry.value else { return true }
        switch value.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off", "": return false
        default: return Int(value).map { $0 != 0 }
        }
    }

    /// The distinct subsection names under `section`, such as remote names under `remote`.
    public func subsections(of section: String) -> [String] {
        let section = section.lowercased()
        var seen = Set<String>()
        var names: [String] = []
        for entry in entries where entry.section == section {
            if let subsection = entry.subsection, seen.insert(subsection).inserted { names.append(subsection) }
        }
        return names
    }

    /// A lookup key split like git's `git_config_parse_key`: the first and last
    /// dots separate section, subsection and name.
    private struct Key {
        var section: String
        var subsection: String?
        var name: String

        init?(_ key: String) {
            guard let first = key.firstIndex(of: "."), let last = key.lastIndex(of: "."), first != key.startIndex else {
                return nil
            }
            section = key[..<first].lowercased()
            name = key[key.index(after: last)...].lowercased()
            subsection = first == last ? nil : String(key[key.index(after: first)..<last])
            if name.isEmpty { return nil }
        }

        func matches(_ entry: Entry) -> Bool {
            entry.name == name && entry.section == section && entry.subsection == subsection
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
        }

        /// Next character with CRLF folded to LF; nil at the end.
        mutating func next() -> UInt8? {
            guard position < bytes.count else { return nil }
            let byte = bytes[position]
            position += 1
            if byte == ASCII.cr, position < bytes.count, bytes[position] == ASCII.lf {
                position += 1
                return ASCII.lf
            }
            return byte
        }

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == ASCII.space || byte == ASCII.tab || byte == ASCII.lf || byte == ASCII.cr
        }

        static func isKeyCharacter(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || ASCII.isUpper(byte) || ASCII.isLower(byte) || byte == UInt8(ascii: "-")
        }

        mutating func parse() -> [Entry] {
            var entries: [Entry] = []
            var section: String?
            var subsection: String?
            var inComment = false
            while let byte = next() {
                if byte == ASCII.lf {
                    inComment = false
                    continue
                }
                if inComment || Self.isSpace(byte) { continue }
                if byte == UInt8(ascii: "#") || byte == UInt8(ascii: ";") {
                    inComment = true
                    continue
                }
                if byte == UInt8(ascii: "[") {
                    guard let header = parseSectionHeader() else { return entries }
                    section = header.section
                    subsection = header.subsection
                    continue
                }
                guard ASCII.isUpper(byte) || ASCII.isLower(byte), let section else { return entries }
                guard let (name, value) = parseVariable(first: byte) else { return entries }
                entries.append(Entry(section: section, subsection: subsection, name: name, value: value))
            }
            return entries
        }

        /// `[name]`, `[name.legacy]` or `[name "subsection"]`, after the `[`.
        mutating func parseSectionHeader() -> (section: String, subsection: String?)? {
            var name: [UInt8] = []
            while let byte = next() {
                if byte == UInt8(ascii: "]") { return finishSection(name, subsection: nil) }
                if Self.isSpace(byte) {
                    if byte == ASCII.lf { return nil }
                    var current = byte
                    while Self.isSpace(current) {
                        if current == ASCII.lf { return nil }
                        guard let following = next() else { return nil }
                        current = following
                    }
                    guard current == UInt8(ascii: "\"") else { return nil }
                    var subsection: [UInt8] = []
                    while true {
                        guard var character = next(), character != ASCII.lf else { return nil }
                        if character == UInt8(ascii: "\"") { break }
                        if character == ASCII.backslash {
                            guard let escaped = next(), escaped != ASCII.lf else { return nil }
                            character = escaped
                        }
                        subsection.append(character)
                    }
                    guard next() == UInt8(ascii: "]") else { return nil }
                    return finishSection(name, subsection: String(decoding: subsection, as: UTF8.self))
                }
                guard Self.isKeyCharacter(byte) || byte == UInt8(ascii: ".") else { return nil }
                name.append(ASCII.lowercased(byte))
            }
            return nil
        }

        private func finishSection(_ name: [UInt8], subsection: String?) -> (section: String, subsection: String?)? {
            guard !name.isEmpty else { return nil }
            let text = String(decoding: name, as: UTF8.self)
            if subsection == nil, let dot = text.firstIndex(of: ".") {
                // Legacy `[section.subsection]`: the whole header is lowercase.
                return (String(text[..<dot]), String(text[text.index(after: dot)...]))
            }
            return (text, subsection)
        }

        /// `name`, `name = value` or `name = "quoted value"`, starting at its first letter.
        mutating func parseVariable(first: UInt8) -> (String, String?)? {
            var name: [UInt8] = [ASCII.lowercased(first)]
            var byte = next()
            while let current = byte, Self.isKeyCharacter(current) {
                name.append(ASCII.lowercased(current))
                byte = next()
            }
            while byte == ASCII.space || byte == ASCII.tab { byte = next() }
            let key = String(decoding: name, as: UTF8.self)
            guard let separator = byte, separator != ASCII.lf else { return (key, nil) }
            if separator == UInt8(ascii: "#") || separator == UInt8(ascii: ";") {
                skipLine()
                return (key, nil)
            }
            guard separator == UInt8(ascii: "=") else { return nil }
            guard let value = parseValue() else { return nil }
            return (key, value)
        }

        mutating func skipLine() {
            while let byte = next(), byte != ASCII.lf {}
        }

        /// A value up to the end of the line: surrounding space trimmed, `#` and
        /// `;` start comments outside quotes, and backslash escapes `\n`, `\t`,
        /// `\b`, `\\`, `\"` and line continuations.
        mutating func parseValue() -> String? {
            var value: [UInt8] = []
            var quoted = false
            var inComment = false
            var trimLength: Int?
            while true {
                guard let byte = next(), byte != ASCII.lf else {
                    if quoted { return nil }
                    if let trimLength { value.removeSubrange(trimLength...) }
                    return String(decoding: value, as: UTF8.self)
                }
                if inComment { continue }
                if Self.isSpace(byte), !quoted {
                    if trimLength == nil { trimLength = value.count }
                    if !value.isEmpty { value.append(byte) }
                    continue
                }
                if !quoted, byte == UInt8(ascii: "#") || byte == UInt8(ascii: ";") {
                    inComment = true
                    continue
                }
                trimLength = nil
                if byte == ASCII.backslash {
                    // A backslash at the very end continues onto the (empty) end of the file.
                    let escaped = next() ?? ASCII.lf
                    switch escaped {
                    case ASCII.lf: continue
                    case UInt8(ascii: "t"): value.append(ASCII.tab)
                    case UInt8(ascii: "b"): value.append(0x08)
                    case UInt8(ascii: "n"): value.append(ASCII.lf)
                    case ASCII.backslash, UInt8(ascii: "\""): value.append(escaped)
                    default: return nil
                    }
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    quoted.toggle()
                    continue
                }
                value.append(byte)
            }
        }
    }
}
