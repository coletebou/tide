import Foundation
import Testing
@testable import TideCore

private let swift = LanguageRegistry.shared.language(id: "swift")!
private let python = LanguageRegistry.shared.language(id: "python")!
private let html = LanguageRegistry.shared.language(id: "html")!

/// Applies an edit produced at the `|` marker (or `[...]` selection) and returns the result with the new caret or selection marked.
private func run(_ marked: String, _ operation: (NSString, NSRange) -> TextEdit?) -> String? {
    var text = marked
    var selection: NSRange
    if let open = text.range(of: "["), let close = text.range(of: "]") {
        let start = text.distance(from: text.startIndex, to: open.lowerBound)
        let end = text.distance(from: text.startIndex, to: close.lowerBound) - 1
        text.removeSubrange(close)
        text.removeSubrange(open)
        selection = NSRange(location: (String(text.prefix(start)) as NSString).length, length: (String(text.prefix(end)) as NSString).length - (String(text.prefix(start)) as NSString).length)
    } else {
        let caret = text.range(of: "|")!
        let offset = (String(text[..<caret.lowerBound]) as NSString).length
        text.removeSubrange(caret)
        selection = NSRange(location: offset, length: 0)
    }
    guard let edit = operation(text as NSString, selection) else { return nil }
    let result = edit.apply(to: text) as NSString
    if edit.selection.length == 0 {
        return result.replacingCharacters(in: edit.selection, with: "|")
    }
    let withClose = result.replacingCharacters(in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "]") as NSString
    return withClose.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "[")
}

struct TypingTests {
    @Test func autoClosesBracketsAndQuotes() {
        #expect(run("let a = |") { TextEditing.typeCharacter("(", in: $0, selection: $1, language: swift) } == "let a = (|)")
        #expect(run("x|") { TextEditing.typeCharacter("\"", in: $0, selection: $1, language: swift) } == nil)
        #expect(run("print(|)") { TextEditing.typeCharacter("\"", in: $0, selection: $1, language: swift) } == "print(\"|\")")
        // Not before a word character.
        #expect(run("|abc") { TextEditing.typeCharacter("(", in: $0, selection: $1, language: swift) } == nil)
    }

    @Test func typesOverClosers() {
        #expect(run("f(|)") { TextEditing.typeCharacter(")", in: $0, selection: $1, language: swift) } == "f()|")
        #expect(run("\"abc|\"") { TextEditing.typeCharacter("\"", in: $0, selection: $1, language: swift, isInStringOrComment: true) } == "\"abc\"|")
    }

    @Test func surroundsSelections() {
        #expect(run("let [value]") { TextEditing.typeCharacter("(", in: $0, selection: $1, language: swift) } == "let ([value])")
        #expect(run("[word]") { TextEditing.typeCharacter("\"", in: $0, selection: $1, language: swift) } == "\"[word]\"")
    }

    @Test func closingBraceSnapsToOpenerIndentation() {
        let input = "func f() {\n    if x {\n        |"
        #expect(run(input) { TextEditing.typeCharacter("}", in: $0, selection: $1, language: swift) } == "func f() {\n    if x {\n    }|")
    }
}

struct NewlineTests {
    @Test func keepsIndentation() {
        #expect(run("    let a = 1|") { TextEditing.newline(in: $0, selection: $1, language: swift) } == "    let a = 1\n    |")
    }

    @Test func indentsAfterOpeningBracket() {
        #expect(run("func f() {|") { TextEditing.newline(in: $0, selection: $1, language: swift) } == "func f() {\n    |")
    }

    @Test func splitsBracketPairs() {
        #expect(run("func f() {|}") { TextEditing.newline(in: $0, selection: $1, language: swift) } == "func f() {\n    |\n}")
        #expect(run("  (|)") { TextEditing.newline(in: $0, selection: $1, language: swift, indentation: Indentation(tabSize: 2)) } == "  (\n    |\n  )")
    }

    @Test func pythonIndentsAfterColonAndDedentsAfterReturn() {
        #expect(run("def f():|") { TextEditing.newline(in: $0, selection: $1, language: python) } == "def f():\n    |")
        #expect(run("def f():\n    return 1|") { TextEditing.newline(in: $0, selection: $1, language: python) } == "def f():\n    return 1\n|")
    }

    @Test func usesTabsWhenConfigured() {
        #expect(run("\tif x {|") { TextEditing.newline(in: $0, selection: $1, language: swift, indentation: Indentation(tabSize: 4, insertSpaces: false)) } == "\tif x {\n\t\t|")
    }
}

