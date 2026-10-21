import Foundation

/// Readline-style line editing for terminals without a pty: turns the bytes a
/// terminal emulator sends for key presses into an edited line and the echo
/// to draw. Supports insertion anywhere, Backspace, Delete, arrows, Home/End,
/// history (Up/Down), ⌃A ⌃E ⌃U ⌃K ⌃W ⌃C ⌃L, and Tab completion requests.
public struct LineEditor: Sendable {
    public enum Event: Equatable, Sendable {
        /// Text to feed back to the terminal (echo and cursor movement).
        case output(String)
        /// Enter was pressed with this line.
        case submit(String)
        /// ⌃C: the line was abandoned.
        case interrupt
        /// ⌃L
        case clearScreen
        /// Tab: the caller should complete the current line.
        case complete(String)
    }

    public private(set) var buffer: [Character] = []
    public private(set) var cursor = 0
    private var historyIndex: Int?
    private var draft: [Character] = []
    private var pending: [UInt8] = []

    public init() {}

    public var line: String { String(buffer) }

    public mutating func reset() {
        clearLine()
        pending = []
    }

    /// Starts a new line, keeping input bytes that are still to be processed.
    private mutating func clearLine() {
        buffer = []
        cursor = 0
        historyIndex = nil
        draft = []
    }

    /// Processes input bytes; `history` is oldest first.
    public mutating func feed(_ bytes: some Sequence<UInt8>, history: [String]) -> [Event] {
        var events: [Event] = []
        var output = ""
        func flush() {
            if !output.isEmpty { events.append(.output(output)) }
            output = ""
        }
        pending.append(contentsOf: bytes)
        var index = 0
        while index < pending.count {
            let byte = pending[index]
            switch byte {
            case 0x1B:
                // Escape sequences: CSI (ESC [) and SS3 (ESC O).
                guard index + 2 < pending.count || (index + 1 < pending.count && pending[index + 1] != 0x5B && pending[index + 1] != 0x4F) else {
                    pending.removeFirst(index)
                    flush()
                    return events
                }
                if pending[index + 1] == 0x5B || pending[index + 1] == 0x4F {
                    var end = index + 2
                    while end < pending.count, !(0x40...0x7E).contains(pending[end]) { end += 1 }
                    guard end < pending.count else {
                        pending.removeFirst(index)
                        flush()
                        return events
                    }
                    let parameters = String(decoding: pending[(index + 2)..<end], as: UTF8.self)
                    output += handleEscape(final: pending[end], parameters: parameters, history: history)
                    index = end + 1
                } else {
                    index += 2
                }
                continue
            case 0x0D, 0x0A:
                // CR LF, as in pasted Windows text, is one Enter.
                if byte == 0x0A, index > 0, pending[index - 1] == 0x0D { break }
                output += "\r\n"
                flush()
                events.append(.submit(line))
                clearLine()
            case 0x7F, 0x08:
                output += backspace()
            case 0x03:
                output += "^C\r\n"
                flush()
                events.append(.interrupt)
                clearLine()
            case 0x0C:
                flush()
                events.append(.clearScreen)
            case 0x01:
                output += moveCursor(to: 0)
            case 0x05:
                output += moveCursor(to: buffer.count)
            case 0x15:
                output += replaceLine(with: Array(buffer[cursor...]), cursorAt: 0)
            case 0x0B:
                buffer.removeSubrange(cursor...)
                output += "\u{1B}[K"
            case 0x17:
                var start = cursor
                while start > 0, buffer[start - 1] == " " { start -= 1 }
                while start > 0, buffer[start - 1] != " " { start -= 1 }
                let removed = cursor - start
                guard removed > 0 else { break }
                buffer.removeSubrange(start..<cursor)
                let moved = cursor - start
                cursor = start
                output += "\u{1B}[\(moved)D" + String(buffer[cursor...]) + String(repeating: " ", count: removed) + "\u{1B}[\(buffer.count - cursor + removed)D"
            case 0x09:
                flush()
                events.append(.complete(line))
            default:
                guard byte >= 0x20 else { break }
                // Decode UTF-8, waiting for the rest of a multi-byte character.
                let length = byte < 0x80 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
                guard index + length <= pending.count else {
                    pending.removeFirst(index)
                    flush()
                    return events
                }
                let text = String(decoding: pending[index..<(index + length)], as: UTF8.self)
                output += insert(text)
                index += length
                continue
            }
            index += 1
        }
        pending.removeAll()
        flush()
        return events
    }

    /// Inserts completion text at the cursor and returns the echo.
    public mutating func insert(_ text: String) -> String {
        let characters = Array(text)
        buffer.insert(contentsOf: characters, at: cursor)
        cursor += characters.count
        let tail = String(buffer[cursor...])
        return text + tail + (tail.isEmpty ? "" : "\u{1B}[\(tail.count)D")
    }

    private mutating func backspace() -> String {
        guard cursor > 0 else { return "\u{07}" }
        buffer.remove(at: cursor - 1)
        cursor -= 1
        let tail = String(buffer[cursor...])
        return "\u{08}" + tail + " " + "\u{1B}[\(tail.count + 1)D"
    }

    private mutating func handleEscape(final: UInt8, parameters: String, history: [String]) -> String {
        switch final {
        case 0x44: return cursor > 0 ? moveCursor(to: cursor - 1) : ""
        case 0x43: return cursor < buffer.count ? moveCursor(to: cursor + 1) : ""
        case 0x48: return moveCursor(to: 0)
        case 0x46: return moveCursor(to: buffer.count)
        case 0x41: return recall(history: history, older: true)
        case 0x42: return recall(history: history, older: false)
        case 0x7E where parameters == "3":
            guard cursor < buffer.count else { return "" }
            buffer.remove(at: cursor)
            let tail = String(buffer[cursor...])
            return tail + " " + "\u{1B}[\(tail.count + 1)D"
        case 0x7E where parameters == "1" || parameters == "7": return moveCursor(to: 0)
        case 0x7E where parameters == "4" || parameters == "8": return moveCursor(to: buffer.count)
        default: return ""
        }
    }

    private mutating func moveCursor(to position: Int) -> String {
        let target = min(max(0, position), buffer.count)
        defer { cursor = target }
        if target < cursor { return "\u{1B}[\(cursor - target)D" }
        if target > cursor { return "\u{1B}[\(target - cursor)C" }
        return ""
    }

    private mutating func replaceLine(with characters: [Character], cursorAt position: Int) -> String {
        let back = cursor > 0 ? "\u{1B}[\(cursor)D" : ""
        buffer = characters
        cursor = min(position, buffer.count)
        let tail = buffer.count - cursor
        return back + "\u{1B}[K" + String(buffer) + (tail > 0 ? "\u{1B}[\(tail)D" : "")
    }

    private mutating func recall(history: [String], older: Bool) -> String {
        guard !history.isEmpty else { return "" }
        if historyIndex == nil {
            guard older else { return "" }
            draft = buffer
            historyIndex = history.count
        }
        var index = historyIndex! + (older ? -1 : 1)
        index = min(max(0, index), history.count)
        historyIndex = index
        let characters = index == history.count ? draft : Array(history[index])
        if index == history.count { historyIndex = nil }
        return replaceLine(with: characters, cursorAt: characters.count)
    }
}
