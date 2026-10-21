import SwiftUI
import TideCore
import UIKit

extension RGBAColor {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(uiColor) }
}

extension Theme {
    func color(_ key: String) -> Color { self[key].color }
    func uiColor(_ key: String) -> UIColor { self[key].uiColor }

    /// The color for a token kind as UIKit color.
    func tokenColor(_ kind: TokenKind) -> UIColor {
        style(for: kind).color?.uiColor ?? uiColor("editor.foreground")
    }

    var colorScheme: ColorScheme { kind.isDark ? .dark : .light }

    /// A color an `opacity` step towards the foreground, for hover and pressed states.
    func tinted(_ key: String, opacity: Double) -> Color {
        Color(self[key].uiColor).opacity(opacity)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = BuiltinThemes.defaultDark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Editor fonts resolved from `editor.fontFamily` and `editor.fontSize`.
struct EditorFonts {
    let regular: UIFont
    let bold: UIFont
    let italic: UIFont
    let boldItalic: UIFont
    let lineHeight: CGFloat
    let characterWidth: CGFloat

    init(family: String, size: CGFloat, lineHeightSetting: Double = 0) {
        func make(_ weight: UIFont.Weight, italic: Bool) -> UIFont {
            var font: UIFont
            switch family {
            case "Menlo": font = UIFont(name: weight == .bold ? "Menlo-Bold" : "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
            case "Courier New": font = UIFont(name: weight == .bold ? "CourierNewPS-BoldMT" : "CourierNewPSMT", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
            default: font = .monospacedSystemFont(ofSize: size, weight: weight)
            }
            if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: descriptor, size: size)
            }
            return font
        }
        regular = make(.regular, italic: false)
        bold = make(.bold, italic: false)
        italic = make(.regular, italic: true)
        boldItalic = make(.bold, italic: true)
        // VS Code on macOS uses 1.5x the font size (GOLDEN_LINE_HEIGHT_RATIO).
        let multiple = lineHeightSetting > 0 ? lineHeightSetting : 1.5
        lineHeight = (size * multiple).rounded()
        characterWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
    }

    func font(bold: Bool, italic: Bool) -> UIFont {
        switch (bold, italic) {
        case (true, true): boldItalic
        case (true, false): self.bold
        case (false, true): self.italic
        default: regular
        }
    }
}