struct DeletionTests {
    @Test func deletesEmptyPairs() {
        #expect(run("f(|)") { TextEditing.deleteBackward(in: $0, selection: $1, language: swift) } == "f|")
        #expect(run("\"|\"") { TextEditing.deleteBackward(in: $0, selection: $1, language: swift) } == "|")
    }

    @Test func deletesToPreviousTabStop() {
        #expect(run("        |x") { TextEditing.deleteBackward(in: $0, selection: $1, language: swift) } == "    |x")
        #expect(run("      |x") { TextEditing.deleteBackward(in: $0, selection: $1, language: swift) } == "    |x")
        #expect(run("a |") { TextEditing.deleteBackward(in: $0, selection: $1, language: swift) } == nil)
    }
}

struct LineCommandTests {
    @Test func togglesLineComments() {
        let commented = run("[let a = 1\n    let b = 2]") { TextEditing.toggleLineComment(in: $0, selection: $1, language: swift) }
        #expect(commented == "[// let a = 1\n//     let b = 2]")
        let uncommented = run("[// let a = 1\n//     let b = 2]") { TextEditing.toggleLineComment(in: $0, selection: $1, language: swift) }
        #expect(uncommented == "[let a = 1\n    let b = 2]")
        #expect(run("    x|") { TextEditing.toggleLineComment(in: $0, selection: $1, language: python) } == "    # x|")
    }

    @Test func blockCommentsForLanguagesWithoutLineComments() {
        #expect(run("<p>|hi</p>") { TextEditing.toggleLineComment(in: $0, selection: $1, language: html) } == "[<!-- <p>hi</p> -->]")
        #expect(run("<!-- <p>|hi</p> -->") { TextEditing.toggleLineComment(in: $0, selection: $1, language: html) } == "[<p>hi</p>]")
    }

    @Test func indentsAndOutdents() {
        #expect(run("[a\nb]") { TextEditing.indentLines(in: $0, selection: $1) } == "[    a\n    b]")
        #expect(run("[    a\n  b]") { TextEditing.outdentLines(in: $0, selection: $1) } == "[a\nb]")
        #expect(run("\tx|") { TextEditing.outdentLines(in: $0, selection: $1) } == "x|")
    }

    @Test func tabInsertsToNextStop() {
        #expect(run("ab|") { TextEditing.insertTab(in: $0, selection: $1) } == "ab  |")
        #expect(run("|") { TextEditing.insertTab(in: $0, selection: $1, indentation: Indentation(insertSpaces: false)) } == "\t|")
    }

    @Test func movesLines() {
        #expect(run("one\ntw|o\nthree") { TextEditing.moveLines(up: true, in: $0, selection: $1) } == "tw|o\none\nthree")
        #expect(run("one\ntw|o\nthree") { TextEditing.moveLines(up: false, in: $0, selection: $1) } == "one\nthree\ntw|o")
        #expect(run("on|e\ntwo") { TextEditing.moveLines(up: true, in: $0, selection: $1) } == nil)
    }

    @Test func duplicatesAndDeletesLines() {
        #expect(run("a\nb|\nc") { TextEditing.duplicateLines(in: $0, selection: $1) } == "a\nb\nb|\nc")
        #expect(run("a\nb|\nc") { TextEditing.deleteLines(in: $0, selection: $1) } == "a\n|c")
        #expect(run("a\nb|") { TextEditing.deleteLines(in: $0, selection: $1) } == "a|")
    }

    /// Line commands keep each line break as it was, so CRLF text stays CRLF.
    @Test func lineCommandsKeepCRLFLineBreaks() {
        #expect(run("a\r\nb|\r\nc") { TextEditing.moveLines(up: false, in: $0, selection: $1) } == "a\r\nc\r\nb|")
        #expect(run("a\r\nb\r\nc|") { TextEditing.moveLines(up: true, in: $0, selection: $1) } == "a\r\nc|\r\nb")
        #expect(run("a\r\nb|\r\nc") { TextEditing.moveLines(up: true, in: $0, selection: $1) } == "b|\r\na\r\nc")
        #expect(run("[a\r\nb]\r\nc") { TextEditing.moveLines(up: false, in: $0, selection: $1) } == "c\r\n[a\r\nb]")
        #expect(run("a\r\nb|\r\nc") { TextEditing.duplicateLines(in: $0, selection: $1) } == "a\r\nb\r\nb|\r\nc")
        #expect(run("a\r\nb|") { TextEditing.duplicateLines(in: $0, selection: $1) } == "a\r\nb\r\nb|")
        #expect(run("a\r\nb|\r\nc") { TextEditing.deleteLines(in: $0, selection: $1) } == "a\r\n|c")
        #expect(run("a\r\nb|") { TextEditing.deleteLines(in: $0, selection: $1) } == "a|")
        // A blank CRLF line is blank: it is neither indented nor commented.
        #expect(run("[a\r\n\r\nb]") { TextEditing.indentLines(in: $0, selection: $1) } == "[    a\r\n\r\n    b]")
        #expect(run("[// a\r\n\r\n// b]") { TextEditing.toggleLineComment(in: $0, selection: $1, language: swift) } == "[a\r\n\r\nb]")
    }

