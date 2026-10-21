import Foundation

/// Character classification on UTF-16 code units. Tokenizers work on UTF-16 so
/// token offsets map directly onto `NSRange`s in the text storage.
enum CodeUnit {
    static let tab: UInt16 = 0x09
    static let space: UInt16 = 0x20
    static let quote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let dollar: UInt16 = 0x24
    static let apostrophe: UInt16 = 0x27
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    static let asterisk: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let comma: UInt16 = 0x2C
    static let minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A
    static let semicolon: UInt16 = 0x3B
    static let lessThan: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let greaterThan: UInt16 = 0x3E
    static let question: UInt16 = 0x3F
    static let at: UInt16 = 0x40
    static let openBracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let closeBracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let openBrace: UInt16 = 0x7B
    static let pipe: UInt16 = 0x7C
    static let closeBrace: UInt16 = 0x7D
    static let tilde: UInt16 = 0x7E
    static let exclamation: UInt16 = 0x21
    static let ampersand: UInt16 = 0x26

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    static func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
    static func isLetter(_ c: UInt16) -> Bool { isUpper(c) || isLower(c) }

    static func isHexDigit(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    /// Letters, `_`, and any non-ASCII unit (so identifiers in other scripts work).
    static func isIdentifierStart(_ c: UInt16) -> Bool {
        isLetter(c) || c == underscore || c >= 0x80
    }

    static func isIdentifierPart(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    static func isWhitespace(_ c: UInt16) -> Bool {
        c == space || c == tab || c == 0x0B || c == 0x0C || c == 0xA0 || c == 0xFEFF
    }

    static func isOperator(_ c: UInt16) -> Bool {
        switch c {
        case plus, minus, asterisk, slash, 0x25, equals, lessThan, greaterThan, exclamation,
             ampersand, pipe, 0x5E, tilde, question, colon, dot:
            return true
        default:
            return false
        }
    }
}

extension Array where Element == UInt16 {
    /// Whether `pattern` occurs at `index`.
    func hasPrefix(_ pattern: [UInt16], at index: Int) -> Bool {
        guard !pattern.isEmpty, index >= 0, index + pattern.count <= count else { return false }
        for offset in 0..<pattern.count where self[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// Case-insensitive ASCII version of `hasPrefix(_:at:)`.
    func hasPrefixIgnoringCase(_ pattern: [UInt16], at index: Int) -> Bool {
        guard !pattern.isEmpty, index >= 0, index + pattern.count <= count else { return false }
        for offset in 0..<pattern.count where Self.lower(self[index + offset]) != Self.lower(pattern[offset]) {
            return false
        }
        return true
    }

    /// Index of the first non-whitespace unit at or after `index`, or `count`.
    func skippingWhitespace(from index: Int) -> Int {
        var i = index
        while i < count, CodeUnit.isWhitespace(self[i]) { i += 1 }
        return i
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: self[range], as: UTF16.self)
    }

    static func lower(_ c: UInt16) -> UInt16 {
        CodeUnit.isUpper(c) ? c + 32 : c
    }
}

extension String {
    var utf16Array: [UInt16] { Array(utf16) }
}
