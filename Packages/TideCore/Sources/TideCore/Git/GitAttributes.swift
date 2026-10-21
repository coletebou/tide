import Foundation

/// One attribute's state for a path, as `git check-attr` reports it.
enum GitAttributeState: Equatable, Sendable {
    /// `name`
    case set
    /// `-name`
    case unset
    /// `name=value`
    case value(String)
    /// `!name`: as if no line named it, which also hides lower-precedence lines.
    case unspecified
}

/// The lines of one `.gitattributes`-style file, in file order.
struct GitAttributeList: Sendable {
    struct Assignment: Sendable {
        var name: String
        var state: GitAttributeState
    }

    struct Rule: Sendable {
        var pattern: GitIgnorePattern
        var assignments: [Assignment]
    }

    struct Macro: Sendable {
        var name: String
        var assignments: [Assignment]
    }

    private(set) var rules: [Rule] = []
    /// `[attr]name ...` definitions, kept only where git allows them.
    private(set) var macros: [Macro] = []

    /// Parses file content like git's `parse_attr_line`. Lines git rejects
    /// (negative patterns, invalid attribute names, macros outside the root
    /// `.gitattributes` and the global files) are skipped.
    init(data: Data, base: [UInt8], caseFold: Bool, allowsMacros: Bool) {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        for line in bytes.split(separator: ASCII.lf) {
            parse(Array(line), base: base, caseFold: caseFold, allowsMacros: allowsMacros)
        }
    }

    private mutating func parse(_ line: [UInt8], base: [UInt8], caseFold: Bool, allowsMacros: Bool) {
        // Git ignores overly long lines.
        guard line.count < 2048 else { return }
        var index = line.firstIndex { !Self.isBlank($0) } ?? line.count
        guard index < line.count, line[index] != UInt8(ascii: "#") else { return }
        var name: [UInt8]
        if line[index] == UInt8(ascii: "\""), let quoted = Self.unquote(line, from: index) {
            name = quoted.text
            index = quoted.end
        } else {
            let end = line[index...].firstIndex(where: Self.isBlank) ?? line.count
            name = Array(line[index..<end])
            index = end
        }
        var macroName: String?
        let macroPrefix = Array("[attr]".utf8)
        if name.count > macroPrefix.count, name.starts(with: macroPrefix) {
            let rest = name.dropFirst(macroPrefix.count)
            guard allowsMacros, Self.isValidName(rest) else { return }
            macroName = String(decoding: rest, as: UTF8.self)
        }
        var assignments: [Assignment] = []
        while true {
            while index < line.count, Self.isBlank(line[index]) { index += 1 }
            guard index < line.count else { break }
            let end = line[index...].firstIndex(where: Self.isBlank) ?? line.count
            // One invalid attribute and git drops the whole line.
            guard let assignment = Self.assignment(line[index..<end]) else { return }
            assignments.append(assignment)
            index = end
        }
        if let macroName {
            macros.append(Macro(name: macroName, assignments: assignments))
            return
        }
        // Only a quoted pattern can start with `#`; keep it literal.
        if name.first == UInt8(ascii: "#") { name.insert(ASCII.backslash, at: 0) }
        guard !assignments.isEmpty, let pattern = GitIgnorePattern(line: name, base: base, caseFold: caseFold), !pattern.negated else { return }
        rules.append(Rule(pattern: pattern, assignments: assignments))
    }

    /// `name`, `-name`, `!name` or `name=value`, as `parse_attr` reads them.
    private static func assignment(_ token: ArraySlice<UInt8>) -> Assignment? {
        let equals = token.firstIndex(of: UInt8(ascii: "="))
        var nameStart = token.startIndex
        let state: GitAttributeState
        if token.first == UInt8(ascii: "-") || token.first == UInt8(ascii: "!") {
            state = token.first == UInt8(ascii: "-") ? .unset : .unspecified
            nameStart += 1
        } else if let equals {
            state = .value(String(decoding: token[(equals + 1)...], as: UTF8.self))
        } else {
            state = .set
        }
        let name = token[nameStart..<(equals ?? token.endIndex)]
        // Names starting with `builtin_` are reserved for git.
        guard isValidName(name), !name.starts(with: "builtin_".utf8) else { return nil }
        return Assignment(name: String(decoding: name, as: UTF8.self), state: state)
    }

