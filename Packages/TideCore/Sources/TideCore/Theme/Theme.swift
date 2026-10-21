import Foundation

/// An sRGB color with alpha, parsed from VS Code's `#RGB`, `#RGBA`, `#RRGGBB`
/// and `#RRGGBBAA` notation.
public struct RGBAColor: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 || digits.count == 4 {
            digits = String(digits.flatMap { [$0, $0] })
        }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 6 {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        }
    }

    public var hexString: String {
        let components = [red, green, blue].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        return alpha >= 1 ? "#\(components)" : "#\(components)\(String(format: "%02X", Int((alpha * 255).rounded())))"
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// This color composited over an opaque `background`.
    public func flattened(over background: RGBAColor) -> RGBAColor {
        RGBAColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }

    /// Relative luminance (WCAG), for picking readable foregrounds.
    public var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
}

/// How a token kind is drawn.
public struct TokenStyle: Hashable, Codable, Sendable {
    public var color: RGBAColor?
    public var bold = false
    public var italic = false
    public var underline = false

    public init(color: RGBAColor? = nil, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    init(_ hex: String, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.init(color: RGBAColor(hex: hex), bold: bold, italic: italic, underline: underline)
    }
}

/// A color theme. Workbench colors use VS Code's color keys
/// (`editor.background`, `activityBar.foreground`, ...), so VS Code theme
/// files map onto Tide directly.
public struct Theme: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case dark
        case light
        case highContrast = "hc-black"
        case highContrastLight = "hc-light"

