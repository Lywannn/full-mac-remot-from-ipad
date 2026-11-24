/// The lines the daemon's notice panel shows (R51): notices that arrive close together are shown together, newest
/// last. A line already shown is not added again, and only the newest `limit` lines stay.
public struct NoticeLines: Equatable, Sendable {
    public static let limit = 4
    public private(set) var lines: [String] = []

    public init() {}

    /// True when `line` was added: the panel then shows the new text and restarts its timer. False for an exact
    /// duplicate of a line already shown, which changes nothing.
    public mutating func add(_ line: String) -> Bool {
        guard !lines.contains(line) else { return false }
        lines.append(line)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        return true
    }

    /// The panel has closed: the next notice starts afresh.
    public mutating func removeAll() {
        lines.removeAll()
    }

    public var text: String { lines.joined(separator: "\n") }
}
