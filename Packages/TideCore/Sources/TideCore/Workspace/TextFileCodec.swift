import Foundation

public enum LineEnding: String, CaseIterable, Codable, Sendable {
    case lf = "\n"
    case crlf = "\r\n"

    /// Status bar label: "LF" or "CRLF".
    public var label: String { self == .lf ? "LF" : "CRLF" }

    /// The dominant line ending in a text (LF when there are none).
    public static func detect(in text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                if previous == 0x0D { crlf += 1 } else { lf += 1 }
            }
            previous = unit
        }
        return crlf > lf ? .crlf : .lf
    }

    /// Rewrites every line ending in `text` to this one.
    public func normalize(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return self == .lf ? unified : unified.replacingOccurrences(of: "\n", with: "\r\n")
    }
}

public enum TextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8
    case utf8BOM = "utf8bom"
    case utf16LE = "utf16le"
    case utf16BE = "utf16be"
    case windows1252

    /// Status bar label, matching VS Code.
    public var label: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 with BOM"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .windows1252: "Western (Windows 1252)"
        }
    }
}

/// How a text file is stored, so saving writes it back the same way.
public struct TextFileFormat: Equatable, Codable, Sendable {
    public var encoding: TextEncoding
    public var lineEnding: LineEnding

    public init(encoding: TextEncoding = .utf8, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

/// Decodes file bytes into text and back.
public enum TextFileCodec {
    /// Git's heuristic: a NUL byte in the first 8000 bytes means binary,
    /// unless the file starts with a UTF-16 byte order mark.
    public static func isProbablyBinary(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return false }
        return data.prefix(8000).contains(0)
    }

    /// Decodes a file, or returns nil for binary data.
    public static func decode(_ data: Data) -> (text: String, format: TextFileFormat)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let text = String(decoding: data.dropFirst(3), as: UTF8.self)
            return (text, TextFileFormat(encoding: .utf8BOM, lineEnding: LineEnding.detect(in: text)))
        }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, TextFileFormat(encoding: .utf16LE, lineEnding: LineEnding.detect(in: text)))
        }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, TextFileFormat(encoding: .utf16BE, lineEnding: LineEnding.detect(in: text)))
        }
        if isProbablyBinary(data) { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return (text, TextFileFormat(encoding: .utf8, lineEnding: LineEnding.detect(in: text)))
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return (text, TextFileFormat(encoding: .windows1252, lineEnding: LineEnding.detect(in: text)))
        }
        return nil
    }

    /// Encodes text the way the file is stored. Throws rather than replace a
    /// character the encoding cannot represent, so saving never loses text.
    public static func encode(_ text: String, format: TextFileFormat) throws -> Data {
        switch format.encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LE:
            return Data([0xFF, 0xFE]) + (try losslessly(text, .utf16LittleEndian, format.encoding))
        case .utf16BE:
            return Data([0xFE, 0xFF]) + (try losslessly(text, .utf16BigEndian, format.encoding))
        case .windows1252:
            return try losslessly(text, .windowsCP1252, format.encoding)
        }
    }

    private static func losslessly(_ text: String, _ encoding: String.Encoding, _ name: TextEncoding) throws -> Data {
        if let data = text.data(using: encoding, allowLossyConversion: false) { return data }
        // A decomposed "é" is the same text as the composed one Windows-1252 has.
        let composed = text.precomposedStringWithCanonicalMapping
        if let data = composed.data(using: encoding, allowLossyConversion: false) { return data }
        let character = composed.first { String($0).data(using: encoding, allowLossyConversion: false) == nil } ?? "\u{FFFD}"
        throw WorkspaceError.unrepresentableCharacter(character, name)
    }
}
