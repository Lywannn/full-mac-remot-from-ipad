import Foundation

/// The system calls the watchdog needs besides the display backend; fakes in tests.
@MainActor public protocol WatchdogSignaller: AnyObject {
    var ownPID: Int32 { get }
    func isAlive(_ pid: Int32) -> Bool
    func executablePath(_ pid: Int32) -> String?
    func send(_ signal: Int32, to pid: Int32)
    /// CLOCK_MONOTONIC: keeps running during sleep.
    func nowNanos() -> UInt64
    /// CLOCK_UPTIME_RAW: stops during sleep.
    func uptimeNanos() -> UInt64
    func sleep(_ d: Duration) async
}

public enum WatchdogTickResult: Equatable, Sendable { case `continue`, exit }

/// One watchdog tick. It may only enable monitors, set origins, write files and signal the daemon.
@MainActor public final class WatchdogRunner {
    /// B-12: displays.json is written when its content changed, or once this long has passed; the watchdog's own
    /// heartbeat once this long has passed. Doctor calls a heartbeat fresh for 5 s.
    static let fileRefreshNanos: UInt64 = 2_000_000_000

    private let paths: Paths
    private let backend: DisplayBackend
    private let signaller: WatchdogSignaller
    private let log: EventSink
    private var policy: WatchdogPolicy
    private var lastListFailed = false
    private var skippedPIDs: Set<Int32> = []
    private var lastDisplays: [DisplayInfo] = []
    /// When, on the signaller's monotonic clock, each file was last written, and what displays.json then held.
    private var displaysWritten: (at: UInt64, displays: [DisplayInfo])?
    private var heartbeatWrittenAt: UInt64?

    public init(paths: Paths, backend: DisplayBackend, signaller: WatchdogSignaller, log: EventSink, config: Config) {
        self.paths = paths; self.backend = backend; self.signaller = signaller; self.log = log
        policy = WatchdogPolicy(staleAfter: .seconds(config.watchdog.heartbeatStaleSeconds))
    }

    public func tick() async -> WatchdogTickResult {
        // Read the heartbeat FIRST, then sample the clocks: a same-boot heartbeat is never in the future.
        let heartbeat = Heartbeat.read(paths.heartbeat)
        let nowNanos = signaller.nowNanos()
        let now = Duration.nanoseconds(Int64(clamping: nowNanos))
        let uptime = Duration.nanoseconds(Int64(clamping: signaller.uptimeNanos()))

        let displays: [DisplayInfo]
        do {
            displays = try backend.listDisplays()
            lastListFailed = false
        } catch {
            if !lastListFailed { log.record("watchdog.list.failed", ["error": "\(error)"]) }
            lastListFailed = true
            policy.skipTick()
            writeHeartbeat()
            return .continue
        }

        let daemonPID = heartbeat.flatMap { validDaemon($0.pid) }
        let input = WatchdogInput(
            persisted: FileStateStore(url: paths.state).load(), daemonAlive: daemonPID != nil,
            heartbeatAge: heartbeat?.age(nowNanos: nowNanos), displays: displays,
            disabledMarker: FileManager.default.fileExists(atPath: paths.disabledMarker.path))

        lastDisplays = displays
        var latest = displays
        var result = WatchdogTickResult.continue
        switch policy.evaluate(input, now: now, uptime: uptime) {
        case .none:
            break
        case .exitDisabled:
            log.record("watchdog.exitDisabled", [:])
            result = .exit
        case .killDaemon:
            if let daemonPID { await terminate(daemonPID) }
        case .restoreMonitors(let kill):
            latest = await restore(input: input, reason: policy.lastReason ?? "unknown",
                                   kill: kill ? daemonPID : nil)
        }

        // On the way out the displays are written whatever: `ipadmode disable` waits for one displays.json written
        // after the daemon ended (DisableWait), and the daemon's end changes nothing in the list.
        writeDisplays(latest, force: result == .exit)
        writeHeartbeat()
        return result
    }

    /// Keeps the breadcrumb files fresh while a long restore or kill is under way.
    private func pulse() {
        writeHeartbeat()
        if !lastDisplays.isEmpty { writeDisplays(lastDisplays) }
    }

    /// B-12: only when the list changed, 2 s have passed, or `force`; every write is an fsync.
    private func writeDisplays(_ displays: [DisplayInfo], force: Bool = false) {
        let now = signaller.nowNanos()
        if !force, let last = displaysWritten, last.displays == displays, now &- last.at < Self.fileRefreshNanos {
            return
        }
        try? WatchdogFiles.writeDisplays(displays, at: Date(), to: paths.displays)
        displaysWritten = (now, displays)
    }

