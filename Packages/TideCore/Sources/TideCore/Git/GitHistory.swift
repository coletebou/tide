import Foundation

extension GitRepository {
    /// Counts the commits reachable from `local` but not `upstream` (ahead) and
    /// the reverse (behind), like `git rev-list --left-right --count local...upstream`.
    ///
    /// The walk visits newest commits first and stops once every commit still
    /// queued is reachable from both sides, plus a few extra steps to absorb
    /// small clock skew. Missing parents (shallow clones) end the walk on that side.
    public func aheadBehind(local: GitObjectID, upstream: GitObjectID) throws -> (ahead: Int, behind: Int) {
        if local == upstream { return (0, 0) }
        let shallow = shallowCommits()
        var walk = AheadBehindWalk()
        var commits: [GitObjectID: (time: Int64, parents: [GitObjectID])] = [:]

        func load(_ id: GitObjectID) throws -> (time: Int64, parents: [GitObjectID])? {
            if let known = commits[id] { return known }
            guard let commit = try? peelToCommit(id) else { return nil }
            let parents = shallow.contains(commit.id) ? [] : commit.parents
            let info = (commit.committer?.time ?? commit.author?.time ?? 0, parents)
            commits[id] = info
            return info
        }

        for (id, side) in [(local, AheadBehindWalk.local), (upstream, AheadBehindWalk.upstream)] {
            guard let info = try load(id) else { throw GitError.notFound("commit \(id)") }
            walk.mark(id, side, time: info.time)
        }
        var slop = 5
        while let id = walk.pop() {
            let flags = walk.flags[id] ?? 0
            for parent in try load(id)?.parents ?? [] {
                guard let info = try load(parent) else { continue }
                walk.mark(parent, flags, time: info.time)
            }
            // Check after queuing the parents: popping the last one-sided commit
            // leaves the count at zero even when its parents continue that history.
            if walk.nonStaleCount == 0 {
                if slop == 0 { break }
                slop -= 1
            }
        }
        var ahead = 0
        var behind = 0
        for flags in walk.flags.values {
            if flags == AheadBehindWalk.local { ahead += 1 }
            if flags == AheadBehindWalk.upstream { behind += 1 }
        }
        return (ahead, behind)
    }

    /// Commits listed in `shallow`, whose parents are absent by design.
    func shallowCommits() -> Set<GitObjectID> {
        guard let data = try? GitFile.readIfExists(commonDirectory.appendingPathComponent("shallow")) else { return [] }
        return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { GitObjectID(hex: $0) })
    }
}

/// State of the ahead/behind walk: which sides reach each commit, and a queue
/// ordered by commit time that tracks how many queued commits are not yet
/// known to be reachable from both sides.
private struct AheadBehindWalk {
    static let local: UInt8 = 1
    static let upstream: UInt8 = 2
    static let both: UInt8 = 3

    private(set) var flags: [GitObjectID: UInt8] = [:]
    private(set) var nonStaleCount = 0
    private var queued = Set<GitObjectID>()
    private var heap: [(time: Int64, id: GitObjectID)] = []

    /// Adds `side` to the commit's flags and queues it when that changes them.
    mutating func mark(_ id: GitObjectID, _ side: UInt8, time: Int64) {
        let old = flags[id] ?? 0
        let new = old | side
        guard new != old else { return }
        flags[id] = new
        if queued.contains(id) {
            if new == Self.both { nonStaleCount -= 1 }
        } else {
            queued.insert(id)
            push((time, id))
            if new != Self.both { nonStaleCount += 1 }
        }
    }

    /// Removes the newest queued commit.
    mutating func pop() -> GitObjectID? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        siftDown(0)
        queued.remove(top.id)
        if flags[top.id] != Self.both { nonStaleCount -= 1 }
        return top.id
    }

    private mutating func push(_ item: (time: Int64, id: GitObjectID)) {
        heap.append(item)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isNewer(heap[child], than: heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var newest = parent
            if left < heap.count, Self.isNewer(heap[left], than: heap[newest]) { newest = left }
            if right < heap.count, Self.isNewer(heap[right], than: heap[newest]) { newest = right }
            if newest == parent { return }
            heap.swapAt(parent, newest)
            parent = newest
        }
    }

    private static func isNewer(_ lhs: (time: Int64, id: GitObjectID), than rhs: (time: Int64, id: GitObjectID)) -> Bool {
        lhs.time != rhs.time ? lhs.time > rhs.time : lhs.id < rhs.id
    }
}
