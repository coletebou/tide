import Foundation

/// JSON with comments and trailing commas, the format of VS Code's
/// `settings.json`, `keybindings.json` and theme files.
public enum JSONC {
    public enum ParseError: Error, Equatable {
        case invalid(String)
    }

    /// Removes `//` and `/* */` comments and trailing commas, leaving strings intact.
    public static func strip(_ text: String) -> String {
        let units = Array(text.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var index = 0
        var inString = false
        while index < units.count {
            let unit = units[index]
            if inString {
                output.append(unit)
                if unit == CodeUnit.backslash, index + 1 < units.count {
                    output.append(units[index + 1])
                    index += 2
                    continue
                }
                if unit == CodeUnit.quote { inString = false }
                index += 1
                continue
            }
            if unit == CodeUnit.quote {
                inString = true
                output.append(unit)
                index += 1
            } else if unit == CodeUnit.slash, index + 1 < units.count, units[index + 1] == CodeUnit.slash {
                while index < units.count, units[index] != 0x0A { index += 1 }
            } else if unit == CodeUnit.slash, index + 1 < units.count, units[index + 1] == CodeUnit.asterisk {
                index += 2
                while index + 1 < units.count, !(units[index] == CodeUnit.asterisk && units[index + 1] == CodeUnit.slash) {
                    // Keep newlines so error positions still line up.
                    if units[index] == 0x0A { output.append(0x0A) }
                    index += 1
                }
                index += 2
            } else if unit == CodeUnit.comma {
                // Drop a comma followed only by whitespace/comments and a closing bracket.
                var lookahead = index + 1
                while lookahead < units.count {
                    let next = units[lookahead]
                    if CodeUnit.isWhitespace(next) || next == 0x0A || next == 0x0D {
                        lookahead += 1
                    } else if next == CodeUnit.slash, lookahead + 1 < units.count, units[lookahead + 1] == CodeUnit.slash {
                        while lookahead < units.count, units[lookahead] != 0x0A { lookahead += 1 }
                    } else if next == CodeUnit.slash, lookahead + 1 < units.count, units[lookahead + 1] == CodeUnit.asterisk {
                        lookahead += 2
                        while lookahead + 1 < units.count, !(units[lookahead] == CodeUnit.asterisk && units[lookahead + 1] == CodeUnit.slash) { lookahead += 1 }
                        lookahead += 2
                    } else {
                        break
                    }
                }
                if lookahead < units.count, units[lookahead] == CodeUnit.closeBrace || units[lookahead] == CodeUnit.closeBracket {
                    index += 1
                } else {
                    output.append(unit)
                    index += 1
                }
            } else {
                output.append(unit)
                index += 1
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// Parses JSONC into Foundation objects (dictionaries, arrays, strings, numbers, bools, NSNull).
    public static func parse(_ text: String) throws -> Any {
        let stripped = strip(text)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [String: Any]() }
        do {
            return try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            throw ParseError.invalid((error as NSError).localizedDescription)
        }
    }

    public static func parseObject(_ text: String) throws -> [String: Any] {
        guard let object = try parse(text) as? [String: Any] else {
            throw ParseError.invalid("Expected an object")
        }
        return object
    }
}