    /// git's `attr_name_valid`: ASCII letters, digits, `-`, `.` and `_`, not starting with `-`.
    private static func isValidName(_ name: some Collection<UInt8>) -> Bool {
        guard let first = name.first, first != UInt8(ascii: "-") else { return false }
        return name.allSatisfy { byte in
            byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_")
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || ASCII.isUpper(byte) || ASCII.isLower(byte)
        }
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == ASCII.space || byte == ASCII.tab || byte == ASCII.cr || byte == ASCII.lf
    }

    /// git's `unquote_c_style` for a pattern in double quotes: the text and the
    /// index just past the closing quote, or nil when the quoting is malformed.
    private static func unquote(_ line: [UInt8], from start: Int) -> (text: [UInt8], end: Int)? {
        var text: [UInt8] = []
        var index = start + 1
        while index < line.count {
            let byte = line[index]
            index += 1
            if byte == UInt8(ascii: "\"") { return (text, index) }
            guard byte == ASCII.backslash else {
                text.append(byte)
                continue
            }
            guard index < line.count else { return nil }
            let escaped = line[index]
            index += 1
            switch escaped {
            case UInt8(ascii: "a"): text.append(0x07)
            case UInt8(ascii: "b"): text.append(0x08)
            case UInt8(ascii: "f"): text.append(0x0C)
            case UInt8(ascii: "n"): text.append(ASCII.lf)
            case UInt8(ascii: "r"): text.append(ASCII.cr)
            case UInt8(ascii: "t"): text.append(ASCII.tab)
            case UInt8(ascii: "v"): text.append(0x0B)
            case ASCII.backslash, UInt8(ascii: "\""): text.append(escaped)
            case UInt8(ascii: "0")...UInt8(ascii: "3"):
                // Three octal digits.
                let octal = UInt8(ascii: "0")...UInt8(ascii: "7")
                guard index + 1 < line.count, octal.contains(line[index]), octal.contains(line[index + 1]) else { return nil }
                let high: UInt8 = (escaped - 0x30) << 6
                let middle: UInt8 = (line[index] - 0x30) << 3
                text.append(high | middle | (line[index + 1] - 0x30))
                index += 2
            default:
                return nil
            }
        }
        return nil
    }
}

/// Git's attributes for one work tree: the `.gitattributes` file in each
/// directory, `info/attributes`, the file named by `core.attributesFile`, and
/// the built-in `binary` macro.
///
/// For each attribute, `info/attributes` takes precedence over a deeper
/// `.gitattributes`, which takes precedence over shallower ones, then
/// `core.attributesFile`; within a file the last matching line wins. As for
/// `git status`, a `.gitattributes` missing from the work tree is read from
/// the index. Files are read lazily and cached for the lifetime of the object.
final class GitAttributes: @unchecked Sendable {
    let workTree: URL
    let caseFold: Bool
    private let infoList: GitAttributeList?
    private let globalList: GitAttributeList?
    private let fallbackContent: (@Sendable (String) -> Data?)?
    private let lock = NSLock()
    private var directoryLists: [String: GitAttributeList] = [:]

    private static let builtin = GitAttributeList(data: Data("[attr]binary -diff -merge -text\n".utf8), base: [], caseFold: false, allowsMacros: true)

