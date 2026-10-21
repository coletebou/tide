import Foundation

/// A glob compiled with git's wildmatch rules.
///
/// - `?` matches one character, `*` a run of characters, and `[...]` a set
///   (`!` or `^` negates, ranges, `[:alpha:]`-style classes, `\` escapes).
/// - In pathname mode none of those match `/`. A `**` between slashes (or at
///   either end) matches across directories: `a/**/b` matches `a/b` and
///   `a/x/y/b`; any other `**` acts like `*`.
/// - With case folding, ASCII letters in the text and in unescaped pattern
///   literals compare case-insensitively. Like git, escaped letters and
///   letters inside sets are compared as written.
/// - A malformed set (no closing `]`, unknown class name) or a trailing
///   backslash makes the pattern match nothing.
struct GitGlob: Sendable {
    enum Token: Sendable {
        /// A byte, already lowercased when it should compare case-insensitively.
        case literal(UInt8)
        case anyCharacter
        /// A run of characters; `crossesSlash` lets it include `/`.
        case star(crossesSlash: Bool)
        /// `**/`: nothing, or anything that ends with a slash.
        case globstarSlash
        case set(ByteSet)
    }

    struct ByteSet: Sendable {
        enum Member: Sendable {
            case byte(UInt8)
            case range(UInt8, UInt8)
            case named(NamedClass)
        }

        var members: [Member]
        var negated: Bool

        /// `character` is the (case-folded) text character.
        func matches(_ character: UInt8, caseFold: Bool) -> Bool {
            var found = false
            for member in members {
                switch member {
                case .byte(let byte):
                    found = character == byte
                case .range(let low, let high):
                    // A reversed range such as `z-a` matches nothing.
                    let upper = ASCII.uppercased(character)
                    found = (character >= low && character <= high)
                        || (caseFold && ASCII.isLower(character) && upper >= low && upper <= high)
                case .named(let named):
                    found = named.contains(character) || (named == .upper && caseFold && ASCII.isLower(character))
                }
                if found { break }
            }
            return found != negated
        }
    }

    enum NamedClass: String, Sendable {
        case alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit

        func contains(_ byte: UInt8) -> Bool {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isAlpha = ASCII.isUpper(byte) || ASCII.isLower(byte)
            switch self {
            case .alnum: return isDigit || isAlpha
            case .alpha: return isAlpha
            case .blank: return byte == ASCII.space || byte == ASCII.tab
            case .cntrl: return byte < 0x20 || byte == 0x7F
            case .digit: return isDigit
            case .graph: return byte > 0x20 && byte < 0x7F
            case .lower: return ASCII.isLower(byte)
            case .print: return byte >= 0x20 && byte < 0x7F
            case .punct: return byte > 0x20 && byte < 0x7F && !isDigit && !isAlpha
            case .space: return byte == ASCII.space || byte == ASCII.tab || byte == ASCII.lf || byte == ASCII.cr
            case .upper: return ASCII.isUpper(byte)
            case .xdigit:
                return isDigit || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
            }
        }
    }

    let pathname: Bool
    let caseFold: Bool
    private(set) var tokens: [Token] = []
    /// False when the pattern is malformed and can never match.
    private(set) var isValid = true
    private var starCount = 0

    init(_ pattern: some Collection<UInt8>, pathname: Bool, caseFold: Bool) {
        self.pathname = pathname
        self.caseFold = caseFold
        let bytes = Array(pattern)
        var index = 0
        while index < bytes.count, isValid {
            let byte = bytes[index]
            switch byte {
            case ASCII.backslash:
                guard index + 1 < bytes.count else {
                    isValid = false
                    break
                }
                tokens.append(.literal(bytes[index + 1]))
                index += 2
            case UInt8(ascii: "?"):
                tokens.append(.anyCharacter)
                index += 1
            case UInt8(ascii: "*"):
                index = compileStars(bytes, from: index)
            case UInt8(ascii: "["):
                index = compileSet(bytes, from: index)
            default:
                tokens.append(.literal(caseFold ? ASCII.lowercased(byte) : byte))
                index += 1
            }
        }
    }

