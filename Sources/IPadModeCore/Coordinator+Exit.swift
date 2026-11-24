import Foundation

// MARK: Back to Normal (§7.6)

/// The way back to Normal: from any phase, as the rollback of a failed enter, and for a display that an enter
/// left running. The fields it shares with the way in are described in Coordinator.swift.
extension Coordinator {
    /// R27: how long re-enabled monitors may take to be listed online and lit; monitors waking from standby took
    /// 2–4 s.
    static let monitorWakeTimeout: Duration = .seconds(10)
    /// R79: how long after the last disable the way back trusts the display list. CoreGraphics lists a disable up to
    /// 0.31 s late (SP2): planned from a list that still shows the monitors on, the way back would turn none of them
    /// on, and could stop the virtual display, the only display that is really on.
    private static let disableSettle: Duration = .seconds(1)

    /// Returns to Normal from any phase, cutting into an enter or a confirmation. Idempotent: in Normal it does
    /// nothing, and while a return is running, callers wait for it and share its result. Within 1 s of a disable it
    /// first waits until then, since the display list shows a disable late (R79). The monitors are back once the
    /// listing shows them (A-2), within 10 s. If no physical monitor is lit by then, the virtual display stays (I1),
    /// and the return is not done even when no virtual display is left: `.failed(Messages.exitFailed)`, or
    /// `Messages.startupRestoreFailed` after a restart; or `.refused(.noPhysicalMonitor, …)` when no monitor is
    /// attached at all.
    public func exitToNormal(_ reason: ExitReason) async -> CommandResult {
        await exitToNormal(reason, failure: nil)
    }

    /// `failure`: the notice of a rollback, which tells why the enter failed. `retrying`: the periodic check tries an
    /// owed return again, so a failure is no news to the user.
    func exitToNormal(_ reason: ExitReason, failure: String?, retrying: Bool = false) async -> CommandResult {
        cancelConfirmation()
        if let exiting {
            let result = await exiting.value
            // An automatic return that joined one that did not finish is owed as itself (A-1).
            if !result.isOK, reason.isAutomatic, state.phase != .normal { oweExit(reason) }
            return result
        }
        guard state.phase != .normal else {
            // A-5: an explicit Normal while Normal looks at the monitors once more.
            guard reason == .user || reason == .hotkey else { return .ok(Messages.backToNormal) }
            let task = Task { @MainActor in await recheckMonitors() }
            exiting = task
            return await task.value
        }
        let task = Task { @MainActor in await restoreNormal(reason, failure: failure, retrying: retrying) }
        exiting = task
        latestExit = task
        return await task.value
    }

    /// A-5: an explicit Normal (CLI, Dock, hotkey) while Normal already lists the displays, and any physical monitor
    /// listed offline is brought back as step 2 does it. It runs as a return of its own, so that nothing enters
    /// meanwhile and other returns join it; Normal holds on disk all along, so nothing is saved. Returns
    /// `.ok(Messages.backToNormal)` once they are back, and else says which monitor is still off: `.ok` while
    /// another physical monitor is lit, `.failed` when none is.
    private func recheckMonitors() async -> CommandResult {
        defer { exiting = nil }
        let displays: [DisplayInfo]
        do { displays = try backend.listDisplays() } catch {
            events.record("normal.recheck.failed", ["error": "\(error)"])
            return .ok(Messages.backToNormal)
        }
        let off = displays.filter { $0.kind == .physical && !$0.isOnline }.map(\.id)
        guard !off.isEmpty else { return .ok(Messages.backToNormal) }
        events.record("normal.recheck", ["ids": Self.text(off)])
        switch await bringMonitorsBack(off, from: displays) {
        case .noMonitor, .back:
            clearStillOffRetry()
            return .ok(Messages.backToNormal)
        case .timedOut(let lit, let notBack):
            let text = monitorsStillOff(notBack, usual: nil)
            return lit ? .ok(text) : .failed(text)
        }
    }

