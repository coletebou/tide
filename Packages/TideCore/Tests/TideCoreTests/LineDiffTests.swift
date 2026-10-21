import Foundation
import Testing
@testable import TideCore

struct LineDiffTests {
    @Test func identicalTextsHaveNoHunks() {
        #expect(LineDiff.diff(oldText: "a\nb", newText: "a\nb").isEmpty)
    }

    @Test func classifiesHunks() {
        let hunks = LineDiff.diff(old: ["a", "b", "c", "d"], new: ["a", "x", "c", "d", "e"])
        #expect(hunks == [
            DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
            DiffHunk(oldStart: 4, oldCount: 0, newStart: 4, newCount: 1),
        ])
        #expect(hunks.map(\.kind) == [.modification, .insertion])
        #expect(LineDiff.diff(old: ["a", "b"], new: ["b"]).first?.kind == .deletion)
    }

    @Test func randomEditsRoundTrip() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<300 {
            let old = (0..<Int.random(in: 0...30, using: &rng)).map { _ in ["a", "b", "c", "d", "e"].randomElement(using: &rng)! }
            var new = old
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                let position = new.isEmpty ? 0 : Int.random(in: 0..<new.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: new.insert(["x", "y", "a"].randomElement(using: &rng)!, at: position)
                case 1: if !new.isEmpty { new.remove(at: position) }
                default: if !new.isEmpty { new[position] = "z" }
                }
            }
            let hunks = LineDiff.diff(old: old, new: new)
            // Accepting every hunk reproduces the new text, rejecting all keeps the old one.
            #expect(LineDiff.merge(old: old, new: new, hunks: hunks, accepted: Set(hunks.indices)) == new)
            #expect(LineDiff.merge(old: old, new: new, hunks: hunks, accepted: []) == old)
        }
    }

    @Test func acceptsSomeHunks() {
        let old = ["one", "two", "three", "four"]
        let new = ["ONE", "two", "three", "FOUR"]
        let hunks = LineDiff.diff(old: old, new: new)
        #expect(hunks.count == 2)
        #expect(LineDiff.merge(old: old, new: new, hunks: hunks, accepted: [1]) == ["one", "two", "three", "FOUR"])
    }

    @Test func unifiedDiffMatchesGitFormat() {
        let diff = LineDiff.unified(oldText: "a\nb\nc\n", newText: "a\nB\nc\n", oldName: "a/f.txt", newName: "b/f.txt")
        #expect(diff == "--- a/f.txt\n+++ b/f.txt\n@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n \n")
    }

    @Test func characterChangesWithinALine() {
        let changes = LineDiff.characterChanges(old: "let value = 1", new: "let total = 12")
        #expect(changes.removed.isEmpty == false)
        #expect(changes.inserted.contains(NSRange(location: 13, length: 1)))
    }

    @Test func largeRewritesCollapseIntoOneHunk() {
        let old = (0..<3000).map { "old \($0)" }
        let new = (0..<3000).map { "new \($0)" }
        let hunks = LineDiff.diff(old: old, new: new)
        #expect(hunks == [DiffHunk(oldStart: 0, oldCount: 3000, newStart: 0, newCount: 3000)])
    }
}