    private mutating func compileStars(_ bytes: [UInt8], from start: Int) -> Int {
        var end = start
        while end < bytes.count, bytes[end] == UInt8(ascii: "*") { end += 1 }
        starCount += 1
        guard end - start >= 2, pathname else {
            tokens.append(.star(crossesSlash: !pathname))
            return end
        }
        let startsComponent = start == 0 || bytes[start - 1] == ASCII.slash
        let next: UInt8? = end < bytes.count ? bytes[end] : nil
        let escapedSlash = next == ASCII.backslash && end + 1 < bytes.count && bytes[end + 1] == ASCII.slash
        guard startsComponent, next == nil || next == ASCII.slash || escapedSlash else {
            tokens.append(.star(crossesSlash: false))
            return end
        }
        if next == ASCII.slash {
            tokens.append(.globstarSlash)
            return end + 1
        }
        tokens.append(.star(crossesSlash: true))
        return end
    }

    private mutating func compileSet(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        var negated = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "!") || bytes[index] == UInt8(ascii: "^") {
            negated = true
            index += 1
        }
        var members: [ByteSet.Member] = []
        // The previous single character, which may start a range.
        var previous: UInt8?
        var first = true
        while true {
            guard index < bytes.count else {
                isValid = false
                return index
            }
            let byte = bytes[index]
            if byte == UInt8(ascii: "]"), !first { break }
            first = false
            if byte == ASCII.backslash {
                guard index + 1 < bytes.count else {
                    isValid = false
                    return index
                }
                members.append(.byte(bytes[index + 1]))
                previous = bytes[index + 1]
                index += 2
            } else if byte == UInt8(ascii: "-"), let low = previous, index + 1 < bytes.count, bytes[index + 1] != UInt8(ascii: "]") {
                var high = bytes[index + 1]
                index += 2
                if high == ASCII.backslash {
                    guard index < bytes.count else {
                        isValid = false
                        return index
                    }
                    high = bytes[index]
                    index += 1
                }
                members.append(.range(low, high))
                previous = nil
            } else if byte == UInt8(ascii: "["), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: ":") {
                let nameStart = index + 2
                guard let close = bytes[nameStart...].firstIndex(of: UInt8(ascii: "]")) else {
                    isValid = false
                    return index
                }
                if close - nameStart >= 1, bytes[close - 1] == UInt8(ascii: ":") {
                    let name = String(decoding: bytes[nameStart..<(close - 1)], as: UTF8.self)
                    guard let named = NamedClass(rawValue: name) else {
                        isValid = false
                        return index
                    }
                    members.append(.named(named))
                    previous = nil
                    index = close + 1
                } else {
                    // Not a `[:class:]` after all: the `[` is an ordinary member.
                    members.append(.byte(byte))
                    previous = byte
                    index += 1
                }
            } else {
                members.append(.byte(byte))
                previous = byte
                index += 1
            }
        }
        tokens.append(.set(ByteSet(members: members, negated: negated)))
        return index + 1
    }

    /// Whether the whole of `text` matches.
    func matches(_ text: UnsafeBufferPointer<UInt8>) -> Bool {
        guard isValid else { return false }
        let count = text.count
        let width = count + 1
        // Memoize (token, position) results once backtracking can compound.
        var memo = starCount >= 2 ? [Int8](repeating: -1, count: (tokens.count + 1) * width) : []

        func character(at index: Int) -> UInt8 {
            caseFold ? ASCII.lowercased(text[index]) : text[index]
        }

        func match(_ token: Int, _ position: Int) -> Bool {
            if token == tokens.count { return position == count }
            if !memo.isEmpty, memo[token * width + position] >= 0 { return memo[token * width + position] == 1 }
            let result: Bool
            switch tokens[token] {
            case .literal(let byte):
                result = position < count && character(at: position) == byte && match(token + 1, position + 1)
            case .anyCharacter:
                result = position < count && !(pathname && text[position] == ASCII.slash) && match(token + 1, position + 1)
            case .set(let set):
                result = position < count && !(pathname && text[position] == ASCII.slash)
                    && set.matches(character(at: position), caseFold: caseFold) && match(token + 1, position + 1)
            case .star(let crossesSlash):
                var end = position
                var found = false
                while true {
                    if match(token + 1, end) {
                        found = true
                        break
                    }
                    if end == count || (!crossesSlash && text[end] == ASCII.slash) { break }
                    end += 1
                }
                result = found
            case .globstarSlash:
                var found = match(token + 1, position)
                var end = position
                while !found, end < count {
                    if text[end] == ASCII.slash, match(token + 1, end + 1) { found = true }
                    end += 1
                }
                result = found
            }
            if !memo.isEmpty { memo[token * width + position] = result ? 1 : 0 }
            return result
        }

        return match(0, 0)
    }

    func matches(_ text: some Collection<UInt8>) -> Bool {
        let bytes = Array(text)
        return bytes.withUnsafeBufferPointer { matches($0) }
    }
}