    /// A-5: Normal is back (a monitor is lit, so I1 holds), but the monitors named in `notBack` did not come on. The
    /// user is told, and they are asked for again every 10 s while Normal, at most 3 times. `usual`: the notice of
    /// this way back. A plain "back to Normal" gives way to the warning; any other is shown before it and stays the
    /// result. Returns the result's text.
    private func monitorsStillOff(_ notBack: [String], usual: String?) -> String {
        let warning = Messages.monitorStillOff(notBack.joined(separator: ", "))
        events.record("physical.still.off", ["names": notBack.joined(separator: ",")])
        if let usual, usual != Messages.backToNormal { notifier.notice(usual) }
        notifier.notice(warning)
        oweStillOffRetry()
        guard let usual, usual != Messages.backToNormal else { return warning }
        return usual
    }

    /// The display that `start` returned after a return to Normal had already finished: that return had nothing
    /// to stop, so the display would be left running in Normal. It goes the way a return stops a virtual display:
    /// as one more return that others join, saved before it acts, and never as the last active display (I1).
    func stopLeftoverVirtualDisplay() async -> CommandResult? {
        // An explicit Normal may be looking at the monitors meanwhile (A-5): the leftover goes once it has ended.
        while let exiting { _ = await exiting.value }
        guard let virtual, state.phase == .normal else { return nil }
        events.record("virtual.leftover", ["id": "\(virtual.displayID.raw)"])
        let task = Task { @MainActor () -> CommandResult in
            defer { exiting = nil }
            commitBestEffort { $0.phase = .exiting; $0.target = virtual.displayID; $0.virtualPID = virtual.pid }
            await settleAfterDisable()   // the I1 check below lists after it
            let attempt = ExitAttempt(reason: .failure, mode: .remote, owes: .failure, isRetry: false)
            if let kept = await stopVirtualDisplay(attempt) { return kept }
            commitBestEffort { $0.phase = .normal; $0.target = nil; $0.virtualPID = nil }
            return .ok(Messages.backToNormal)
        }
        exiting = task
        return await task.value
    }

    /// R79: within `disableSettle` of the last disable, waits until it has passed, on the injected clock. The main
    /// thread stays free, and a return to Normal or a lock that comes meanwhile joins this return.
    private func settleAfterDisable() async {
        guard let disabled = lastDisableAt else { return }
        let left = disabled + Self.disableSettle - uptime()
        guard left > .zero else { return }
        let parts = left.components
        events.record("exit.settle", ["ms": "\(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)"])
        await wait(until: disabled + Self.disableSettle)
    }

    /// Closes the dialog of the confirmation that is waiting, if any; whatever it answers no longer counts.
    private func cancelConfirmation() {
        guard confirmationID != nil else { return }
        confirmationID = nil
        confirmer.cancel()
    }

    /// One way back to Normal, as the steps that may end it without Normal see it.
    struct ExitAttempt {
        let reason: ExitReason
        /// The mode the display stays in if this does not finish. After a restart there is none: the way back starts
        /// from `.exiting`, and no mode is made up for it (I5).
        let mode: Mode?
        /// What is owed if it does not finish (A-1).
        let owes: ExitReason
        /// The periodic check is trying an owed return again.
        let isRetry: Bool
    }

