import Foundation

/// Describes how an edit changed the line structure of a document:
/// `removedLineCount` old lines starting at `firstLine` were replaced by
/// `insertedLineCount` new lines.
public struct LineEdit: Equatable, Sendable {
    public var firstLine: Int
    public var removedLineCount: Int
    public var insertedLineCount: Int

    public var lineDelta: Int { insertedLineCount - removedLineCount }
}

/// Maps between UTF-16 offsets (the coordinate system of `NSString`,
/// `NSTextStorage` and `UITextView`) and zero-based line numbers.
///
/// Line terminators follow VS Code: `\n`, `\r\n` and a lone `\r`. The index is
/// updated incrementally by `applyEdit`, which rescans only the lines an edit
/// touched and shifts the rest.
public struct LineIndex: Equatable, Sendable {
    /// UTF-16 offset of the first unit of each line. Never empty; starts with 0.
    public private(set) var lineStarts: [Int]
    /// UTF-16 length of the indexed text.
    public private(set) var length: Int

    public init(_ text: NSString) {
        var starts = [0]
        Self.scanLineStarts(in: text, from: 0, through: text.length, into: &starts)
        lineStarts = starts
        length = text.length
    }

    public init(_ text: String) {
        self.init(text as NSString)
    }

    public var lineCount: Int { lineStarts.count }

    /// The line containing `offset`. Offsets past the end clamp to the last line.
    public func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Range of `line` including its terminator.
    public func range(ofLine line: Int) -> NSRange {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// Range of `line` without its terminator.
    public func contentRange(ofLine line: Int, in text: NSString) -> NSRange {
        var range = range(ofLine: line)
        if range.length > 0 {
            let last = text.character(at: range.location + range.length - 1)
            if last == Self.lf {
                range.length -= 1
                if range.length > 0, text.character(at: range.location + range.length - 1) == Self.cr {
                    range.length -= 1
                }
            } else if last == Self.cr {
                range.length -= 1
            }
        }
        return range
    }

    /// Zero-based line and UTF-16 column of `offset`.
    public func position(of offset: Int) -> (line: Int, column: Int) {
        let clamped = min(max(offset, 0), length)
        let line = line(containing: clamped)
        return (line, clamped - lineStarts[line])
    }

    /// UTF-16 offset of a zero-based line and column, clamped to the line's content.
    public func offset(line: Int, column: Int, in text: NSString) -> Int {
        let line = min(max(line, 0), lineStarts.count - 1)
        let content = contentRange(ofLine: line, in: text)
        return content.location + min(max(column, 0), content.length)
    }

    /// Updates the index after `oldRange` (in the old text) was replaced by
    /// `replacementLength` UTF-16 units. `text` is the complete text after the edit.
    @discardableResult
    public mutating func applyEdit(oldRange: NSRange, replacementLength: Int, newText text: NSString) -> LineEdit {
        let delta = replacementLength - oldRange.length
        // Start one line early: inserting "\n" right after a lone "\r" turns it
        // into "\r\n", which removes the line break that used to follow the "\r".
        let firstLine = max(0, line(containing: oldRange.location) - 1)
        let lastLine = line(containing: oldRange.location + oldRange.length)
        let hasTail = lastLine + 1 < lineStarts.count

        var regionStarts: [Int] = []
        if hasTail {
            let nextStart = lineStarts[lastLine + 1] + delta
            Self.scanLineStarts(in: text, from: lineStarts[firstLine], through: nextStart - 1, into: &regionStarts)
            var updated = Array(lineStarts[0...firstLine])
            updated.append(contentsOf: regionStarts)
            updated.append(contentsOf: lineStarts[(lastLine + 1)...].lazy.map { $0 + delta })
            lineStarts = updated
        } else {
            Self.scanLineStarts(in: text, from: lineStarts[firstLine], through: text.length, into: &regionStarts)
            lineStarts.removeSubrange((firstLine + 1)...)
            lineStarts.append(contentsOf: regionStarts)
        }
        length = text.length
        return LineEdit(
            firstLine: firstLine,
            removedLineCount: lastLine - firstLine + 1,
            insertedLineCount: regionStarts.count + 1
        )
    }

    static let lf: unichar = 0x0A
    static let cr: unichar = 0x0D

    /// Appends the start offset of every line that begins at an offset `s` with
    /// `from < s <= through`, scanning the text in chunks.
    static func scanLineStarts(in text: NSString, from: Int, through: Int, into starts: inout [Int]) {
        let end = min(through, text.length)
        guard from < end else { return }
        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var position = from
        while position < end {
            let count = min(chunkSize, end - position)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: position, length: count))
            }
            for index in 0..<count {
                let unit = buffer[index]
                let offset = position + index
                if unit == lf {
                    if offset + 1 <= through { starts.append(offset + 1) }
                } else if unit == cr {
                    // "\r\n" is one terminator, recorded when the "\n" is seen.
                    let next = offset + 1 < text.length ? text.character(at: offset + 1) : 0
                    if next != lf, offset + 1 <= through { starts.append(offset + 1) }
                }
            }
            position += count
        }
    }
}
