/// The boundary between Lite and whatever parses VT sequences and keeps screen
/// state. SwiftTerm implements it today (`SwiftTermEngine`); a home-grown parser
/// can replace it later without touching the PTY, renderer or UI.
///
/// Threading contract: implementations are internally synchronised. `feed` is
/// called from the PTY read thread; everything else from the main thread.
/// Event callbacks may fire *during* `feed` (on the PTY thread, possibly with
/// the engine's lock held), so they must not call back into the engine
/// synchronously.
public protocol TerminalEngine: AnyObject, Sendable {
    var cols: Int { get }
    var rows: Int { get }

    /// Parses output from the child process.
    func feed(_ bytes: UnsafeRawBufferPointer)

    func resize(cols: Int, rows: Int)

    /// Updates `grid` to the current visible screen. Implementations only rewrite
    /// rows that changed since the previous call (a full rewrite if the size
    /// changed). Returns false if nothing changed.
    @discardableResult
    func snapshot(into grid: inout GridSnapshot) -> Bool

    /// Modes that affect how input is encoded.
    var modes: TerminalModes { get }

    // MARK: Scrollback

    var viewport: Viewport { get }
    /// Scrolls the view `offset` rows back from the live screen (clamped; 0 = live).
    func scrollViewport(toOffset offset: Int)

    // MARK: Text (absolute rows; see `Viewport`)

    /// The cells of one line as strings (one per column; "" for the second half of a
    /// wide character), and whether the *next* line is a soft-wrapped continuation.
    func line(absoluteRow: Int) -> (cells: [String], wrapsIntoNext: Bool)?
    /// Text between two points (inclusive). Soft-wrapped lines are joined; hard line
    /// breaks become "\n"; trailing blanks are trimmed.
    func text(from start: GridPoint, to end: GridPoint) -> String

    // MARK: Mouse reporting

    /// Encodes and sends a mouse event to the program, if it asked for this kind.
    func sendMouse(_ event: MouseReport)
}

/// A cell position. `row` is *absolute* (scroll-invariant): it identifies the same
/// line whether it's on screen or in scrollback, so selections survive scrolling.
public struct GridPoint: Sendable, Hashable, Comparable {
    public var row: Int
    public var col: Int
    public init(row: Int, col: Int) { self.row = row; self.col = col }
    public static func < (a: Self, b: Self) -> Bool { (a.row, a.col) < (b.row, b.col) }
}

public struct Viewport: Sendable, Equatable {
    /// Rows scrolled back from the live screen (0 = live).
    public var offset: Int
    /// Rows of scrollback available (0 on the alternate screen).
    public var maxOffset: Int
    /// Absolute row of the top visible line.
    public var topRow: Int
    /// Absolute range of all lines (scrollback + screen).
    public var firstRow: Int
    public var endRow: Int

    public init(offset: Int = 0, maxOffset: Int = 0, topRow: Int = 0, firstRow: Int = 0, endRow: Int = 0) {
        self.offset = offset; self.maxOffset = maxOffset; self.topRow = topRow
        self.firstRow = firstRow; self.endRow = endRow
    }
}

public struct MouseReport: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case press, release, drag, move, scrollUp, scrollDown }
    public var kind: Kind
    /// 0 left, 1 middle, 2 right.
    public var button: Int
    /// Visible cell coordinates (0-based).
    public var col: Int
    public var row: Int
    public var shift = false, option = false, control = false

    public init(kind: Kind, button: Int = 0, col: Int, row: Int,
                shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.kind = kind; self.button = button; self.col = col; self.row = row
        self.shift = shift; self.option = option; self.control = control
    }
}

public struct TerminalModes: Sendable, Equatable {
    /// DECCKM: arrows send `ESC O A` instead of `ESC [ A` (vim, less, …).
    public var applicationCursor = false
    /// Wrap pasted text in `ESC [200~ … ESC [201~` so shells don't execute it line by line.
    public var bracketedPaste = false
    /// Programs like vim/htop switch to the alternate screen (no scrollback).
    public var alternateScreen = false
    /// The program wants mouse events (vim `mouse=a`, htop, tmux…).
    public var mouseReporting = false
    /// …including motion while a button is held.
    public var mouseDrag = false
    /// …including motion with no button held.
    public var mouseMotion = false

    public init() {}
}

/// Things the engine tells its host about. All optional; set before feeding.
public struct TerminalEngineEvents: Sendable {
    /// Bytes the terminal must send back to the program (e.g. replies to "what
    /// terminal are you?" or cursor position queries).
    public var reply: @Sendable ([UInt8]) -> Void = { _ in }
    public var title: @Sendable (String) -> Void = { _ in }
    public var bell: @Sendable () -> Void = {}

    public init() {}
}