    private func restoreNormal(_ reason: ExitReason, failure: String?, retrying: Bool) async -> CommandResult {
        defer { exiting = nil }
        // A way back that does not finish stays owed, whatever its reason (A-1): an automatic return as itself; any
        // other as the return the episode already owes, if one is; in a mode nobody has confirmed as its timeout, so
        // that the automatic return of §7.4 step 5 survives a failed Normal; else as itself.
        let owes: ExitReason = if reason.isAutomatic { reason } else if let owed = exitRetryReason { owed }
            else if state.phase.isUnconfirmed { .confirmTimeout } else { reason }
        let attempt = ExitAttempt(reason: reason, mode: state.phase.mode, owes: owes, isRetry: retrying)
        events.record("exit.\(reason.rawValue).begin", [:])
        commitBestEffort { $0.phase = .exiting }
        lastExitSaw = (locked: lock.isLocked, targetLost: false, monitorLit: false)
        // R79: the list this plans from, and every later one, the I1 check before the virtual display goes included,
        // is taken after the settle.
        await settleAfterDisable()

        // Step 2: every monitor on, matched by identity rather than by ID, and judged by the listing (A-2). Without a
        // lit monitor the virtual display stays.
        let current: [DisplayInfo]
        do { current = try backend.listDisplays() } catch {
            return failExit(attempt, detail: "\(error)")
        }
        lastExitSaw.targetLost = isTargetLost(in: current)
        let baseline = state.baseline ?? Snapshot(displays: [], takenAt: .distantPast)
        let plan = RestorePlanner.plan(baseline: baseline, current: current)
        let wake = await bringMonitorsBack(plan.enable, from: current)
        lastExitSaw.monitorLit = wake.isLit
        // With no monitor lit, Normal would show nothing at all, even when the virtual display is already gone or
        // there never was one: the way back is not done (I1).
        if case .timedOut(lit: false, _) = wake {
            return failExit(attempt, detail: "\(TransitionFailure.monitorsNotActive)")
        }

        // Step 3: layout, best effort.
        await restoreLayout(baseline)

        // Step 4: only now the virtual display goes, and never as the last active display (I1).
        if let kept = await stopVirtualDisplay(attempt) { return kept }

        commitBestEffort {
            $0.phase = .normal; $0.baseline = nil; $0.target = nil; $0.virtualPID = nil
            if reason != .failure { $0.lastError = nil }   // a rollback keeps the error it rolled back from
        }
        clearOwedExit()
        let text = notice(for: reason, failure: failure)
        // A-5: a monitor that is there but did not come on is told, and asked for again.
        if case .timedOut(lit: true, let notBack) = wake, !notBack.isEmpty {
            return .ok(monitorsStillOff(notBack, usual: text))
        }
        clearStillOffRetry()
        notifier.notice(text)
        return .ok(text)
    }

    // MARK: Step 2: the monitors come back (A-2)

    /// What step 2 found.
    enum MonitorWake: Equatable {
        /// No physical monitor is attached: there is nothing to bring back.
        case noMonitor
        /// Every monitor it knows of is listed online, and one is lit.
        case back
        /// The wake window ran out first. `lit`: a physical monitor is lit all the same; `notBack`: the names of the
        /// monitors it knows of that are not listed online, by ID.
        case timedOut(lit: Bool, notBack: [String])

        /// A physical monitor was lit at the end.
        var isLit: Bool {
            switch self {
            case .back: true
            case .timedOut(let lit, _): lit
            case .noMonitor: false
            }
        }
    }