/// One line of a `.gitignore`-style file.
struct GitIgnorePattern: Sendable {
    /// `!pattern`: re-includes what earlier patterns excluded.
    let negated: Bool
    /// `pattern/`: matches only directories.
    let directoryOnly: Bool
    /// No slash in the pattern: it matches the last path component at any depth.
    /// Otherwise it matches the path relative to `base`.
    let matchesBasename: Bool
    /// The directory of the file the pattern came from, with a trailing slash, or empty for the root.
    let base: [UInt8]
    /// Set when the pattern has no wildcards: the exact text to compare.
    private let literal: [UInt8]?
    /// Set for `*suffix` basename patterns with no other wildcards.
    private let suffix: [UInt8]?
    private let glob: GitGlob?

    /// Parses one line, already stripped of its line ending and trailing spaces.
    /// Returns nil for blank lines and comments.
    init?(line: [UInt8], base: [UInt8], caseFold: Bool) {
        guard !line.isEmpty, line[0] != UInt8(ascii: "#") else { return nil }
        var pattern = line[...]
        negated = pattern.first == UInt8(ascii: "!")
        if negated { pattern = pattern.dropFirst() }
        directoryOnly = pattern.last == ASCII.slash
        if directoryOnly { pattern = pattern.dropLast() }
        matchesBasename = !pattern.contains(ASCII.slash)
        self.base = base
        if !matchesBasename, pattern.first == ASCII.slash { pattern = pattern.dropFirst() }

        let wildcards: Set<UInt8> = [UInt8(ascii: "*"), UInt8(ascii: "?"), UInt8(ascii: "["), ASCII.backslash]
        if !pattern.contains(where: wildcards.contains) {
            literal = Array(pattern)
            suffix = nil
            glob = nil
        } else if matchesBasename, pattern.first == UInt8(ascii: "*"), !pattern.dropFirst().contains(where: wildcards.contains) {
            literal = nil
            suffix = Array(pattern.dropFirst())
            glob = nil
        } else {
            literal = nil
            suffix = nil
            glob = GitGlob(pattern, pathname: !matchesBasename, caseFold: caseFold)
        }
    }

    /// Whether the pattern matches `path` (relative to the work tree). The
    /// caller has already checked `directoryOnly`.
    func matches(_ path: UnsafeBufferPointer<UInt8>, basenameStart: Int, caseFold: Bool) -> Bool {
        let name: UnsafeBufferPointer<UInt8>
        if matchesBasename {
            name = UnsafeBufferPointer(rebasing: path[basenameStart...])
        } else {
            // The path must lie inside the pattern's directory.
            guard path.count > base.count || (base.isEmpty && path.count > 0) else { return false }
            if !base.isEmpty {
                guard ASCII.equal(path[0..<base.count], base, ignoringCase: caseFold) else { return false }
            }
            name = UnsafeBufferPointer(rebasing: path[base.count...])
        }
        if let literal { return ASCII.equal(name, literal, ignoringCase: caseFold) }
        if let suffix {
            return name.count >= suffix.count && ASCII.equal(name.suffix(suffix.count), suffix, ignoringCase: caseFold)
        }
        return glob?.matches(name) ?? false
    }
}

