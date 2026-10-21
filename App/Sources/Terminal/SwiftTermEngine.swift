import SwiftTerm
import TideCore
import UIKit

/// SwiftTerm as Tide's terminal engine. The only file that imports SwiftTerm.
final class SwiftTermEngine: TerminalEngine {
    var onInput: (([UInt8]) -> Void)?
    var onGridResize: ((TerminalGridSize) -> Void)?
    var onTitle: ((String) -> Void)?
    private let terminalView: TerminalView
    private let delegateBridge = TerminalDelegateBridge()

    init() {
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        terminalView.terminalDelegate = delegateBridge
        terminalView.accessibilityIdentifier = "terminal"
        delegateBridge.onSend = { [weak self] data in self?.onInput?(Array(data)) }
        delegateBridge.onSizeChanged = { [weak self] columns, rows in self?.onGridResize?(TerminalGridSize(columns: columns, rows: rows)) }
        delegateBridge.onTitle = { [weak self] title in self?.onTitle?(title) }
    }

    var view: UIView { terminalView }

    var gridSize: TerminalGridSize {
        let terminal = terminalView.getTerminal()
        return TerminalGridSize(columns: terminal.cols, rows: terminal.rows)
    }

    func feed(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
    }

    func apply(_ appearance: TerminalAppearance) {
        terminalView.installColors(appearance.ansiColors.map { color in
            SwiftTerm.Color(red: UInt16(color.red * 65535), green: UInt16(color.green * 65535), blue: UInt16(color.blue * 65535))
        })
        terminalView.nativeBackgroundColor = appearance.background
        terminalView.nativeForegroundColor = appearance.foreground
        terminalView.caretColor = appearance.cursor
        terminalView.font = appearance.font
        terminalView.getTerminal().setCursorStyle(Self.cursorStyle(appearance.cursorShape, blinking: appearance.cursorBlinks))
    }

    static func cursorStyle(_ shape: TerminalAppearance.CursorShape, blinking: Bool) -> CursorStyle {
        switch shape {
        case .bar: blinking ? .blinkBar : .steadyBar
        case .underline: blinking ? .blinkUnderline : .steadyUnderline
        case .block: blinking ? .blinkBlock : .steadyBlock
        }
    }

    func clear() {
        terminalView.feed(text: "\u{1B}[2J\u{1B}[3J\u{1B}[H")
    }

    func text() -> String {
        let data = terminalView.getTerminal().getBufferAsData(kind: .active)
        // The buffer always holds a full screen; drop the empty rows below the output.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\n+$", with: "\n", options: .regularExpression)
    }
}

/// SwiftTerm's delegate protocol, forwarded to closures.
final class TerminalDelegateBridge: NSObject, TerminalViewDelegate {
    var onSend: ((ArraySlice<UInt8>) -> Void)?
    var onTitle: ((String) -> Void)?
    var onSizeChanged: ((Int, Int) -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onSizeChanged?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onSend?(data) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
    /// OSC 52 can ask for the clipboard too, and the answer goes to the
    /// program in the terminal, which may run on another machine: a host
    /// could read a key or password copied here. Reads are refused; writes,
    /// such as a remote vim copying a selection, still reach the clipboard.
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
