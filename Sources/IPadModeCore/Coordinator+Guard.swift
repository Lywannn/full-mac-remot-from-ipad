import Foundation

/// Guarding the mode against the world (§7.7, §7.10). The fields it keeps are described in Coordinator.swift.
extension Coordinator {
    /// §7.7: enforcement actions run at most this often.
    private static let enforcementInterval: Duration = .milliseconds(500)
    /// §7.7: a monitor that has been disabled again `flappingLimit` times within `flappingWindow` is left on the
    /// next time it comes back.
    private static let flappingWindow: Duration = .seconds(60)
    private static let flappingLimit = 3
    /// B-6: a monitor this daemon disabled less than this long ago is not back, only listed late: CoreGraphics lists a
    /// disable up to 0.31 s late (SP2, as for R79).
    private static let lateListing: Duration = .seconds(1)

    // MARK: Guarding the mode (§7.7, §7.10)

    /// Checks the mode against the world, on every display change, lock change and 1 s tick. A lock event ends
    /// any transition or mode at once (I8). Outside a transition, in a confirming or active mode:
    /// - a locked Mac, or a lost target (`isTargetLost`), returns to Normal at once, with no rate limit;
    /// - in `.active`, the target is kept main and the monitors off (`enforce`);
    /// - but while a return is owed, the mode is never guarded against it (A-1): the return is only tried again, at
    ///   once for a lock, a lost target or a lit physical monitor its last attempt did not see (R30, A-1), otherwise
    ///   at most every 10 s.
    /// Without a mode (owed since a restart) the owed return is only tried again, the same way. In Normal, a monitor
    /// a way back left off is asked for again, if that is owed (A-5).
    public func handle(_ event: SystemEvent) async {
        if event == .screenLocked {
            _ = await exitToNormal(.locked)
            return
        }
        guard !enterInFlight, exiting == nil else { return }
        guard state.phase != .normal else {
            retryMonitorsStillOff()
            return
        }
        let kept: Bool
        switch state.phase {
        case .active: kept = true
        case .confirming: kept = false
        case .normal, .entering, .exiting:   // owed since a restart, or left by the last run for `reconcileAtStartup`
            guard let owed = exitRetryReason else { return }
            let lit = (try? backend.listDisplays()).map(newlyLit) ?? false
            await retryOwedExit(now: lit ? owed : nil)
            return
        }
        let displays: [DisplayInfo]
        do { displays = try backend.listDisplays() } catch {
            events.record("guard.failed", ["step": "list", "error": "\(error)"])
            await retryOwedExit()
            return
        }
        let lost = isTargetLost(in: displays)
        if let owed = exitRetryReason {
            if lock.isLocked, !lastExitSaw.locked {
                await retryOwedExit(now: .locked)
            } else if lost, !lastExitSaw.targetLost {
                recordTargetLost()
                await retryOwedExit(now: .targetLost)
            } else {
                await retryOwedExit(now: newlyLit(displays) ? owed : nil)
            }
            return
        }
        // Step 0. Without any monitor attached the way back is refused (I1), so it waits until one is.
        if lock.isLocked, displays.contains(where: { $0.kind == .physical }) {
            _ = await exitToNormal(.locked)
            return
        }
        // Step 1.
        if lost {
            recordTargetLost()
            _ = await exitToNormal(.targetLost)
            return
        }
        recordResolutionDrift(in: displays)
        // Not before the confirmation has kept the mode.
        if kept, let target = displays.first(where: { $0.id == state.target }) {
            enforce(keeping: target, in: displays)
        }
    }

    /// R31: the target is lost when it is gone or offline. Online but not active (display sleep, a blink during a
    /// mode change) is not lost; the watchdog's grace covers a target that stays dark.
    func isTargetLost(in displays: [DisplayInfo]) -> Bool {
        !displays.contains { $0.id == state.target && $0.isOnline }
    }

    private func recordTargetLost() {
        events.record("guard.target.lost", ["id": state.target.map { "\($0.raw)" } ?? "none"])
    }

    /// A-3: once the monitors are off, the mode of the only display is never changed. That it left the configured
    /// resolution is only recorded, once per mode.
    private func recordResolutionDrift(in displays: [DisplayInfo]) {
        let wanted = remoteResolution.remoteMode
        guard !driftRecorded, let target = displays.first(where: { $0.id == state.target }),
              let mode = target.mode, !mode.isSameMode(as: wanted) else { return }
        driftRecorded = true
        events.record("resolution.drift", ["id": "\(target.id.raw)", "listed": Self.text(mode),
                                           "wanted": remoteResolution.text])
    }