/// The patterns of one ignore file, in file order.
struct GitIgnoreList: Sendable {
    var patterns: [GitIgnorePattern]

    /// Parses file content. A UTF-8 byte order mark is skipped, `\r\n` line
    /// endings are accepted, and unescaped trailing spaces are removed.
    init(data: Data, base: [UInt8], caseFold: Bool) {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        patterns = []
        for var line in bytes.split(separator: ASCII.lf, omittingEmptySubsequences: false).map(Array.init) {
            if line.last == ASCII.cr { line.removeLast() }
            Self.trimTrailingSpaces(&line)
            if let pattern = GitIgnorePattern(line: line, base: base, caseFold: caseFold) {
                patterns.append(pattern)
            }
        }
    }

    /// Removes trailing spaces unless they are escaped with a backslash.
    static func trimTrailingSpaces(_ line: inout [UInt8]) {
        var end = line.count
        while end > 0, line[end - 1] == ASCII.space {
            var backslashes = 0
            var index = end - 2
            while index >= 0, line[index] == ASCII.backslash {
                backslashes += 1
                index -= 1
            }
            if backslashes % 2 == 1 { break }
            end -= 1
        }
        line.removeSubrange(end...)
    }

    /// The verdict of the last matching pattern: true to exclude, false to
    /// re-include, nil when no pattern matches.
    func verdict(for path: UnsafeBufferPointer<UInt8>, basenameStart: Int, isDirectory: Bool, caseFold: Bool) -> Bool? {
        for pattern in patterns.reversed() {
            if pattern.directoryOnly, !isDirectory { continue }
            if pattern.matches(path, basenameStart: basenameStart, caseFold: caseFold) { return !pattern.negated }
        }
        return nil
    }
}

/// Git's ignore rules for one work tree: `.gitignore` files at every level,
/// `.git/info/exclude`, and the file named by `core.excludesFile`.
///
/// A `.gitignore` deeper in the tree takes precedence over shallower ones,
/// which take precedence over `info/exclude`, then `core.excludesFile`; within
/// a file the last matching line wins. As in git, nothing inside an ignored
/// directory can be re-included, and a `.git` entry is always ignored.
/// `.gitignore` files are read lazily and cached for the lifetime of the
/// object, so create a new one to pick up edits. Safe to use from several threads.
public final class GitIgnoreRules: @unchecked Sendable {
    public let workTree: URL
    let caseFold: Bool
    private let globalLists: [GitIgnoreList]
    /// Extra patterns given directly, consulted after the `.gitignore` files.
    private let extraList: GitIgnoreList?
    private let fallbackContent: (@Sendable (String) -> Data?)?
    private let lock = NSLock()
    private var directoryLists: [String: GitIgnoreList] = [:]

    /// - Parameters:
    ///   - infoExclude: usually `.git/info/exclude` (in the common directory of a linked worktree).
    ///   - excludesFile: the file named by `core.excludesFile`, if any.
    ///   - ignoreCase: `core.ignoreCase`; makes matching ASCII case-insensitive.
    ///   - fallbackContent: content for a `.gitignore` that is missing from the
    ///     work tree, such as one outside a sparse checkout (git reads those from the index).
    init(
        workTree: URL,
        infoExclude: URL?,
        excludesFile: URL?,
        ignoreCase: Bool,
        extraPatterns: String? = nil,
        fallbackContent: (@Sendable (String) -> Data?)? = nil
    ) {
        self.workTree = workTree
        caseFold = ignoreCase
        self.fallbackContent = fallbackContent
        extraList = extraPatterns.map { GitIgnoreList(data: Data($0.utf8), base: [], caseFold: ignoreCase) }
        // info/exclude is consulted before core.excludesFile.
        globalLists = [infoExclude, excludesFile].compactMap { url in
            guard let url, let data = try? GitFile.readIfExists(url) else { return nil }
            return GitIgnoreList(data: data, base: [], caseFold: ignoreCase)
        }
    }

