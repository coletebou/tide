import Foundation

/// A glob pattern as used by VS Code's `files.exclude`, `search.exclude` and
/// the Search view's include/exclude fields: `**` (any number of folders),
/// `*`, `?`, `{a,b}` alternatives and `[...]` character classes.
public struct Glob: Hashable, @unchecked Sendable {
    public let pattern: String
    // NSRegularExpression is immutable and documented as thread-safe.
    private let regex: NSRegularExpression?

    /// - Parameter matchAnywhere: treat a pattern without `/` as matching at
    ///   any depth (`*.ts` means `**/*.ts`), as the Search view does.
    public init(_ pattern: String, matchAnywhere: Bool = false) {
        var trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        if trimmed.hasSuffix("/") { trimmed += "**" }
        if matchAnywhere, !trimmed.contains("/"), !trimmed.hasPrefix("**") {
            trimmed = "**/" + trimmed
        }
        self.pattern = trimmed
        self.regex = try? NSRegularExpression(pattern: "^" + Self.translate(trimmed) + "$")
    }

    public static func == (lhs: Glob, rhs: Glob) -> Bool { lhs.pattern == rhs.pattern }
    public func hash(into hasher: inout Hasher) { hasher.combine(pattern) }

    /// Whether a workspace-relative path matches. A folder pattern also
    /// matches everything inside that folder.
    public func matches(_ path: String) -> Bool {
        guard let regex else { return false }
        if Self.fullMatch(regex, path) { return true }
        // "**/node_modules" excludes "node_modules/x/y" too.
        var prefix = path
        while let slash = prefix.lastIndex(of: "/") {
            prefix = String(prefix[..<slash])
            if Self.fullMatch(regex, prefix) { return true }
        }
        return false
    }

    private static func fullMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func translate(_ glob: String) -> String {
        var output = ""
        let characters = Array(glob)
        var index = 0
        var braceDepth = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    let followedBySlash = index + 2 < characters.count && characters[index + 2] == "/"
                    if followedBySlash {
                        output += "(?:.*/)?"
                        index += 3
                    } else {
                        output += ".*"
                        index += 2
                    }
                    continue
                }
                output += "[^/]*"
            case "?":
                output += "[^/]"
            case "{":
                braceDepth += 1
                output += "(?:"
            case "}" where braceDepth > 0:
                braceDepth -= 1
                output += ")"
            case "," where braceDepth > 0:
                output += "|"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]") {
                    var body = String(characters[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    output += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close + 1
                    continue
                }
                output += "\\["
            default:
                output += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return output
    }
}

/// VS Code's default exclude settings.
public enum DefaultExcludes {
    public static let files: [String] = ["**/.git", "**/.svn", "**/.hg", "**/CVS", "**/.DS_Store", "**/Thumbs.db"]
    public static let search: [String] = ["**/node_modules", "**/bower_components", "**/*.code-search"]
}
