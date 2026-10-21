import Foundation
import Observation
import TideCore

/// The Search view (find in files).
@Observable
final class SearchModel {
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    var replacement = ""
    var isRegex = false { didSet { scheduleSearch() } }
    var matchCase = false { didSet { scheduleSearch() } }
    var wholeWord = false { didSet { scheduleSearch() } }
    var include = "" { didSet { if include != oldValue { scheduleSearch() } } }
    var exclude = "" { didSet { if exclude != oldValue { scheduleSearch() } } }
    var showReplace = false
    var showDetails = false
    private(set) var results: [FileSearchResult] = []
    private(set) var isSearching = false
    private(set) var error: String?
    var collapsed: Set<String> = []
    var focusRequest = 0

    @ObservationIgnored weak var workbench: Workbench?
    @ObservationIgnored private var task: Task<Void, Never>?

    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }

    var summary: String {
        if let error { return error }
        if query.isEmpty { return "" }
        if isSearching, results.isEmpty { return "Searching..." }
        if results.isEmpty { return "No results found. Review your settings for configured exclusions and check your gitignore files." }
        return "\(matchCount) result\(matchCount == 1 ? "" : "s") in \(results.count) file\(results.count == 1 ? "" : "s")"
    }

    func reset() {
        task?.cancel()
        results = []
        error = nil
    }

    private func scheduleSearch() {
        task?.cancel()
        guard !query.isEmpty, let workbench else {
            results = []
            error = nil
            isSearching = false
            return
        }
        isSearching = true
        let search = SearchQuery(pattern: query, isRegex: isRegex, matchCase: matchCase, wholeWord: wholeWord, include: include, exclude: exclude)
        do {
            _ = try WorkspaceSearch.regex(for: search)
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
            results = []
            isSearching = false
            return
        }
        guard let root = workbench.workspace.localRoot else {
            error = "Search in remote folders runs on the host; connect a terminal to grep there."
            isSearching = false
            return
        }
        let extra = workbench.settings.globs("search.exclude") + workbench.settings.globs("files.exclude")
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            var collected: [FileSearchResult] = []
            do {
                for try await result in WorkspaceSearch.search(root: root, query: search, extraExcludes: extra) {
                    collected.append(result)
                    if collected.count % 20 == 0 { self?.results = collected }
                }
            } catch {
                self?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.results = collected.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            self.isSearching = false
        }
    }

    func rerun() { scheduleSearch() }

    func documentSaved() async {
        if !query.isEmpty { scheduleSearch() }
    }

    /// Replaces every match in every result file (open documents are edited in place).
    func replaceAll() async {
        guard let workbench, !results.isEmpty, let regex = try? WorkspaceSearch.regex(for: SearchQuery(pattern: query, isRegex: isRegex, matchCase: matchCase, wholeWord: wholeWord)) else { return }
        var total = 0
        var files = 0
        for result in results {
            if let document = workbench.document(for: result.path) {
                let (text, count) = WorkspaceSearch.replaceAll(in: document.text, regex: regex, replacement: replacement, isRegex: isRegex)
                if count > 0 {
                    document.replaceText(with: text)
                    await workbench.save(document)
                    total += count
                    files += 1
                }
                continue
            }
            guard let data = try? await workbench.workspace.fileSystem.read(result.path), let (text, format) = TextFileCodec.decode(data) else { continue }
            let (replaced, count) = WorkspaceSearch.replaceAll(in: text, regex: regex, replacement: replacement, isRegex: isRegex)
            guard count > 0 else { continue }
            do {
                try await workbench.workspace.fileSystem.write(result.path, data: TextFileCodec.encode(replaced, format: format))
                total += count
                files += 1
            } catch {
                workbench.show(error: error, prefix: "Replace failed in \(result.path)")
            }
        }
        workbench.toast("Replaced \(total) occurrence\(total == 1 ? "" : "s") across \(files) file\(files == 1 ? "" : "s").")
        scheduleSearch()
    }
}
