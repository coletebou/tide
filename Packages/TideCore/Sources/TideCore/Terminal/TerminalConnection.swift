import Foundation

/// A terminal's size in character cells, plus pixels when the view knows
/// them (SSH carries both in its window-change request).
public struct TerminalGridSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// How a terminal's shell ended.
public enum TerminalExit: Equatable, Sendable {
    /// The shell exited with this status.
    case status(Int32)
    /// The connection failed or dropped; the message says why.
    case failure(String)
}

/// What a connection reports to its terminal, in order.
public enum TerminalConnectionEvent: Equatable, Sendable {
    /// Bytes for the terminal to show.
    case output([UInt8])
    /// A new title for the terminal's tab.
    case title(String)
    /// Workspace files to open in editors, as the built-in shell's `code` asks.
    case openFiles([String])
    /// The shell ended. No events follow.
    case ended(TerminalExit)
}

/// What runs in a terminal: Tide's built-in shell, or a shell on an SSH host.
/// The terminal engine hands a connection the bytes that keys, paste and the
/// terminal's replies to queries produce, and shows the output it reports.
/// Neither side knows the other's type, so any engine (SwiftTerm today,
/// libghostty-vt if it earns the switch) works with any connection.
@MainActor
public protocol TerminalConnection: AnyObject {
    /// Receives the connection's events, on the main actor and in order.
    var onEvent: ((TerminalConnectionEvent) -> Void)? { get set }
    /// Starts the shell for a terminal of this size.
    func start(size: TerminalGridSize)
    /// Input from the terminal: key presses, pasted text, replies to queries.
    func send(_ bytes: [UInt8])
    /// The terminal's grid changed size.
    func resize(to size: TerminalGridSize)
    /// The terminal was cleared. A connection that draws its own prompt draws
    /// it again; a remote shell is left alone, because a ⌃L sent to redraw it
    /// could reach a program that is reading the terminal.
    func redrawAfterClear()
    /// Ends the shell. No events follow.
    func close()
}