    /// Step 2 (A-2): asks the monitors in `enable` to turn on, then watches them, and every other physical monitor a
    /// listing shows, come back, within `monitorWakeTimeout` (R27). `MonitorWakeWatch` has the rules: the listing
    /// decides, not what the calls return (1001 for a monitor that is on or waking already), a known monitor missing
    /// from the listing is not back, and one that is not back is asked for again at most once a second, by
    /// `enableMonitors` (the batch, then each monitor alone). `first` is the listing `enable` was planned from. The
    /// main thread stays free: every wait is on the injected clock.
    func bringMonitorsBack(_ enable: [DisplayID], from first: [DisplayInfo]) async -> MonitorWake {
        var watch = MonitorWakeWatch(known: Set(enable))
        var listing: [DisplayInfo]? = first
        var latest = first
        var names: [DisplayID: String] = [:]   // each monitor's name, as the last listing that showed it had it
        var requested = false, waited = false
        let start = uptime(), deadline = start + Self.monitorWakeTimeout
        func known() -> String { Self.text(watch.known.sorted { $0.raw < $1.raw }) }
        while true {
            let elapsed = uptime() - start
            if let listing {
                latest = listing
                for monitor in listing where monitor.kind == .physical { names[monitor.id] = monitor.name }
            }
            let step = watch.observe(listing, at: elapsed)
            if watch.known.isEmpty { return .noMonitor }
            if step == .back {
                if requested || waited { events.record("physical.enabled", ["ids": known()]) }
                return .back
            }
            if elapsed >= Self.monitorWakeTimeout || Task.isCancelled { break }
            waited = true
            if case .enable(let ids) = step {
                _ = backend.enableMonitors(ids, scope: scope) { failed, error in
                    events.record("physical.enable.failed", ["ids": Self.text(failed), "error": "\(error)"])
                }
                // The first request is looked at at once; one asked again waits for the next poll.
                if !requested {
                    requested = true
                    listing = try? backend.listDisplays()
                    continue
                }
            }
            await wait(until: min(uptime() + Self.pollInterval, deadline))
            listing = try? backend.listDisplays()
        }
        let lit = MonitorWakeWatch.isLit(latest)
        let online = Set(latest.filter { $0.kind == .physical && $0.isOnline }.map(\.id))
        let notBack = watch.known.subtracting(online).sorted { $0.raw < $1.raw }
        events.record("physical.enable.timeout", ["ids": known(), "notBack": Self.text(notBack), "lit": "\(lit)"])
        return .timedOut(lit: lit, notBack: notBack.map { names[$0] ?? "\($0.raw)" })
    }

    // MARK: Step 3: the layout

    /// Origins and modes from the baseline, best effort: mismatches and failures are logged and left to macOS. Planned
    /// from a listing taken now, once the monitors are back, so that one that was missing from the listing step 2
    /// began with is laid out too. Only online displays are moved, since one unknown display fails the whole
    /// transaction. The same `setOrigins` call moves the virtual display right of the restored layout, so the
    /// baseline main is the only display at (0,0). A mode is set only where it differs: macOS brings a re-enabled
    /// monitor back at its own mode, rotation included.
    private func restoreLayout(_ baseline: Snapshot) async {
        let now: [DisplayInfo]
        do { now = try backend.listDisplays() } catch {
            events.record("restore.failed", ["step": "list", "error": "\(error)"])
            return
        }
        let plan = RestorePlanner.plan(baseline: baseline, current: now)
        let online = Set(now.filter(\.isOnline).map(\.id))
        var origins = plan.origins.filter { online.contains($0.key) }
        if !origins.isEmpty {
            if let virtual, online.contains(virtual.displayID) {
                let right = origins.map { $0.value.x + Self.width(plan.modes[$0.key]) }.max() ?? 0
                origins[virtual.displayID] = Point(x: right, y: 0)
            }
            var placed = true
            do { try backend.setOrigins(origins, scope: scope) } catch {
                placed = false
                events.record("restore.failed", ["step": "origins", "error": "\(error)"])
            }
            // B-8: CoreGraphics lists the new main a little late (R56), so after a layout that went through the check
            // waits up to 2 s for it. Otherwise nothing of ours is under way: one look.
            if let main = plan.main {
                let isMain: ([DisplayInfo]) -> Bool = { list in list.contains { $0.id == main && $0.isMain } }
                let listed = placed && online.contains(main) ? await waitUntil(Self.mainTimeout, isMain)
                    : (try? backend.listDisplays()).map(isMain) == true
                if !listed { events.record("restore.main.mismatch", ["id": "\(main.raw)"]) }
            }
        }
        for (id, mode) in plan.modes.sorted(by: { $0.key.raw < $1.key.raw }) {
            guard let display = now.first(where: { $0.id == id }), display.isOnline, display.mode != mode else {
                continue
            }
            do { try backend.setMode(id, mode, scope: scope) }
            catch { events.record("restore.failed", ["step": "mode", "id": "\(id.raw)", "error": "\(error)"]) }
        }
        for name in plan.unmatched { events.record("restore.unmatched", ["name": name]) }
    }

