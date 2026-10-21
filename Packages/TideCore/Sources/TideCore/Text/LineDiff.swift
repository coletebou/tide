import Foundation

/// A contiguous change between two versions of a text, in zero-based lines.
public struct DiffHunk: Equatable, Hashable, Sendable {
    public enum Kind: Sendable { case insertion, deletion, modification }

    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }

    public var kind: Kind {
        if oldCount == 0 { return .insertion }
        if newCount == 0 { return .deletion }
        return .modification
    }

    public var oldRange: Range<Int> { oldStart..<(oldStart + oldCount) }
    public var newRange: Range<Int> { newStart..<(newStart + newCount) }
}

/// Line diffs (Myers' O(ND) algorithm with common prefix/suffix trimming).
/// Used by the source control diff view, the editor's change gutter, and AI
/// edit review, where each hunk can be accepted or rejected.
public enum LineDiff {
    /// Above this many differences the middle of the diff collapses into one
    /// hunk, which bounds memory on large rewrites.
    static let maxEditDistance = 2_000

    public static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices where lines[index].hasSuffix("\r") {
            lines[index].removeLast()
        }
        return lines
    }

    public static func diff(oldText: String, newText: String) -> [DiffHunk] {
        diff(old: lines(of: oldText), new: lines(of: newText))
    }

    public static func diff(old: [String], new: [String]) -> [DiffHunk] {
        // Intern lines so comparisons are integer compares.
        var ids: [String: Int] = [:]
        let a = old.map { line -> Int in
            if let id = ids[line] { return id }
            let id = ids.count
            ids[line] = id
            return id
        }
        let b = new.map { line -> Int in
            if let id = ids[line] { return id }
            let id = ids.count
            ids[line] = id
            return id
        }

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let middleA = Array(a[prefix..<(a.count - suffix)])
        let middleB = Array(b[prefix..<(b.count - suffix)])
        if middleA.isEmpty, middleB.isEmpty { return [] }

        guard let operations = myers(middleA, middleB) else {
            return [DiffHunk(oldStart: prefix, oldCount: middleA.count, newStart: prefix, newCount: middleB.count)]
        }
        return hunks(from: operations, offset: prefix)
    }

    private enum Operation {
        case equal
        case delete
        case insert
    }

    /// Myers' greedy algorithm. Each step keeps only the slice of the V array
    /// it can reach (2d+1 entries), so memory grows with D² rather than D·(N+M).
    private static func myers(_ a: [Int], _ b: [Int]) -> [Operation]? {
        let n = a.count
        let m = b.count
        let maxD = min(n + m, maxEditDistance)
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        let offset = maxD + 1
        var trace: [[Int]] = []
        for d in 0...maxD {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    return backtrack(trace: trace, n: n, m: m)
                }
                k += 2
            }
        }
        return nil
    }

    private static func backtrack(trace: [[Int]], n: Int, m: Int) -> [Operation] {
        var operations: [Operation] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let slice = trace[d]
            // slice[i] holds V[k] for k = i - d.
            func value(_ k: Int) -> Int { slice[k + d] }
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && value(k - 1) < value(k + 1)) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = d == 0 ? 0 : value(previousK)
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                operations.append(.equal)
                x -= 1
                y -= 1
            }
            if d > 0 {
                operations.append(x == previousX ? .insert : .delete)
            }
            x = previousX
            y = previousY
        }
        return operations.reversed()
    }

    private static func hunks(from operations: [Operation], offset: Int) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var oldLine = offset
        var newLine = offset
        var current: DiffHunk?
        for operation in operations {
            switch operation {
            case .equal:
                if let hunk = current { hunks.append(hunk) }
                current = nil
                oldLine += 1
                newLine += 1
            case .delete:
                if current == nil { current = DiffHunk(oldStart: oldLine, oldCount: 0, newStart: newLine, newCount: 0) }
                current!.oldCount += 1
                oldLine += 1
            case .insert:
                if current == nil { current = DiffHunk(oldStart: oldLine, oldCount: 0, newStart: newLine, newCount: 0) }
                current!.newCount += 1
                newLine += 1
            }
        }
        if let hunk = current { hunks.append(hunk) }
        return hunks
    }

    // MARK: - Applying and presenting

    /// Builds a text that takes the new side of each accepted hunk and the old
    /// side of every other hunk, for reviewing proposed edits hunk by hunk.
    public static func merge(old: [String], new: [String], hunks: [DiffHunk], accepted: Set<Int>) -> [String] {
        var result: [String] = []
        var oldIndex = 0
        for (index, hunk) in hunks.enumerated() {
            result.append(contentsOf: old[oldIndex..<hunk.oldStart])
            if accepted.contains(index) {
                result.append(contentsOf: new[hunk.newRange])
            } else {
                result.append(contentsOf: old[hunk.oldRange])
            }
            oldIndex = hunk.oldStart + hunk.oldCount
        }
        result.append(contentsOf: old[oldIndex...])
        return result
    }

    /// A unified diff (`git diff` format) with `context` lines around changes.
    public static func unified(oldText: String, newText: String, oldName: String = "a", newName: String = "b", context: Int = 3) -> String {
        let old = lines(of: oldText)
        let new = lines(of: newText)
        let hunks = diff(old: old, new: new)
        guard !hunks.isEmpty else { return "" }
        var output = "--- \(oldName)\n+++ \(newName)\n"
        var index = 0
        while index < hunks.count {
            // Merge hunks whose context windows overlap.
            var last = index
            while last + 1 < hunks.count, hunks[last + 1].oldStart - (hunks[last].oldStart + hunks[last].oldCount) <= context * 2 {
                last += 1
            }
            let first = hunks[index]
            let final = hunks[last]
            let oldStart = max(0, first.oldStart - context)
            let oldEnd = min(old.count, final.oldStart + final.oldCount + context)
            let newStart = max(0, first.newStart - context)
            let newEnd = min(new.count, final.newStart + final.newCount + context)
            output += "@@ -\(oldStart + 1),\(oldEnd - oldStart) +\(newStart + 1),\(newEnd - newStart) @@\n"
            var oldCursor = oldStart
            for hunk in hunks[index...last] {
                for line in old[oldCursor..<hunk.oldStart] { output += " \(line)\n" }
                for line in old[hunk.oldRange] { output += "-\(line)\n" }
                for line in new[hunk.newRange] { output += "+\(line)\n" }
                oldCursor = hunk.oldStart + hunk.oldCount
            }
            for line in old[oldCursor..<oldEnd] { output += " \(line)\n" }
            index = last + 1
        }
        return output
    }

    /// Character-level changes between two versions of a line, as UTF-16
    /// ranges, for highlighting what changed inside a modified line.
    public static func characterChanges(old: String, new: String) -> (removed: [NSRange], inserted: [NSRange]) {
        let a = Array(old.utf16).map(Int.init)
        let b = Array(new.utf16).map(Int.init)
        guard a.count + b.count <= 4_000, let operations = myers(a, b) else {
            return ([NSRange(location: 0, length: a.count)], [NSRange(location: 0, length: b.count)])
        }
        var removed: [NSRange] = []
        var inserted: [NSRange] = []
        var x = 0
        var y = 0
        for operation in operations {
            switch operation {
            case .equal:
                x += 1
                y += 1
            case .delete:
                if let last = removed.last, NSMaxRange(last) == x {
                    removed[removed.count - 1].length += 1
                } else {
                    removed.append(NSRange(location: x, length: 1))
                }
                x += 1
            case .insert:
                if let last = inserted.last, NSMaxRange(last) == y {
                    inserted[inserted.count - 1].length += 1
                } else {
                    inserted.append(NSRange(location: y, length: 1))
                }
                y += 1
            }
        }
        return (removed, inserted)
    }
}