        public var isDark: Bool { self == .dark || self == .highContrast }
    }

    public let id: String
    public var name: String
    public var kind: Kind
    public var colors: [String: RGBAColor]
    public var tokenStyles: [TokenKind: TokenStyle]

    public init(id: String, name: String, kind: Kind, colors: [String: RGBAColor], tokenStyles: [TokenKind: TokenStyle]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.colors = colors
        self.tokenStyles = tokenStyles
    }

    /// The color for a workbench key, falling back to VS Code's default for this
    /// theme kind and finally to the theme's foreground.
    public subscript(_ key: String) -> RGBAColor {
        if let color = colors[key] { return color }
        if let fallback = ThemeDefaults.fallbackKeys[key], let color = colors[fallback] { return color }
        let defaults = kind.isDark ? ThemeDefaults.dark : ThemeDefaults.light
        if let color = defaults[key] { return color }
        // VS Code's color registry leaves unset backgrounds and borders
        // transparent; only foregrounds fall back to the theme's foreground.
        let lower = key.lowercased()
        if lower.contains("background") || lower.contains("border") || lower.contains("shadow") {
            return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        return colors["foreground"] ?? (kind.isDark ? RGBAColor(hex: "#CCCCCC")! : RGBAColor(hex: "#3B3B3B")!)
    }

    /// The style for a token kind; unstyled kinds use the editor foreground.
    public func style(for kind: TokenKind) -> TokenStyle {
        var style = tokenStyles[kind] ?? tokenStyles[ThemeDefaults.tokenFallback[kind] ?? .plain] ?? TokenStyle()
        if style.color == nil {
            style.color = self["editor.foreground"]
        }
        return style
    }

    public static func == (lhs: Theme, rhs: Theme) -> Bool {
        lhs.id == rhs.id && lhs.colors == rhs.colors && lhs.tokenStyles == rhs.tokenStyles
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Defaults used when a theme omits a key. Values follow VS Code's built-in
/// color registry defaults for dark and light themes.
enum ThemeDefaults {
    static let fallbackKeys: [String: String] = [
        "editorLineNumber.activeForeground": "editor.foreground",
        "sideBar.foreground": "foreground",
        "sideBarTitle.foreground": "sideBar.foreground",
        "sideBarSectionHeader.foreground": "sideBar.foreground",
        "sideBarSectionHeader.background": "sideBar.background",
        "panel.background": "editor.background",
        "terminal.background": "panel.background",
        "terminal.foreground": "editor.foreground",
        "tab.activeBackground": "editor.background",
        "tab.hoverBackground": "tab.activeBackground",
        "editorGroupHeader.tabsBackground": "tab.inactiveBackground",
        "quickInput.background": "editorWidget.background",
        "quickInput.foreground": "foreground",
        "titleBar.activeBackground": "activityBar.background",
        "titleBar.activeForeground": "foreground",
        "statusBar.border": "statusBar.background",
        "editorWidget.foreground": "foreground",
        "menu.background": "editorWidget.background",
        "notifications.background": "editorWidget.background",
        "breadcrumb.foreground": "descriptionForeground",
        "breadcrumb.background": "editor.background",
        "minimapSlider.background": "scrollbarSlider.background",
        "chat.requestBackground": "editorWidget.background",
        "editorGutter.background": "editor.background",
        "editorStickyScroll.background": "editor.background",
        "editorGroupHeader.tabsBorder": "tab.border",
        "sideBarSectionHeader.border": "sideBar.border",
        "notifications.border": "widget.border",
        "quickInputTitle.background": "quickInput.background",
        "welcomePage.tileBackground": "editorWidget.background",
        "terminalCursor.foreground": "editorCursor.foreground",
    ]

    static let tokenFallback: [TokenKind: TokenKind] = [
        .escape: .string,
        .property: .variable,
        .preprocessor: .keyword,
        .attribute: .keyword,
        .selector: .tag,
        .code: .string,
        .listMarker: .keyword,
    ]

    static let dark: [String: RGBAColor] = hexMap([
        "foreground": "#CCCCCC",
        "descriptionForeground": "#9D9D9D",
        "errorForeground": "#F85149",
        "focusBorder": "#0078D4",
        "icon.foreground": "#C5C5C5",
        "editor.background": "#1E1E1E",
        "editor.foreground": "#D4D4D4",
        "editorCursor.foreground": "#AEAFAD",
        "editor.selectionBackground": "#264F78",
        "editor.inactiveSelectionBackground": "#3A3D41",
        "editor.lineHighlightBorder": "#282828",
        "editor.findMatchBackground": "#515C6A",
        "editor.findMatchHighlightBackground": "#EA5C0055",
        "editor.wordHighlightBackground": "#575757B8",
        "editorBracketMatch.background": "#0064001A",
        "editorBracketMatch.border": "#888888",
        "editorIndentGuide.background1": "#404040",
        "editorIndentGuide.activeBackground1": "#707070",
        "editorWhitespace.foreground": "#E3E4E229",
        "editorLineNumber.foreground": "#858585",
        "editorError.foreground": "#F14C4C",
        "editorWarning.foreground": "#CCA700",
        "editorInfo.foreground": "#59A4F9",
        "editorBracketHighlight.foreground1": "#FFD700",
        "editorBracketHighlight.foreground2": "#DA70D6",
        "editorBracketHighlight.foreground3": "#179FFF",
        "editorBracketHighlight.unexpectedBracket.foreground": "#FF1212CC",
        "editorGutter.addedBackground": "#2EA043",
        "editorGutter.modifiedBackground": "#0078D4",
        "editorGutter.deletedBackground": "#F85149",
        "editorWidget.background": "#252526",
        "editorWidget.border": "#454545",
        "scrollbarSlider.background": "#79797966",
        "list.activeSelectionBackground": "#04395E",
        "list.activeSelectionForeground": "#FFFFFF",
        "list.inactiveSelectionBackground": "#37373D",
        "list.hoverBackground": "#2A2D2E",
        "list.highlightForeground": "#2AAAFF",
        "quickInputList.focusBackground": "#04395E",
        "pickerGroup.foreground": "#3794FF",
        "pickerGroup.border": "#3F3F46",
        "keybindingLabel.background": "#8080802B",
        "keybindingLabel.foreground": "#CCCCCC",
        "keybindingLabel.border": "#33333399",
        "badge.background": "#4D4D4D",
        "badge.foreground": "#FFFFFF",
        "button.background": "#0E639C",
        "button.foreground": "#FFFFFF",
        "input.background": "#3C3C3C",
        "input.foreground": "#CCCCCC",
        "input.placeholderForeground": "#A6A6A6",
        "inputOption.activeBackground": "#2489DB82",
        "inputOption.activeBorder": "#2488DB",
        "gitDecoration.modifiedResourceForeground": "#E2C08D",
        "gitDecoration.untrackedResourceForeground": "#73C991",
        "gitDecoration.addedResourceForeground": "#81B88B",
        "gitDecoration.deletedResourceForeground": "#C74E39",
        "gitDecoration.ignoredResourceForeground": "#8C8C8C",
        "gitDecoration.conflictingResourceForeground": "#E4676B",
        "diffEditor.insertedTextBackground": "#9CCC2C33",
        "diffEditor.removedTextBackground": "#FF000033",
        "diffEditor.insertedLineBackground": "#9BB95533",
        "diffEditor.removedLineBackground": "#FF000033",
        "textLink.foreground": "#3794FF",
        "textCodeBlock.background": "#0A0A0A66",
        "terminal.ansiBlack": "#000000", "terminal.ansiRed": "#CD3131", "terminal.ansiGreen": "#0DBC79",
        "terminal.ansiYellow": "#E5E510", "terminal.ansiBlue": "#2472C8", "terminal.ansiMagenta": "#BC3FBC",
        "terminal.ansiCyan": "#11A8CD", "terminal.ansiWhite": "#E5E5E5", "terminal.ansiBrightBlack": "#666666",
        "terminal.ansiBrightRed": "#F14C4C", "terminal.ansiBrightGreen": "#23D18B", "terminal.ansiBrightYellow": "#F5F543",
        "terminal.ansiBrightBlue": "#3B8EEA", "terminal.ansiBrightMagenta": "#D670D6", "terminal.ansiBrightCyan": "#29B8DB",
        "terminal.ansiBrightWhite": "#E5E5E5",
        "terminalCursor.foreground": "#FFFFFF",
    ])

    static let light: [String: RGBAColor] = hexMap([
        "foreground": "#616161",
        "descriptionForeground": "#717171",
        "errorForeground": "#A1260D",
        "focusBorder": "#0090F1",
        "icon.foreground": "#424242",
        "editor.background": "#FFFFFF",
        "editor.foreground": "#000000",
        "editorCursor.foreground": "#000000",
        "editor.selectionBackground": "#ADD6FF",
        "editor.inactiveSelectionBackground": "#E5EBF1",
        "editor.lineHighlightBorder": "#EEEEEE",
        "editor.findMatchBackground": "#A8AC94",
        "editor.findMatchHighlightBackground": "#EA5C0055",
        "editor.wordHighlightBackground": "#57575740",
        "editorBracketMatch.background": "#0064001A",
        "editorBracketMatch.border": "#B9B9B9",
        "editorIndentGuide.background1": "#D3D3D3",
        "editorIndentGuide.activeBackground1": "#939393",
        "editorWhitespace.foreground": "#33333333",
        "editorLineNumber.foreground": "#237893",
        "editorError.foreground": "#E51400",
        "editorWarning.foreground": "#BF8803",
        "editorInfo.foreground": "#0063D3",
        "editorBracketHighlight.foreground1": "#0431FA",
        "editorBracketHighlight.foreground2": "#319331",
        "editorBracketHighlight.foreground3": "#7B3814",
        "editorBracketHighlight.unexpectedBracket.foreground": "#FF1212CC",
        "editorGutter.addedBackground": "#2EA043",
        "editorGutter.modifiedBackground": "#005FB8",
        "editorGutter.deletedBackground": "#F85149",
        "editorWidget.background": "#F3F3F3",
        "editorWidget.border": "#C8C8C8",
        "scrollbarSlider.background": "#64646466",
        "list.activeSelectionBackground": "#0060C0",
        "list.activeSelectionForeground": "#FFFFFF",
        "list.inactiveSelectionBackground": "#E4E6F1",
        "list.hoverBackground": "#E8E8E8",
        "list.highlightForeground": "#0066BF",
        "quickInputList.focusBackground": "#0060C0",
        "pickerGroup.foreground": "#0066BF",
        "pickerGroup.border": "#CCCEDB",
        "keybindingLabel.background": "#DDDDDD66",
        "keybindingLabel.foreground": "#555555",
        "keybindingLabel.border": "#CCCCCC66",
        "badge.background": "#C4C4C4",
        "badge.foreground": "#333333",
        "button.background": "#007ACC",
        "button.foreground": "#FFFFFF",
        "input.background": "#FFFFFF",
        "input.foreground": "#616161",
        "input.placeholderForeground": "#767676",
        "inputOption.activeBackground": "#007ACC33",
        "inputOption.activeBorder": "#007ACC",
        "gitDecoration.modifiedResourceForeground": "#895503",
        "gitDecoration.untrackedResourceForeground": "#007100",
        "gitDecoration.addedResourceForeground": "#587C0C",
        "gitDecoration.deletedResourceForeground": "#AD0707",
        "gitDecoration.ignoredResourceForeground": "#8E8E90",
        "gitDecoration.conflictingResourceForeground": "#AD0707",
        "diffEditor.insertedTextBackground": "#9CCC2C40",
        "diffEditor.removedTextBackground": "#FF000033",
        "diffEditor.insertedLineBackground": "#9BB95533",
        "diffEditor.removedLineBackground": "#FF000033",
        "textLink.foreground": "#006AB1",
        "textCodeBlock.background": "#DCDCDC66",
        "terminal.ansiBlack": "#000000", "terminal.ansiRed": "#CD3131", "terminal.ansiGreen": "#107C10",
        "terminal.ansiYellow": "#949800", "terminal.ansiBlue": "#0451A5", "terminal.ansiMagenta": "#BC05BC",
        "terminal.ansiCyan": "#0598BC", "terminal.ansiWhite": "#555555", "terminal.ansiBrightBlack": "#666666",
        "terminal.ansiBrightRed": "#CD3131", "terminal.ansiBrightGreen": "#14CE14", "terminal.ansiBrightYellow": "#B5BA00",
        "terminal.ansiBrightBlue": "#0451A5", "terminal.ansiBrightMagenta": "#BC05BC", "terminal.ansiBrightCyan": "#0598BC",
        "terminal.ansiBrightWhite": "#A5A5A5",
        "terminalCursor.foreground": "#000000",
    ])

    static func hexMap(_ map: [String: String]) -> [String: RGBAColor] {
        map.compactMapValues(RGBAColor.init(hex:))
    }
}