    /// - Parameters:
    ///   - infoAttributes: usually `info/attributes` in the common directory.
    ///   - attributesFile: the file named by `core.attributesFile`, if any.
    ///   - ignoreCase: `core.ignoreCase`; makes matching ASCII case-insensitive.
    ///   - fallbackContent: content for a `.gitattributes` missing from the work tree.
    init(workTree: URL, infoAttributes: URL?, attributesFile: URL?, ignoreCase: Bool, fallbackContent: (@Sendable (String) -> Data?)? = nil) {
        self.workTree = workTree
        caseFold = ignoreCase
        self.fallbackContent = fallbackContent
        func read(_ url: URL?) -> GitAttributeList? {
            guard let url, let data = try? GitFile.readIfExists(url) else { return nil }
            return GitAttributeList(data: data, base: [], caseFold: ignoreCase, allowsMacros: true)
        }
        infoList = read(infoAttributes)
        globalList = read(attributesFile)
    }

    /// Every attribute git assigns to the file at `path` (relative to the work
    /// tree, `/`-separated), with macros such as `binary` expanded, like
    /// `git check-attr --all` plus the unspecified ones.
    func states(forFile path: String) -> [String: GitAttributeState] {
        let bytes = Array(path.utf8)
        let basenameStart = bytes.lastIndex(of: ASCII.slash).map { $0 + 1 } ?? 0
        // Highest precedence first.
        var stack: [GitAttributeList] = infoList.map { [$0] } ?? []
        var directories: [[UInt8]] = [[]]
        for (index, byte) in bytes.enumerated() where byte == ASCII.slash {
            directories.append(Array(bytes[...index]))
        }
        stack += directories.reversed().compactMap(list(forDirectory:))
        if let globalList { stack.append(globalList) }
        stack.append(Self.builtin)

        // The highest-precedence definition of each macro.
        var macros: [String: [GitAttributeList.Assignment]] = [:]
        for list in stack {
            for macro in list.macros.reversed() where macros[macro.name] == nil {
                macros[macro.name] = macro.assignments
            }
        }
        // Like git's `fill`: the first value found for an attribute stands,
        // and setting a macro fills in the attributes it stands for.
        var states: [String: GitAttributeState] = [:]
        func fill(_ assignments: [GitAttributeList.Assignment]) {
            for assignment in assignments.reversed() where states[assignment.name] == nil {
                states[assignment.name] = assignment.state
                if assignment.state == .set, let expansion = macros[assignment.name] { fill(expansion) }
            }
        }
        bytes.withUnsafeBufferPointer { buffer in
            for list in stack {
                // A pattern for directories (`name/`) never matches a file.
                for rule in list.rules.reversed() where !rule.pattern.directoryOnly {
                    if rule.pattern.matches(buffer, basenameStart: basenameStart, caseFold: caseFold) { fill(rule.assignments) }
                }
            }
        }
        return states
    }

    /// The parsed `.gitattributes` of a directory (given with a trailing
    /// slash, or empty for the root), or nil when it has none.
    private func list(forDirectory directory: [UInt8]) -> GitAttributeList? {
        let key = String(decoding: directory, as: UTF8.self)
        lock.lock()
        if let cached = directoryLists[key] {
            lock.unlock()
            return cached.rules.isEmpty && cached.macros.isEmpty ? nil : cached
        }
        lock.unlock()
        let relative = key + ".gitattributes"
        let url = workTree.appendingPathComponent(relative)
        var data: Data?
        var info = stat()
        // Like git, a .gitattributes that is a symbolic link is not followed; the index's copy is used instead.
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
            data = try? GitFile.readIfExists(url)
        } else {
            data = fallbackContent?(relative)
        }
        // Macros may only be defined at the top level.
        let list = GitAttributeList(data: data ?? Data(), base: directory, caseFold: caseFold, allowsMacros: directory.isEmpty)
        lock.lock()
        directoryLists[key] = list
        lock.unlock()
        return list.rules.isEmpty && list.macros.isEmpty ? nil : list
    }
}

/// How git converts a work-tree file's content before hashing it, chosen from
/// its `text`, `crlf` and `eol` attributes and `core.autocrlf` (`convert_attrs`
/// and `crlf_to_git` in git's convert.c).
enum GitTextConversion: Equatable, Sendable {
    /// The bytes are hashed as they are.
    case none
    /// `text`, `eol` or `crlf`: each CRLF becomes LF.
    case text
    /// `text=auto` or `core.autocrlf`: CRLF becomes LF in a file that looks
    /// like text, unless the blob `indexBlob` already in the index has CRLF.
    case auto(indexBlob: GitObjectID)

