import Foundation

/// A Search view query (find in files).
public struct SearchQuery: Hashable, Sendable {
    public var pattern: String
    public var isRegex = false
    public var matchCase = false
    public var wholeWord = false
    /// Comma-separated globs; empty means every file.
    public var include = ""
    /// Comma-separated globs added to the default excludes.
    public var exclude = ""
    public var useDefaultExcludes = true
    public var maxResults = 20_000

    public init(pattern: String, isRegex: Bool = false, matchCase: Bool = false, wholeWord: Bool = false, include: String = "", exclude: String = "") {
        self.pattern = pattern
        self.isRegex = isRegex
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.include = include
        self.exclude = exclude
    }
}

/// One match in a file. `line` is zero-based; `range` is UTF-16 within the line.
public struct SearchMatch: Hashable, Sendable {
    public var line: Int
    public var range: NSRange
    /// The line's text, trimmed to a window around the match for display.
    public var preview: String
    /// The match within `preview`.
    public var previewRange: NSRange
}

public struct FileSearchResult: Hashable, Identifiable, Sendable {
    public var path: String
    public var matches: [SearchMatch]
    public var id: String { path }
}

public enum WorkspaceSearch {
    public enum SearchError: Error, Equatable, LocalizedError {
        case invalidPattern(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPattern(let message): message
            }
        }
    }

    /// Compiles a query into a regular expression with VS Code's semantics:
    /// literal unless regex mode is on, case-insensitive unless Match Case,
    /// and `\b` boundaries for Match Whole Word.
    public static func regex(for query: SearchQuery) throws -> NSRegularExpression {
        var pattern = query.isRegex ? query.pattern : NSRegularExpression.escapedPattern(for: query.pattern)
        if query.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.matchCase { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw SearchError.invalidPattern("Invalid regular expression: \(query.pattern)")
        }
    }

    /// Every match in a text, line by line.
    public static func matches(in text: String, regex: NSRegularExpression, limit: Int = .max) -> [SearchMatch] {
        let nsText = text as NSString
        let index = LineIndex(nsText)
        var results: [SearchMatch] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            let line = index.line(containing: match.range.location)
            let content = index.contentRange(ofLine: line, in: nsText)
            let column = match.range.location - content.location
            let length = min(match.range.length, max(0, content.length - column))
            let (preview, previewRange) = makePreview(line: nsText.substring(with: content) as NSString, match: NSRange(location: column, length: length))
            results.append(SearchMatch(line: line, range: NSRange(location: column, length: length), preview: preview, previewRange: previewRange))
            if results.count >= limit { stop.pointee = true }
        }
        return results
    }

    /// Replaces every match. In regex mode the replacement may use `$1`.
    public static func replaceAll(in text: String, regex: NSRegularExpression, replacement: String, isRegex: Bool) -> (text: String, count: Int) {
        let template = isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        let mutable = NSMutableString(string: text)
        let count = regex.replaceMatches(in: mutable, options: [], range: NSRange(location: 0, length: mutable.length), withTemplate: template)
        return (mutable as String, count)
    }

    /// Searches every text file under a local folder, yielding results file
    /// by file. Cancel the consuming task to stop early.
    public static func search(root: URL, query: SearchQuery, extraExcludes: [String] = [], isIgnored: (@Sendable (String) -> Bool)? = nil) -> AsyncThrowingStream<FileSearchResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let regex = try regex(for: query)
                    let includes = globs(query.include)
                    var excludes = globs(query.exclude)
                    if query.useDefaultExcludes {
                        excludes += (DefaultExcludes.files + DefaultExcludes.search + extraExcludes).map { Glob($0) }
                    }
                    let base = root.standardizedFileURL
                    guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []) else {
                        continuation.finish()
                        return
                    }
                    var total = 0
                    while let url = enumerator.nextObject() as? URL {
                        try Task.checkCancellation()
                        let path = relativePath(of: url, base: base)
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        if excludes.contains(where: { $0.matches(path) }) || (isIgnored?(path) ?? false) {
                            if values?.isDirectory == true { enumerator.skipDescendants() }
                            continue
                        }
                        guard values?.isDirectory != true else { continue }
                        if !includes.isEmpty, !includes.contains(where: { $0.matches(path) }) { continue }
                        if (values?.fileSize ?? 0) > 10_000_000 { continue }
                        guard let data = try? Data(contentsOf: url), let (text, _) = TextFileCodec.decode(data) else { continue }
                        let found = matches(in: text, regex: regex, limit: query.maxResults - total)
                        if !found.isEmpty {
                            total += found.count
                            continuation.yield(FileSearchResult(path: path, matches: found))
                            if total >= query.maxResults { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Comma-separated globs from a Search view field, matching at any depth.
    public static func globs(_ field: String) -> [Glob] {
        field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { Glob($0, matchAnywhere: true) }
    }

    static func relativePath(of url: URL, base: URL) -> String {
        let full = url.standardizedFileURL.path
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// Keeps previews short: up to 40 characters of context before the match.
    static func makePreview(line: NSString, match: NSRange) -> (String, NSRange) {
        let leadingTrim = line.length - (line as String).drop(while: { $0 == " " || $0 == "\t" }).utf16.count
        var start = min(leadingTrim, match.location)
        if match.location - start > 40 { start = match.location - 40 }
        let end = min(line.length, max(NSMaxRange(match) + 120, start))
        let preview = line.substring(with: NSRange(location: start, length: end - start))
        return (preview, NSRange(location: match.location - start, length: match.length))
    }
}
