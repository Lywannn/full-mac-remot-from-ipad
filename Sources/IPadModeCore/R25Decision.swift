/// R25, "last one out turns on the lights" (amended): what the `vdisplay` child does on each poll, every 100 ms,
/// once its parent, the daemon, has died, until it releases its display. Pure: the child lists the displays, asks
/// `next`, and does what it says. Which monitors are known, when they are back, and how often their enable is asked
/// for again are `MonitorWakeWatch`'s rules, which the way back to Normal shares; on top of them:
/// - The display may go (`.release`) once every known monitor is back and a physical monitor is lit; once 3 listings
///   in a row show no physical monitor while none is known (headless: one bad listing, which drops the disabled
///   monitors, must not release the only display); or at the 6 s deadline, whatever is known by then.
/// - A failed listing (`nil`) only waits.
public enum R25Decision {
    /// Monitors waking from standby take 2–4 s (SP4): releasing sooner could leave no active display (I1).
    public static let deadline: Duration = .seconds(6)
    public static let retryInterval = MonitorWakeWatch.retryInterval
    public static let headlessListings = 3

    public enum Action: Equatable, Sendable {
        /// Turn these monitors on.
        case enable([DisplayID])
        /// Release the display and exit.
        case release
        /// Poll again.
        case wait
    }

    public struct State: Equatable, Sendable {
        /// Listings in a row that showed no physical monitor while none was known.
        public internal(set) var headlessStreak = 0
        /// The monitors R25 brings back, and when it last asked for them.
        public internal(set) var watch = MonitorWakeWatch()
        /// When the last `.enable` was asked for, in time since the parent died.
        public var lastRequest: Duration? { watch.lastRequest }
        /// Every physical monitor seen in a listing since R25 began.
        public var known: Set<DisplayID> { watch.known }

        public init() {}
    }

    /// The next step. `displays` is nil when the listing failed; `elapsed` is the time since the parent died.
    public static func next(displays: [DisplayInfo]?, elapsed: Duration, state: State) -> (action: Action, state: State) {
        var state = state
        if elapsed >= deadline { return (.release, state) }
        guard let displays else {
            state.headlessStreak = 0
            return (.wait, state)
        }
        if state.known.isEmpty, !displays.contains(where: { $0.kind == .physical }) {
            state.headlessStreak += 1
            return (state.headlessStreak >= headlessListings ? .release : .wait, state)
        }
        state.headlessStreak = 0
        switch state.watch.observe(displays, at: elapsed) {
        case .enable(let ids): return (.enable(ids), state)
        case .back: return (.release, state)
        case .wait: return (.wait, state)
        }
    }
}