    /// Git's choice for a file with these attribute states.
    init(_ states: [String: GitAttributeState], autoCRLF: Bool, indexBlob: GitObjectID) {
        enum Action { case undefined, binary, text, auto }
        func action(_ state: GitAttributeState?) -> Action {
            switch state {
            case .set?, .value("input")?: return .text
            case .unset?: return .binary
            case .value("auto")?: return .auto
            default: return .undefined
            }
        }
        var chosen = action(states["text"])
        if chosen == .undefined { chosen = action(states["crlf"]) }
        // `eol=lf` or `eol=crlf` makes a file text unless it is binary or auto.
        if chosen != .binary, chosen != .auto, states["eol"] == .value("lf") || states["eol"] == .value("crlf") {
            chosen = .text
        }
        if chosen == .undefined { chosen = autoCRLF ? .auto : .binary }
        switch chosen {
        case .text: self = .text
        case .auto: self = .auto(indexBlob: indexBlob)
        case .binary, .undefined: self = .none
        }
    }

    /// The content git hashes for a file with `data` on disk. `blob` reads
    /// an object, for the check of the indexed blob in auto mode.
    func normalized(_ data: Data, blob: (GitObjectID) -> Data?) -> Data {
        guard self != .none else { return data }
        let stats = GitTextStats(data)
        guard stats.crlf > 0 else { return data }
        switch self {
        case .none:
            return data
        case .text:
            // Each CR before an LF goes; a lone CR stays.
            var result: [UInt8] = []
            result.reserveCapacity(data.count - stats.crlf)
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for index in bytes.indices where !(bytes[index] == ASCII.cr && index + 1 < bytes.count && bytes[index + 1] == ASCII.lf) {
                    result.append(bytes[index])
                }
            }
            return Data(result)
        case .auto(let indexBlob):
            guard !stats.isBinary else { return data }
            // Git's safer autocrlf: a file committed with CRLF stays that way.
            if let committed = blob(indexBlob), committed.contains(ASCII.cr) {
                let committedStats = GitTextStats(committed)
                if !committedStats.isBinary, committedStats.crlf > 0 { return data }
            }
            // A file with a lone CR counts as binary, so every CR left is part of a CRLF.
            return data.filter { $0 != ASCII.cr }
        }
    }
}

/// Git's byte counts for its text heuristic (`gather_stats` in convert.c).
struct GitTextStats {
    var crlf = 0
    var loneCR = 0
    var nul = 0
    var printable = 0
    var nonPrintable = 0

    init(_ data: Data) {
        var crlf = 0
        var loneCR = 0
        var nul = 0
        var printable = 0
        var nonPrintable = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case ASCII.cr:
                    if index < bytes.count, bytes[index] == ASCII.lf {
                        crlf += 1
                        index += 1
                    } else {
                        loneCR += 1
                    }
                case ASCII.lf:
                    break
                // Backspace, tab, escape and form feed count as text.
                case 0x08, ASCII.tab, 0x1B, 0x0C:
                    printable += 1
                case 0:
                    nul += 1
                    nonPrintable += 1
                case 0x01..<0x20, 0x7F:
                    nonPrintable += 1
                default:
                    printable += 1
                }
            }
            // A final Ctrl-Z, the old DOS end-of-file mark, does not count.
            if bytes.last == 0x1A { nonPrintable -= 1 }
        }
        self.crlf = crlf
        self.loneCR = loneCR
        self.nul = nul
        self.printable = printable
        self.nonPrintable = nonPrintable
    }

    /// `convert_is_binary`: a lone CR, a NUL, or more than one control
    /// character for every 128 printable ones.
    var isBinary: Bool { loneCR > 0 || nul > 0 || (printable >> 7) < nonPrintable }
}