    /// Step 4: stops the virtual display, but never while it is the only active display (I1). Returns nil once it
    /// is gone, or if there is none; otherwise it stays, and so does the mode.
    private func stopVirtualDisplay(_ attempt: ExitAttempt) async -> CommandResult? {
        guard let virtual else { return nil }
        let displays: [DisplayInfo]
        do { displays = try backend.listDisplays() } catch {
            return failExit(attempt, detail: "\(error)")
        }
        if displays.filter(\.isActive).map(\.id) == [virtual.displayID] {
            guard displays.contains(where: { $0.kind == .physical }) else { return keepWithoutMonitor(attempt) }
            return failExit(attempt, detail: "\(TransitionFailure.monitorsNotActive)")
        }
        await virtualHost.stop(virtual)
        self.virtual = nil
        events.record("virtual.stopped", ["id": "\(virtual.displayID.raw)"])
        return nil
    }

    /// The way back cannot finish. The virtual display stays (I1), and so does the mode, if there is one; after a
    /// restart there is none, and the return stays `.exiting` (I5). The return stays owed, to be tried again (A-1).
    /// The user is told once per owed episode, and each time they asked for Normal.
    private func failExit(_ attempt: ExitAttempt, detail: String) -> CommandResult {
        let text = attempt.mode == nil ? Messages.startupRestoreFailed : Messages.exitFailed
        // A retry, or an automatic return, that fails while the episode is owed is no news.
        let alreadyTold = exitRetryReason != nil && (attempt.isRetry || attempt.reason.isAutomatic)
        commitBestEffort { $0.phase = attempt.mode.map(Phase.active) ?? .exiting; $0.lastError = detail }
        oweExit(attempt.owes)
        events.record("exit.failed", ["reason": attempt.reason.rawValue, "error": detail])
        if !alreadyTold { notifier.notice(text) }
        return .failed(text)
    }

    /// No physical monitor is attached: the virtual display is the only display there is, so it stays and so does
    /// the mode. The return stays owed (A-1): once a monitor is lit, it is tried again at once.
    private func keepWithoutMonitor(_ attempt: ExitAttempt) -> CommandResult {
        commitBestEffort {
            $0.phase = attempt.mode.map(Phase.active) ?? .exiting
            $0.lastError = RefusalReason.noPhysicalMonitor.rawValue
        }
        oweExit(attempt.owes)
        events.record("exit.refused", ["reason": RefusalReason.noPhysicalMonitor.rawValue])
        return .refused(.noPhysicalMonitor, Messages.noPhysicalMonitor)
    }

    private func notice(for reason: ExitReason, failure: String?) -> String {
        switch reason {
        case .user, .hotkey, .confirmRevert, .disable: Messages.backToNormal
        case .confirmTimeout: Messages.revertedTimeout
        case .locked: Messages.revertedLocked
        case .targetLost: Messages.targetLost
        case .failure: failure ?? Messages.backToNormal
        case .startup: Messages.recovered
        }
    }
}

private extension ExitReason {
    /// Returns to Normal that nobody waits on; if one fails, it has to be tried again. The startup reconcile is one:
    /// the daemon runs it on its own, and monitors it leaves off would stay off.
    var isAutomatic: Bool {
        switch self {
        case .confirmTimeout, .confirmRevert, .locked, .targetLost, .failure, .startup: true
        case .user, .hotkey, .disable: false
        }
    }
}

private extension Phase {
    /// The mode a phase belongs to; nil in Normal and while exiting.
    var mode: Mode? {
        switch self {
        case .entering(let mode), .confirming(let mode), .active(let mode): mode
        case .normal, .exiting: nil
        }
    }

    /// Entering, or waiting for the confirmation: nobody has confirmed the mode yet.
    var isUnconfirmed: Bool {
        switch self {
        case .entering, .confirming: true
        case .normal, .active, .exiting: false
        }
    }
}