    /// Tries the owed return to Normal again, if one is owed: as `now` at once, or else as itself once its 10 s
    /// have passed since it last failed. A failure is no news to the user (`retrying`).
    private func retryOwedExit(now reason: ExitReason? = nil) async {
        guard let owed = exitRetryReason, reason != nil || uptime() >= exitRetryDue else { return }
        let retry = reason ?? owed
        events.record("exit.retry", ["reason": retry.rawValue])
        _ = await exitToNormal(retry, failure: nil, retrying: true)
    }

    /// A-1: a physical monitor is lit that the owed return's last attempt did not see, so the way back can finish
    /// now: it is tried again at once. One the attempt saw lit waits for the 10 s, so a return that fails with a
    /// monitor lit is not tried on every event.
    private func newlyLit(_ displays: [DisplayInfo]) -> Bool {
        !lastExitSaw.monitorLit && MonitorWakeWatch.isLit(displays)
    }

    /// Steps 2–3, at most one action per 500 ms, and only around an active target: one that is not active is left
    /// alone (R31). The target is made main again first: a monitor that came back is disabled again only while the
    /// target is active and main (I2), so after a new main it waits for a later event. Only `.physical` displays
    /// are disabled, matched by kind and not by baseline ID, since a replug may give a monitor a new ID. A monitor
    /// this daemon disabled less than 1 s ago is only listed late, and is skipped (B-6). A monitor disabled again 3
    /// times within a minute is left on when it comes back again; only a disable that went through counts (B-6).
    private func enforce(keeping target: DisplayInfo, in displays: [DisplayInfo]) {
        guard target.isActive else { return }
        let now = uptime()
        if let lastEnforcement, now - lastEnforcement < Self.enforcementInterval { return }
        guard target.isMain else {
            lastEnforcement = now
            makeMainAgain(target, displays)
            return
        }
        var off: [(id: DisplayID, key: String, recent: [Duration])] = []
        for monitor in displays where monitor.kind == .physical && monitor.isOnline {
            let key = Self.identity(monitor)
            guard !flapping.contains(key) else { continue }
            if let disabled = disabledAt[key], now - disabled < Self.lateListing { continue }
            let recent = (reenabled[key] ?? []).filter { now - $0 < Self.flappingWindow }
            if recent.count >= Self.flappingLimit {
                flapping.insert(key)
                reenabled[key] = nil
                events.record("guard.flapping", ["id": "\(monitor.id.raw)", "name": monitor.name])
                notifier.notice(Messages.flapping(monitor.name))
            } else {
                off.append((monitor.id, key, recent))
            }
        }
        guard !off.isEmpty else { return }
        lastEnforcement = now
        lastDisableAt = now   // R79, as on the way in; also if the call fails
        let ids = off.map(\.id)
        do {
            try backend.setEnabled(ids, enabled: false, scope: scope)
            for monitor in off {
                reenabled[monitor.key] = monitor.recent + [now]
                disabledAt[monitor.key] = now
            }
            events.record("guard.physical.disabled", ["ids": Self.text(ids)])
        } catch {
            events.record("guard.failed", ["step": "disable", "error": "\(error)"])
        }
    }

    /// Step 3: the whole layout moves by one offset, so that the target lands at (0,0) and becomes main while every
    /// other display keeps its place beside it. Only online displays are moved: one unknown display fails the whole
    /// transaction.
    private func makeMainAgain(_ target: DisplayInfo, _ displays: [DisplayInfo]) {
        var origins: [DisplayID: Point] = [:]
        for display in displays where display.isOnline {
            origins[display.id] = Point(x: display.origin.x - target.origin.x, y: display.origin.y - target.origin.y)
        }
        do {
            try backend.setOrigins(origins, scope: scope)
            let main = try backend.listDisplays().contains { $0.id == target.id && $0.isMain }
            events.record(main ? "guard.target.main" : "guard.main.mismatch", ["id": "\(target.id.raw)"])
        } catch {
            events.record("guard.failed", ["step": "main", "error": "\(error)"])
        }
    }

    /// A monitor as itself rather than by its ID, which a replug may change.
    static func identity(_ display: DisplayInfo) -> String {
        display.uuid ?? "\(display.vendor):\(display.model):\(display.serial):\(display.location ?? "")"
    }
}