    /// Rules with explicit pattern text, for previews and tests. `patterns` acts
    /// like `.git/info/exclude`; `.gitignore` files in `workTree` still apply.
    public convenience init(workTree: URL, patterns: String, ignoreCase: Bool = false) {
        self.init(workTree: workTree, infoExclude: nil, excludesFile: nil, ignoreCase: ignoreCase, extraPatterns: patterns)
    }

    /// Whether git would ignore `path`, given relative to the work tree with
    /// `/` separators (such as `build/output.o`). Pass `isDirectory` for
    /// directories so `name/` patterns can match.
    public func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        let bytes = Array(path.utf8)
        let components = bytes.split(separator: ASCII.slash)
        guard !components.isEmpty else { return false }
        if components.contains(where: { ASCII.equal($0, Array(".git".utf8), ignoringCase: caseFold) }) { return true }
        var stack = [list(forDirectory: [])]
        var prefix: [UInt8] = []
        for component in components.dropLast() {
            let start = prefix.count
            prefix.append(contentsOf: component)
            if isExcluded(prefix, basenameStart: start, isDirectory: true, stack: stack) { return true }
            prefix.append(ASCII.slash)
            stack.append(list(forDirectory: prefix))
        }
        let start = prefix.count
        prefix.append(contentsOf: components[components.count - 1])
        return isExcluded(prefix, basenameStart: start, isDirectory: isDirectory, stack: stack)
    }

    /// The verdict for `path` given the `.gitignore` lists of its directory and
    /// every parent (root first).
    func isExcluded(_ path: [UInt8], basenameStart: Int, isDirectory: Bool, stack: [GitIgnoreList?]) -> Bool {
        path.withUnsafeBufferPointer { buffer in
            for list in stack.reversed() {
                if let verdict = list?.verdict(for: buffer, basenameStart: basenameStart, isDirectory: isDirectory, caseFold: caseFold) {
                    return verdict
                }
            }
            if let verdict = extraList?.verdict(for: buffer, basenameStart: basenameStart, isDirectory: isDirectory, caseFold: caseFold) {
                return verdict
            }
            for list in globalLists {
                if let verdict = list.verdict(for: buffer, basenameStart: basenameStart, isDirectory: isDirectory, caseFold: caseFold) {
                    return verdict
                }
            }
            return false
        }
    }

    /// The parsed `.gitignore` of a directory (given with a trailing slash, or
    /// empty for the root), or nil when it has none.
    func list(forDirectory directory: [UInt8]) -> GitIgnoreList? {
        let key = String(decoding: directory, as: UTF8.self)
        lock.lock()
        if let cached = directoryLists[key] {
            lock.unlock()
            return cached.patterns.isEmpty ? nil : cached
        }
        lock.unlock()
        let relative = key + ".gitignore"
        let url = workTree.appendingPathComponent(relative)
        var data: Data?
        var info = stat()
        if lstat(url.path, &info) == 0 {
            // Like git, a .gitignore that is a symbolic link is not followed.
            if info.st_mode & S_IFMT == S_IFREG { data = try? GitFile.readIfExists(url) }
        } else {
            data = fallbackContent?(relative)
        }
        let list = GitIgnoreList(data: data ?? Data(), base: directory, caseFold: caseFold)
        lock.lock()
        directoryLists[key] = list
        lock.unlock()
        return list.patterns.isEmpty ? nil : list
    }
}
