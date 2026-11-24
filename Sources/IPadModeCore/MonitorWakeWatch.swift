/// Watching physical monitors come back on once their enable was asked for: the rules that R25 (the `vdisplay` child,
/// `R25Decision`) and step 2 of the way back to Normal share (A-2). Pure: the caller lists the displays, calls
/// `observe`, and does what it says.
/// - Every physical monitor named at the start or seen in any listing is *known*. A known monitor is back only while a
///   listing shows it online: one that is offline, or missing from the listing, is not (N3: a monitor waking from
///   standby can drop out of the listing, its vendor reading 0 meanwhile).
/// - Every known monitor that is not back is asked to turn on (`.enable`), by ID, again at most once a second. Whether
///   CoreGraphics accepted a request proves nothing: an accepted one is no proof that the monitor came back (N1), and a
///   monitor that is on or waking already makes it fail (spikes.md: 1001), the whole batch with it.
/// - They are `.back` once every known monitor is listed online and a physical monitor is lit (online and active);
///   while every known monitor is online but none is lit yet, they are waking.
/// - A failed listing (`nil`) only waits.
public struct MonitorWakeWatch: Equatable, Sendable {
    /// A monitor that is not back is asked to turn on again at most this often.
    public static let retryInterval: Duration = .seconds(1)

    public enum Step: Equatable, Sendable {
        /// Ask these monitors to turn on.
        case enable([DisplayID])
        /// Every known monitor is listed online, and one is lit.
        case back
        /// Poll again.
        case wait
    }

    /// Every physical monitor named at the start or seen in a listing.
    public private(set) var known: Set<DisplayID>
    /// When the last `.enable` was asked for, in time since the watch began.
    public private(set) var lastRequest: Duration?

    /// `known`: the monitors to bring back, before any listing names them.
    public init(known: Set<DisplayID> = []) {
        self.known = known
    }

    /// The next step for the listing taken `elapsed` after the watch began; nil when the listing failed.
    public mutating func observe(_ displays: [DisplayInfo]?, at elapsed: Duration) -> Step {
        guard let displays else { return .wait }
        let monitors = displays.filter { $0.kind == .physical }
        known.formUnion(monitors.map(\.id))
        let online = Set(monitors.filter(\.isOnline).map(\.id))
        let notBack = known.subtracting(online).sorted { $0.raw < $1.raw }
        guard !notBack.isEmpty else { return Self.isLit(displays) ? .back : .wait }   // else: waking
        if let lastRequest, elapsed - lastRequest < Self.retryInterval { return .wait }
        lastRequest = elapsed
        return .enable(notBack)
    }

    /// Whether a physical monitor is lit: online and active. A sleeping display reads active (R32).
    public static func isLit(_ displays: [DisplayInfo]) -> Bool {
        displays.contains { $0.kind == .physical && $0.isOnline && $0.isActive }
    }
}
