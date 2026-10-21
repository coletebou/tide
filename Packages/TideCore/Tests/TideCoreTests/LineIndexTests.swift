import Foundation
import Testing
@testable import TideCore

struct LineIndexTests {
    @Test func recognizesAllLineTerminators() {
        let index = LineIndex("a\nb\r\nc\rd")
        #expect(index.lineStarts == [0, 2, 5, 7])
        #expect(index.lineCount == 4)
    }

    @Test func trailingNewlineStartsAnEmptyLine() {
        #expect(LineIndex("a\n").lineStarts == [0, 2])
        #expect(LineIndex("").lineStarts == [0])
        #expect(LineIndex("\r\n\r\n").lineStarts == [0, 2, 4])
    }

    @Test func contentRangeExcludesTerminator() {
        let text = "ab\r\ncd\n" as NSString
        let index = LineIndex(text)
        #expect(index.contentRange(ofLine: 0, in: text) == NSRange(location: 0, length: 2))
        #expect(index.contentRange(ofLine: 1, in: text) == NSRange(location: 4, length: 2))
        #expect(index.contentRange(ofLine: 2, in: text) == NSRange(location: 7, length: 0))
    }

    @Test func convertsBetweenOffsetsAndPositions() {
        let text = "one\ntwo\nthree" as NSString
        let index = LineIndex(text)
        #expect(index.position(of: 0) == (0, 0))
        #expect(index.position(of: 5) == (1, 1))
        #expect(index.position(of: 13) == (2, 5))
        #expect(index.offset(line: 2, column: 2, in: text) == 10)
        #expect(index.offset(line: 0, column: 99, in: text) == 3)
    }

    @Test func joiningCRAndLFRemovesALine() {
        let original = "a\rb" as NSString
        var index = LineIndex(original)
        #expect(index.lineCount == 2)
        let edited = "a\r\nb" as NSString
        let edit = index.applyEdit(oldRange: NSRange(location: 2, length: 0), replacementLength: 1, newText: edited)
        #expect(index == LineIndex(edited))
        #expect(edit.lineDelta == 0)
    }

    @Test func randomEditsMatchAFullRebuild() {
        var rng = SeededGenerator(seed: 42)
        let pieces = ["a", "bc", " ", "\n", "\r", "\r\n", "xyz\n", "\n\n"]
        var text = NSMutableString(string: "hello\nworld\r\nthis\ris a test\n")
        var index = LineIndex(text)
        for _ in 0..<3000 {
            let location = Int.random(in: 0...text.length, using: &rng)
            let length = Int.random(in: 0...min(6, text.length - location), using: &rng)
            let insertion = (0..<Int.random(in: 0...3, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            let oldLineCount = index.lineCount
            text.replaceCharacters(in: NSRange(location: location, length: length), with: insertion)
            let edit = index.applyEdit(
                oldRange: NSRange(location: location, length: length),
                replacementLength: (insertion as NSString).length,
                newText: text
            )
            let rebuilt = LineIndex(text)
            #expect(index == rebuilt, "after replacing \(location),\(length) with \(insertion.debugDescription)")
            #expect(oldLineCount + edit.lineDelta == rebuilt.lineCount)
            if index != rebuilt { return }
            if text.length > 400 { text = NSMutableString(string: text.substring(to: 100)); index = LineIndex(text) }
        }
    }
}