    /// B-12: once 2 s have passed since the last write, not on every tick.
    private func writeHeartbeat() {
        let now = signaller.nowNanos()
        if let last = heartbeatWrittenAt, now &- last < Self.fileRefreshNanos { return }
        try? Heartbeat.now(pid: signaller.ownPID).write(paths.watchdogHeartbeat)
        heartbeatWrittenAt = now
    }

    /// The daemon pid when it is alive and is our binary; otherwise nil (treated as dead).
    private func validDaemon(_ pid: Int32) -> Int32? {
        if let why = WatchdogPIDGuard.refusal(pid: pid, ownPID: signaller.ownPID) {
            skip(pid, why); return nil
        }
        guard signaller.isAlive(pid) else { return nil }
        guard WatchdogPIDGuard.isDaemonExecutable(signaller.executablePath(pid)) else {
            skip(pid, "notOurBinary"); return nil
        }
        return pid
    }

    private func skip(_ pid: Int32, _ reason: String) {
        if skippedPIDs.insert(pid).inserted {
            log.record("watchdog.kill.skipped", ["pid": "\(pid)", "reason": reason])
        }
    }

    /// Returns the freshest display list.
    private func restore(input: WatchdogInput, reason: String, kill: Int32?) async -> [DisplayInfo] {
        let disabled = WatchdogPolicy.disabledMonitors(input.displays)
        log.record("watchdog.restore", ["reason": reason, "disabled": disabled.map(\.name).joined(separator: ",")])
        let baseline = input.persisted?.baseline
        let toEnable = WatchdogRestorePlan.make(baseline: baseline, current: input.displays).enable

        // After a failed batch, each monitor alone: one that cannot be enabled must not keep the others off (R69).
        let enabled = backend.enableMonitors(toEnable, scope: .session) { ids, error in
            log.record("watchdog.restoreFailed",
                       ["step": "enable", "ids": ids.map { "\($0.raw)" }.joined(separator: ","), "error": "\(error)"])
        }
        policy.restoreAccepted(Set(enabled))   // B-7: only these cool down
        let enabledOK = enabled.count == toEnable.count

        // The kill overlaps with the monitors waking up.
        if let kill { await terminate(kill) }

        // Monitors take 2-4 s to come up: wait for the ones that accepted, up to 10 s.
        var current = input.displays
        var waited = 0
        while true {
            if let list = try? backend.listDisplays() { current = list; lastDisplays = list }
            if waited % 10 == 0 { pulse() }
            let up = enabled.allSatisfy { id in current.contains { $0.id == id && $0.isOnline && $0.isActive } }
            if up || enabled.isEmpty || waited >= 100 { break }
            await signaller.sleep(.milliseconds(100))
            waited += 1
        }

        var layoutOK = false
        let plan = WatchdogRestorePlan.make(baseline: baseline, current: current)
        if plan.origins.isEmpty {
            log.record("watchdog.layout.skipped", ["reason": "noOnlineMonitor"])
        } else {
            do { try backend.setOrigins(plan.origins, scope: .session); layoutOK = true }
            catch { log.record("watchdog.restoreFailed", ["step": "origins", "error": "\(error)"]) }
        }
        if let list = try? backend.listDisplays() { current = list }

        let incident = WatchdogFiles.Incident(time: Date(), reason: reason, disabled: disabled.map(\.name),
                                              enabledOK: enabledOK, layoutOK: layoutOK)
        try? WatchdogFiles.writeIncident(incident, to: paths.incident)
        return current
    }

    /// SIGTERM, then SIGKILL after 3 s if it is still there.
    private func terminate(_ pid: Int32) async {
        log.record("watchdog.kill", ["pid": "\(pid)", "signal": "SIGTERM"])
        signaller.send(SIGTERM, to: pid)
        for i in 0..<30 {
            await signaller.sleep(.milliseconds(100))
            if !signaller.isAlive(pid) { return }
            if i % 10 == 9 { pulse() }
        }
        // Never kill a wrong process: the pid may have been reused during the wait.
        let refusal = WatchdogPIDGuard.refusal(pid: pid, ownPID: signaller.ownPID)
            ?? (WatchdogPIDGuard.isDaemonExecutable(signaller.executablePath(pid)) ? nil : "notOurBinary")
        if let refusal {
            log.record("watchdog.kill.skipped", ["pid": "\(pid)", "reason": refusal])
            return
        }
        log.record("watchdog.kill", ["pid": "\(pid)", "signal": "SIGKILL"])
        signaller.send(SIGKILL, to: pid)
    }
}
