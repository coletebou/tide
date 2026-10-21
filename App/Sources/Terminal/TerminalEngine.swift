import TideCore
import UIKit

/// The terminal emulator and its view: it turns a connection's output into a
/// screen, and keys, paste and mouse into input bytes for the connection.
/// SwiftTerm is the engine today. The seam stays small so that another engine
/// (libghostty-vt, if it earns the switch; see docs/reports) could replace it
/// without touching connections, and connections never see SwiftTerm types.
protocol TerminalEngine: AnyObject {
    /// The view the terminal panel hosts.
    var view: UIView { get }
    /// The grid's size now, in cells.
    var gridSize: TerminalGridSize { get }
    /// Bytes for the connection: keys, paste, mouse and replies to queries.
    var onInput: (([UInt8]) -> Void)? { get set }
    /// The grid changed size, as when the panel is resized.
    var onGridResize: ((TerminalGridSize) -> Void)? { get set }
    /// The program in the terminal set a title (OSC 0 or 2).
    var onTitle: ((String) -> Void)? { get set }
    /// Shows output from the connection.
    func feed(_ bytes: [UInt8])
    func apply(_ appearance: TerminalAppearance)
    /// Clears the screen and the scrollback.
    func clear()
    /// The scrollback and the screen as plain text, one line per row.
    func text() -> String
}

/// Colors, font and cursor in the engine's terms, read from the theme's
/// `terminal.*` colors and the `terminal.integrated.*` settings as VS Code does.
struct TerminalAppearance {
    enum CursorShape {
        case block, bar, underline
    }

    /// Black, red, green, yellow, blue, magenta, cyan and white, then their bright forms.
    var ansiColors: [RGBAColor]
    var foreground: UIColor
    var background: UIColor
    var cursor: UIColor
    var font: UIFont
    var cursorShape: CursorShape
    /// As in VS Code the cursor is steady unless blinking is turned on, which
    /// also spares the battery an endless animation.
    var cursorBlinks: Bool

    init(theme: Theme, settings: SettingsStore) {
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        ansiColors = (names.map { "terminal.ansi\($0)" } + names.map { "terminal.ansiBright\($0)" }).map { theme[$0] }
        foreground = theme.uiColor("terminal.foreground")
        background = theme.uiColor("terminal.background")
        cursor = theme.uiColor("terminalCursor.foreground")
        font = UIFont.monospacedSystemFont(ofSize: CGFloat(settings.number("terminal.integrated.fontSize")), weight: .regular)
        cursorShape = switch settings.string("terminal.integrated.cursorStyle") {
        case "line": .bar
        case "underline": .underline
        default: .block
        }
        cursorBlinks = settings.bool("terminal.integrated.cursorBlinking")
    }
}
