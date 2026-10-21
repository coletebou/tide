import Foundation

/// Imports a VS Code color theme (`*-color-theme.json`): workbench `colors`
/// carry over by key, and `tokenColors` TextMate rules are resolved onto
/// Tide's token kinds by matching each kind's representative scopes.
public enum VSCodeThemeImporter {
    public enum ImportError: Error, Equatable {
        case notATheme
    }

    /// Representative TextMate scopes per token kind, most specific first.
    static let representativeScopes: [TokenKind: [String]] = [
        .comment: ["comment.line", "comment"],
        .string: ["string.quoted", "string"],
        .escape: ["constant.character.escape", "constant.character"],
        .number: ["constant.numeric"],
        .keyword: ["storage.type", "storage.modifier", "storage", "keyword"],
        .control: ["keyword.control.flow", "keyword.control", "keyword"],
        .type: ["entity.name.type", "entity.name.class", "support.type", "support.class", "storage.type"],
        .function: ["entity.name.function", "support.function", "meta.function-call"],
        .variable: ["variable.other.readwrite", "variable.other", "variable"],
        .property: ["variable.other.property", "support.variable.property", "meta.object-literal.key", "variable.other.object.property", "variable"],
        .constant: ["constant.language", "variable.other.constant", "constant"],
        .operatorSymbol: ["keyword.operator"],
        .punctuation: ["punctuation"],
        .attribute: ["storage.modifier.attribute", "meta.decorator", "entity.name.function.decorator", "storage.type.annotation"],
        .preprocessor: ["keyword.control.directive", "meta.preprocessor", "keyword.control.import"],
        .regex: ["string.regexp"],
        .tag: ["entity.name.tag"],
        .attributeName: ["entity.other.attribute-name"],
        .selector: ["entity.other.attribute-name.class.css", "entity.name.tag.css", "entity.other.attribute-name"],
        .heading: ["markup.heading", "entity.name.section.markdown"],
        .emphasis: ["markup.italic"],
        .strong: ["markup.bold"],
        .link: ["markup.underline.link", "string.other.link"],
        .code: ["markup.inline.raw", "markup.fenced_code", "markup.raw"],
        .quote: ["markup.quote"],
        .listMarker: ["punctuation.definition.list.begin.markdown", "markup.list"],
        .inserted: ["markup.inserted"],
        .deleted: ["markup.deleted"],
        .invalid: ["invalid.illegal", "invalid"],
    ]

    private struct Rule {
        var scope: String
        var foreground: RGBAColor?
        var fontStyle: String?
    }

    public static func importTheme(from text: String, id: String? = nil) throws -> Theme {
        let object = try JSONC.parseObject(text)
        let colorsObject = object["colors"] as? [String: Any]
        let tokenColors = object["tokenColors"] as? [[String: Any]]
        guard colorsObject != nil || tokenColors != nil else { throw ImportError.notATheme }

        let name = object["name"] as? String ?? "Imported Theme"
        let kind: Theme.Kind
        switch (object["type"] as? String)?.lowercased() {
        case "light": kind = .light
        case "hc-black", "hc": kind = .highContrast
        case "hc-light": kind = .highContrastLight
        default: kind = .dark
        }

        var colors: [String: RGBAColor] = [:]
        for (key, value) in colorsObject ?? [:] {
            if let hex = value as? String, let color = RGBAColor(hex: hex) {
                colors[key] = color
            }
        }

        let rules = parseRules(tokenColors ?? [])
        // A rule without a scope sets the default foreground.
        if colors["editor.foreground"] == nil, let base = rules.first(where: { $0.scope.isEmpty })?.foreground {
            colors["editor.foreground"] = base
        }

        var styles: [TokenKind: TokenStyle] = [:]
        for kind in TokenKind.allCases {
            guard let scopes = representativeScopes[kind] else { continue }
            for scope in scopes {
                if let style = resolve(scope: scope, rules: rules) {
                    styles[kind] = style
                    break
                }
            }
        }
        let identifier = id ?? "imported-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
        return Theme(id: identifier, name: name, kind: kind, colors: colors, tokenStyles: styles)
    }

    private static func parseRules(_ entries: [[String: Any]]) -> [Rule] {
        var rules: [Rule] = []
        for entry in entries {
            let settings = entry["settings"] as? [String: Any] ?? [:]
            let foreground = (settings["foreground"] as? String).flatMap(RGBAColor.init(hex:))
            let fontStyle = settings["fontStyle"] as? String
            var scopes: [String] = []
            if let scope = entry["scope"] as? String {
                scopes = scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let list = entry["scope"] as? [String] {
                scopes = list
            } else {
                scopes = [""]
            }
            for scope in scopes {
                // Descendant selectors ("source.js meta.x") apply in narrower
                // contexts than Tide models; use their last segment only when
                // nothing simpler matches (handled by specificity ordering).
                rules.append(Rule(scope: scope, foreground: foreground, fontStyle: fontStyle))
            }
        }
        return rules
    }

    /// TextMate matching: rule `r` matches scope `s` when `s == r` or `s`
    /// starts with `r + "."`. The longest (most specific) matching rule wins;
    /// later rules win ties, as in VS Code.
    private static func resolve(scope: String, rules: [Rule]) -> TokenStyle? {
        var best: (specificity: Int, rule: Rule)?
        for rule in rules where !rule.scope.isEmpty {
            let isDescendant = rule.scope.contains(" ")
            let selector = isDescendant ? String(rule.scope.split(separator: " ").last ?? "") : rule.scope
            guard scope == selector || scope.hasPrefix(selector + ".") else { continue }
            // Descendant selectors rank below plain selectors of equal length.
            let specificity = selector.count * 2 - (isDescendant ? 1 : 0)
            if best == nil || specificity >= best!.specificity {
                best = (specificity, rule)
            }
        }
        guard let rule = best?.rule, rule.foreground != nil || rule.fontStyle != nil else { return nil }
        let fontStyle = rule.fontStyle ?? ""
        return TokenStyle(
            color: rule.foreground,
            bold: fontStyle.contains("bold"),
            italic: fontStyle.contains("italic"),
            underline: fontStyle.contains("underline")
        )
    }
}
