// Pure decision logic of the watchdog (spec §7.8 L4). It only ever moves toward safety: it can ask
// for physical monitors to be re-enabled, a hung daemon to be killed, or the watchdog to exit.

public struct WatchdogInput: Sendable {
    public var persisted: PersistedState?
    public var daemonAlive: Bool
    public var heartbeatAge: Duration?
    public var displays: [DisplayInfo]
    public var disabledMarker: Bool

    public init(persisted: PersistedState?, daemonAlive: Bool, heartbeatAge: Duration?,
                displays: [DisplayInfo], disabledMarker: Bool) {
        self.persisted = persisted; self.daemonAlive = daemonAlive; self.heartbeatAge = heartbeatAge
        self.displays = displays; self.disabledMarker = disabledMarker
    }
}

public enum WatchdogAction: Equatable, Sendable {
    case none
    case restoreMonitors(killDaemon: Bool)
    /// Kill a hung daemon only (during the cool-down): no enable, no layout, no incident.
    case killDaemon
    case exitDisabled
}

public struct WatchdogPolicy {
    public let staleAfter: Duration
    public let targetGrace: Duration
    /// After a restore, monitors need 2-4 s to become active (Gate R): no new restore for this long.
    public let coolDown: Duration

    /// A system sleep longer than this between two evaluations is a resume.
    public let resumeThreshold: Duration = .milliseconds(500)
    /// Why the last restore or kill was decided: noActiveDisplay, daemonDead, heartbeatStale, targetLost.
    public private(set) var lastReason: String?

    private var targetMissingSince: Duration?
    private var lastSample: (monotonic: Duration, uptime: Duration)?
    private var resumedAt: Duration?
    private var lastRestoreAt: Duration?
    private var restoredIDs: Set<DisplayID> = []

    public init(staleAfter: Duration = .seconds(5), targetGrace: Duration = .seconds(3),
                coolDown: Duration = .seconds(10)) {
        self.staleAfter = staleAfter; self.targetGrace = targetGrace; self.coolDown = coolDown
    }

    /// The tick had no usable display list (backend failure): forget the target-grace timer so rule (c)
    /// cannot fire on the first tick after an outage.
    public mutating func skipTick() { targetMissingSince = nil }

    /// B-7: what became of the restore `evaluate` just decided. Only the monitors whose enable was accepted cool down,
    /// waking; when none was, no cool-down starts, and the next evaluation may restore again at once.
    public mutating func restoreAccepted(_ accepted: Set<DisplayID>) {
        restoredIDs.formIntersection(accepted)
        if restoredIDs.isEmpty { lastRestoreAt = nil }
    }

    /// A physical monitor that exists in the system list but is offline. Sidecar and virtual
    /// displays never count. A sleeping online display reads `isActive = true`, so it is not "gone".
    public static func disabledMonitors(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.filter { $0.kind == .physical && !$0.isOnline }
    }

    /// `now` is CLOCK_MONOTONIC, which keeps running while the Mac sleeps; `uptime` is CLOCK_UPTIME_RAW, which
    /// does not (nil: no sleep is known). Time asleep between two evaluations = delta(now) - delta(uptime); the
    /// watchdog's own busy time cancels out. After a resume the daemon gets `staleAfter` to beat again. The first
    /// evaluation after a (re)start counts as a resume (B-1): launchd may start the watchdog right at wake, before the
    /// daemon has beaten since. That delays only the stale-heartbeat rule, never rule A or a dead daemon.
    public mutating func evaluate(_ input: WatchdogInput, now: Duration, uptime: Duration? = nil) -> WatchdogAction {
        lastReason = nil
        let up = uptime ?? now
        if let last = lastSample {
            if (now - last.monotonic) - (up - last.uptime) > resumeThreshold {
                resumedAt = now
                targetMissingSince = nil
            }
        } else {
            resumedAt = now
        }
        lastSample = (now, up)
        let inResumeWindow = resumedAt.map { now - $0 < staleAfter } ?? false
        let disabled = Self.disabledMonitors(input.displays)
        let phase = input.persisted?.phase ?? .normal
        let tracked: Bool
        switch phase { case .confirming, .active: tracked = true; default: tracked = false }

        // Track how long the target has been continuously inactive (rule c), whatever else happens.
        if tracked, let target = input.persisted?.target,
           !input.displays.contains(where: { $0.id == target && $0.isActive }) {
            if targetMissingSince == nil { targetMissingSince = now }
        } else {
            targetMissingSince = nil
        }

        guard !disabled.isEmpty else {
            return input.disabledMarker && !input.daemonAlive ? .exitDisabled : .none
        }

        let phaseNotNormal: Bool
        if let p = input.persisted?.phase { phaseNotNormal = p != .normal } else { phaseNotNormal = true }
        // A missing heartbeat counts as stale.
        let heartbeatStale = !inResumeWindow && (input.heartbeatAge.map { $0 > staleAfter } ?? true)
        let daemonBad = !input.daemonAlive || heartbeatStale
        let ruleB = phaseNotNormal && daemonBad
        let ruleA = !input.displays.contains { $0.isActive }
        let ruleC = targetMissingSince.map { now - $0 >= targetGrace } ?? false
        guard ruleA || ruleB || ruleC else { return .none }

        let kill = ruleB && input.daemonAlive
        let reason = ruleA ? "noActiveDisplay"
            : ruleB ? (input.daemonAlive ? "heartbeatStale" : "daemonDead") : "targetLost"
        let ids = Set(disabled.map(\.id))
        if let last = lastRestoreAt, now - last < coolDown, ids.isSubset(of: restoredIDs) {
            // Cooling down: only the hung-daemon kill may still go through, and only the kill.
            if kill { lastReason = reason; return .killDaemon }
            return .none
        }
        lastReason = reason
        lastRestoreAt = now   // until `restoreAccepted` says which enables were accepted (B-7)
        restoredIDs = ids
        return .restoreMonitors(killDaemon: kill)
    }
}
