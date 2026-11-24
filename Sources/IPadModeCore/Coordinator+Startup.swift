import Foundation

/// What the daemon runs as it starts and before it exits on purpose (§7.8 L5).
extension Coordinator {
    /// §7.8 L5: `crashLimit` unclean starts within `crashWindow` mean safe mode.
    private static let crashWindow: TimeInterval = 10 * 60
    private static let crashLimit = 3

    // MARK: Startup (§7.8 L5)

    /// Run by the daemon as it starts, before any other command. No start resumes a mode (I5): it ends in Normal,
    /// or, while the monitors cannot be brought back, in `.exiting` with the way back owed and retried every 10 s.
    /// - This start counts as unclean when the last run did not end with `markCleanShutdown`; ≥3 unclean starts
    ///   within 10 minutes mean safe mode. Entries dated in the future (the clock stepped back) no longer count.
    ///   The count is saved before anything else, the display list included: that list is the first private-API
    ///   call, and a crash in it has to count too (R34).
    /// - Whatever the last run left is undone by the way back to Normal: a mode or transition, a disabled monitor,
    ///   or a virtual display process. No handle to that process survives a restart: the host's `stopStale()`
    ///   ends it, and the state stops naming it. If the displays cannot be listed, a disabled monitor cannot be
    ///   ruled out, so the way back is owed then too.
    /// - No mode is saved after a restart: a return the state already owes is saved as `.exiting` together with
    ///   the count, and one that the display list adds is saved as `.exiting` before it begins.
    /// - An unreadable `state.json` reads as Normal without a baseline: the disabled monitors are turned on and
    ///   macOS lays them out.
    public func reconcileAtStartup() async {
        let now = Date()
        let owedByState = state.phase != .normal || state.virtualPID != nil
        commitBestEffort {
            if !$0.cleanShutdown { $0.uncleanStarts.append(now) }
            $0.uncleanStarts.removeAll { start in
                let age = now.timeIntervalSince(start)
                return age >= Self.crashWindow || age < 0
            }
            $0.cleanShutdown = false   // until `markCleanShutdown`: a crash from here on counts
            if owedByState { $0.phase = .exiting }   // write-ahead: the way back, and no mode
        }
        isSafeMode = state.uncleanStarts.count >= Self.crashLimit
        if isSafeMode {
            events.record("safe.mode", ["starts": "\(state.uncleanStarts.count)"])
            notifier.notice(Messages.safeMode)
        }
        var disabled: [DisplayID] = [], listed = true
        do { disabled = try backend.listDisplays().filter { $0.kind == .physical && !$0.isOnline }.map(\.id) } catch {
            events.record("reconcile.failed", ["error": "\(error)"])
            listed = false
        }
        let owed = owedByState || !listed || !disabled.isEmpty
        guard owed else { return }
        if !owedByState { commitBestEffort { $0.phase = .exiting } }   // the list added a reason: write-ahead
        if let pid = state.virtualPID { events.record("reconcile.stale.virtual", ["pid": "\(pid)"]) }
        events.record("reconcile.begin", ["disabled": Self.text(disabled)])
        _ = await exitToNormal(.startup)
    }

    /// Run by the daemon right before it exits on purpose (disable, SIGTERM), so that the next start does not count
    /// as a crash.
    public func markCleanShutdown() throws {
        try commit { $0.cleanShutdown = true }
    }
}