    /// A selection that ends after a blank line includes that line: its
    /// content is empty, so the block's content ends where it starts.
    @Test(arguments: ["\n", "\r\n"])
    func blocksEndingOnABlankLine(n: String) {
        #expect(run("[a\(n)\(n)]b") { TextEditing.deleteLines(in: $0, selection: $1) } == "|b")
        #expect(run("[a\(n)\(n)]b") { TextEditing.moveLines(up: false, in: $0, selection: $1) } == "b\(n)[a\(n)]")
        #expect(run("x\(n)[a\(n)\(n)]b") { TextEditing.moveLines(up: true, in: $0, selection: $1) } == "[a\(n)\(n)]x\(n)b")
        #expect(run("[a\(n)\(n)]b") { TextEditing.duplicateLines(in: $0, selection: $1) } == "a\(n)\(n)[a\(n)\(n)]b")
        // Here the blank line is followed only by the empty line that ends the document.
        #expect(run("[a\(n)\(n)]") { TextEditing.deleteLines(in: $0, selection: $1) } == "|")
        #expect(run("[a\(n)\(n)]") { TextEditing.moveLines(up: false, in: $0, selection: $1) } == "\(n)[a\(n)]")
        #expect(run("x\(n)[a\(n)\(n)]") { TextEditing.moveLines(up: true, in: $0, selection: $1) } == "[a\(n)\(n)]x\(n)")
    }

    /// A duplicate copies each line's own break: here CRLF, then LF on the blank line.
    @Test func duplicatesMixedLineBreaksAsTheyAre() {
        #expect(run("[a\r\n\n]b") { TextEditing.duplicateLines(in: $0, selection: $1) } == "a\r\n\n[a\r\n\n]b")
    }

    /// A whole-line selection runs to the start of the next line. Moved down
    /// onto the last line, which has no line break, it must still end inside the text.
    @Test(arguments: ["\n", "\r\n"])
    func movingDownOntoTheLastLineKeepsTheSelectionInBounds(n: String) throws {
        let text = "a\(n)b" as NSString
        let edit = try #require(TextEditing.moveLines(up: false, in: text, selection: NSRange(location: 0, length: text.length - 1)))
        #expect(edit.apply(to: text as String) == "b\(n)a")
        #expect(edit.selection == NSRange(location: text.length - 1, length: 1))
    }

    @Test func movesLinesPastAnEmptyLastLine() {
        #expect(run("a\nb|\n") { TextEditing.moveLines(up: false, in: $0, selection: $1) } == "a\n\nb|")
        #expect(run("a\n|") { TextEditing.moveLines(up: true, in: $0, selection: $1) } == "|\na")
        #expect(run("a\n|") { TextEditing.moveLines(up: false, in: $0, selection: $1) } == nil)
    }
}

struct BracketMatchingTests {
    @Test func findsMatchingBrackets() {
        let text = "func f(a: [Int]) { g(a) }" as NSString
        #expect(TextEditing.matchingBracket(at: 6, in: text, language: swift)! == (6, 15))
        #expect(TextEditing.matchingBracket(at: 17, in: text, language: swift)! == (17, 24))
        #expect(TextEditing.matchingBracket(at: 24, in: text, language: swift)! == (17, 24))
        #expect(TextEditing.matchingBracket(at: 2, in: text, language: swift) == nil)
    }

    @Test func skipsBracketsOutsideCode() {
        let text = "f(\")\")" as NSString
        let isCode: (Int) -> Bool = { $0 != 3 }
        #expect(TextEditing.matchingBracket(at: 1, in: text, language: swift, isCode: isCode)! == (1, 5))
    }
}

struct IndentationDetectionTests {
    @Test func detectsSpacesTabsAndWidth() {
        #expect(Indentation.detect(in: "a\n  b\n    c\n  d\n") == Indentation(tabSize: 2, insertSpaces: true))
        #expect(Indentation.detect(in: "a\n\tb\n\t\tc\n") == Indentation(tabSize: 4, insertSpaces: false))
        #expect(Indentation.detect(in: "plain\ntext\n") == Indentation())
    }
}
