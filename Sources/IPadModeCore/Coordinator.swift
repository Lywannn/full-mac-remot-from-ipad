import Foundation

/// The mode state machine (spec §7.3–§7.8). Every display change goes through the injected ports, and the
/// intent is saved to `store` before each action (write-ahead). Invariants kept at every step:
/// - I1: never zero active displays;
/// - I2: monitors are disabled only while the target is active and main;
/// - I3: on the way back, monitors are on before the virtual display goes away;
/// - I8: a locked Mac means Normal, and no mode is entered while it is locked.
/// One transition runs at a time. A return to Normal may always cut in, and the transition it cuts into stops.
/// The user only ever sees `Messages`; details go to `events` and `lastError`.
/// The way into a mode is in this file; guarding it is in Coordinator+Guard.swift, startup in
/// Coordinator+Startup.swift, and the way back to Normal in Coordinator+Exit.swift.
@MainActor
public final class Coordinator {
    public private(set) var state: PersistedState

    let backend: DisplayBackend
    let virtualHost: VirtualDisplayHost
    let lock: ScreenLockProvider
    let confirmer: Confirmer
    let notifier: Notifier
    let events: EventSink
    private let store: StateStore
    private let clock: any Clock<Duration>
    public private(set) var config: Config
    private let capabilities: Capabilities
    let scope: ConfigScope
    private let settleDelay: Duration

    // MARK: Transitions in progress
    //
    // Kept in memory only; `state` is what a restart sees. How these fields relate:
    // - `exiting` is set while a return to Normal runs (`restoreNormal`, the stop of a leftover display, or an
    //   explicit Normal's look at the monitors while Normal, A-5) and cleared when it ends. Meanwhile every other way
    //   back joins it, `enterRemote` answers busy, and an enter in flight stops at its next check. A `restoreNormal`'s
    //   phase is `.exiting` from its first step until it ends: in `.normal`; or, when it cannot finish, in
    //   `.active(mode)` with the display kept, or still in `.exiting` after a restart, when there is no mode to keep.
    // - `latestExit` is the return started last since the current enter began. Unlike `exiting` it is kept after
    //   the return ends, so that an enter that was cut off can reply with that return's outcome.
    // - `enterInFlight` is true for the whole of `enterRemote`, cleanup included. With `exiting`, it makes
    //   `refusalToEnter` answer busy, so at most one enter runs and nothing sets `.entering` again while an enter
    //   may still act on it: that is why `interruption` can trust the phase.
    // - `confirmationID` names the confirmation whose answer still counts. It is set when `.confirming` is
    //   committed, and cleared when that answer is applied or when a return to Normal begins, which also closes the
    //   dialog. An answer counts only while its ID is current and the phase is `.confirming`.
    //   `pendingConfirmation` is the task that waits for that answer; tests await it.
    // - `virtual` is the display this Coordinator started and has not stopped. It is set as soon as `start`
    //   returns, even when a return has cut in meanwhile, and cleared only once `stopVirtualDisplay` has stopped
    //   it. On disk, `state.target` and `state.virtualPID` name it before anything depends on it (write-ahead); an
    //   enter that was cut off writes them itself if `start` returned late. If it is still set once back in Normal,
    //   `stopLeftoverVirtualDisplay` stops it.
    // - `exitRetryReason` is a return to Normal that did not finish and is still owed, as this reason. Only `oweExit`
    //   sets it, whenever a return ends with the display kept (R19, A-1), whatever its reason, a refusal for lack of
    //   monitors included; and only `clearOwedExit` clears it, once a return reaches Normal. Between the two lies one
    //   owed episode, told to the user once. While it is set, `handle` never guards the mode against it (no
    //   re-disable, no re-main) and only tries it again: at most every 10 s, but at once for a lock, a lost target or
    //   a lit physical monitor its last attempt did not see (`lastExitSaw`, R30, A-1); a lock event (`.screenLocked`)
    //   also starts a fresh `.locked` return at once.

    var virtual: VirtualDisplayHandle?
    var exiting: Task<CommandResult, Never>?
    var latestExit: Task<CommandResult, Never>?
    private(set) var enterInFlight = false
    var confirmationID: Int?
    private var confirmationCount = 0
    private(set) var pendingConfirmation: Task<Void, Never>?
    private(set) var exitRetryReason: ExitReason?
    /// What the last return to Normal found: as it began, whether the Mac was locked and the target lost (R31); and
    /// whether a physical monitor was lit once it had asked for them (A-1).
    var lastExitSaw: (locked: Bool, targetLost: Bool, monitorLit: Bool) = (false, false, false)
    /// R79: when monitors were last disabled, by the way in or by the guard, on the injected clock (`uptime`).
    /// CoreGraphics lists that change up to 0.31 s late, so the way back trusts the display list only 1 s after it.
    var lastDisableAt: Duration?

    // MARK: Guarding (§7.7)

    /// The time on the injected clock since this Coordinator was made; the times below are on it.
    let uptime: @Sendable () -> Duration
    /// When an enforcement action last ran in this mode; they run at most once per 500 ms.
    var lastEnforcement: Duration?
    /// When each monitor, by `identity`, was disabled again in this mode within the last minute.
    var reenabled: [String: [Duration]] = [:]
    /// B-6: when each monitor, by `identity`, was last disabled in this mode, by the way in or the guard.
    var disabledAt: [String: Duration] = [:]
    /// Monitors that came back more than 3 times within a minute: left on for the rest of this mode.
    /// `enterRemote` clears these, and `driftRecorded`, for each new mode.
    var flapping: Set<String> = []
    /// A-3: this mode has recorded that the virtual display left the configured resolution; once per mode.
    var driftRecorded = false
    /// From when the owed return to Normal (`exitRetryReason`) may be tried again.
    private(set) var exitRetryDue: Duration = .zero
    /// A-5: a way back reached Normal with a monitor still off. While Normal, the offline monitors are asked to turn on
    /// again every 10 s, this many more times, from `stillOffDue` on; `enterRemote` drops what is left.
    private(set) var stillOffRetries = 0
    private var stillOffDue: Duration = .zero

    /// ≥3 unclean starts within 10 minutes, this one included, as `reconcileAtStartup` counted them: modes are
    /// refused until a later start finds fewer. Normal still works.
    public internal(set) var isSafeMode = false

    /// How long a new virtual display may take to be online and active (§7.4 step 2).
    private static let virtualOnlineTimeout: Duration = .seconds(5)
    /// R56: CoreGraphics lists a change 0.05–0.31 s after its transaction (SP2), so the checks after transactions A
    /// and B wait: up to this long for the target to be listed as main (and the way back for the baseline main, B-8)...
    static let mainTimeout: Duration = .seconds(2)
    /// ...and up to this long for it to be listed as the only active display.
    private static let disableTimeout: Duration = .seconds(3)
    /// How often the waits list the displays.
    static let pollInterval: Duration = .milliseconds(100)
    /// R19: an owed return to Normal is tried again at most this often; A-5: so is a monitor left off.
    private static let exitRetryInterval: Duration = .seconds(10)
    /// A-5: how many times a monitor left off is asked for again.
    private static let stillOffAttempts = 3

    public init(backend: DisplayBackend, virtualHost: VirtualDisplayHost, lock: ScreenLockProvider, confirmer: Confirmer,
                notifier: Notifier, events: EventSink, store: StateStore, clock: any Clock<Duration>, config: Config,
                capabilities: Capabilities, scope: ConfigScope, settleDelay: Duration = .seconds(1)) {
        self.backend = backend; self.virtualHost = virtualHost; self.lock = lock; self.confirmer = confirmer
        self.notifier = notifier; self.events = events; self.store = store; self.clock = clock
        self.config = config; self.capabilities = capabilities; self.scope = scope; self.settleDelay = settleDelay
        uptime = clock.stopwatch()
        state = store.load() ?? .initial
    }

    // MARK: Remote mode (§7.4)

    /// Makes an iPad-sized virtual display the only active display. Returns once the confirmation is showing;
    /// `pendingConfirmation` applies its outcome. `confirmSeconds` overrides the config; 0 skips the confirmation.
    /// Refused, with nothing changed, in safe mode, while the Mac is locked, the display APIs are missing, a
    /// transition is running or Sidecar is active. A failure rolls back to Normal; a return to Normal or a lock that
    /// comes meanwhile ends it.
    public func enterRemote(confirmSeconds: Int? = nil) async -> CommandResult {
        if let refusal = refusalToEnter() {
            events.record("enter.remote.refused", ["reason": refusal.reason.rawValue])
            return .refused(refusal.reason, refusal.text)
        }
        enterInFlight = true
        defer { enterInFlight = false }
        latestExit = nil
        lastEnforcement = nil; reenabled = [:]; flapping = []; disabledAt = [:]; driftRecorded = false   // afresh
        clearStillOffRetry()   // the mode turns the monitors off on purpose
        let seconds = confirmSeconds ?? config.remote.confirmSeconds
        events.record("enter.remote.begin", [:])
        do {
            let target = try await startVirtualDisplay()
            try await makeMain(target)
            try await clock.sleep(for: settleDelay)   // RustDesk moves to the new display while the monitors are on
            try await keepConfiguredResolution(target)
            try await disableMonitors(keeping: target)
            try await startConfirmation(seconds: seconds)
            return .ok(Messages.remoteEntered(seconds: seconds))
        } catch {
            return await abandonEnter(error)
        }
    }

    /// The preconditions of §7.4 and the one-transition rule of §7.3, checked before anything changes. Safe mode
    /// comes first: it blocks every mode, whatever else holds.
    private func refusalToEnter() -> (reason: RefusalReason, text: String)? {
        if isSafeMode { return (.safeMode, Messages.safeMode) }
        if lock.isLocked { return (.locked, Messages.locked) }
        if !capabilities.privateAPIs { return (.unavailable, Messages.unavailable) }
        if enterInFlight || exiting != nil || state.phase != .normal { return (.busy, Messages.busy) }
        if (try? backend.listDisplays())?.contains(where: { $0.kind == .sidecar && $0.isActive }) == true {
            return (.sidecarActive, Messages.sidecarActive)
        }
        return nil
    }

    /// The resolution of Remote mode, as configured.
    var remoteResolution: Resolution { Resolution(parsing: config.remote.resolution) ?? .defaultRemote }

    /// Steps 1–2: baseline saved, virtual display started and online and active.
    private func startVirtualDisplay() async throws -> DisplayID {
        let baseline = Snapshot(displays: try backend.listDisplays(), takenAt: Date())
        try commit { $0.phase = .entering(.remote); $0.baseline = baseline; $0.target = nil; $0.virtualPID = nil }
        let handle: VirtualDisplayHandle
        do {
            handle = try await virtualHost.start(role: .remote, resolution: remoteResolution)
        } catch {
            events.record("virtual.failed", ["error": "\(error)"])
            throw TransitionFailure.virtualFailed
        }
        virtual = handle
        try ensureStillEntering()
        try commit { $0.target = handle.displayID; $0.virtualPID = handle.pid }
        let id = handle.displayID
        let online = try await waitWhileEntering(Self.virtualOnlineTimeout) { list in
            list.contains { $0.id == id && $0.isOnline && $0.isActive }
        }
        guard online else { throw TransitionFailure.virtualFailed }
        events.record("virtual.ready", ["id": "\(id.raw)"])
        return id
    }

    /// Step 3, transaction A: the target goes to (0,0) and becomes main. The monitors line up to its right in
    /// baseline order, so nothing overlaps. The target may be listed as main only a little later (R56).
    private func makeMain(_ target: DisplayID) async throws {
        try ensureStillEntering()
        let displays = try backend.listDisplays()
        let online = Set(displays.filter(\.isOnline).map(\.id))
        var origins = [target: Point(x: 0, y: 0)]
        var x = Self.width(displays.first { $0.id == target }?.mode)
        for monitor in state.baseline?.displays ?? [] where monitor.kind == .physical && online.contains(monitor.id) {
            origins[monitor.id] = Point(x: x, y: 0)
            x += Self.width(monitor.mode)
        }
        try backend.setOrigins(origins, scope: scope)
        let main = try await waitWhileEntering(Self.mainTimeout) { list in
            list.contains { $0.id == target && $0.isMain }
        }
        guard main else { throw TransitionFailure.targetNotMain }
        events.record("target.main", ["id": "\(target.raw)"])
    }

    /// A-3, between transactions A and B: macOS may switch the new display to the mode last chosen for this display
    /// identity in System Settings once another transaction runs (SP3; acceptance A1 came up 1321x918 with 1180x820
    /// configured). So, while the monitors are still on (I1), the configured mode is set again, in session scope,
    /// if the listing shows another one, and waited for up to 2 s. Not fatal: a failure is logged and the enter goes
    /// on. The config wins at every enter; a resolution chosen in System Settings is not taken over into it. After
    /// transaction B the mode of the only display is left alone (see `handle`).
    private func keepConfiguredResolution(_ target: DisplayID) async throws {
        try ensureStillEntering()
        let wanted = remoteResolution.remoteMode
        guard let listed = (try? backend.listDisplays())?.first(where: { $0.id == target }),
              listed.mode.map({ !$0.isSameMode(as: wanted) }) ?? true else { return }
        events.record("resolution.enforce", ["id": "\(target.raw)", "listed": Self.text(listed.mode),
                                             "wanted": remoteResolution.text])
        do { try backend.setMode(target, wanted, scope: .session) } catch {
            events.record("resolution.enforce.failed", ["id": "\(target.raw)", "error": "\(error)"])
            return
        }
        let applied = try await waitWhileEntering(Self.mainTimeout) { list in
            list.first { $0.id == target }?.mode.map { $0.isSameMode(as: wanted) } ?? false
        }
        if !applied { events.record("resolution.enforce.failed", ["id": "\(target.raw)", "error": "notApplied"]) }
    }

    /// Step 4, transaction B: checked right before acting (I2); afterwards the target must be the only active display,
    /// which the list may show only a little later (R56). A target that is gone or offline meanwhile ends the wait at
    /// once (B-10): it never will be, and the way back must not wait 3 s more with nothing lit.
    private func disableMonitors(keeping target: DisplayID) async throws {
        try ensureStillEntering()
        let displays = try backend.listDisplays()
        guard displays.contains(where: { $0.id == target && $0.isActive && $0.isMain }) else {
            throw TransitionFailure.targetNotMain
        }
        let monitors = displays.filter { $0.kind == .physical && $0.isOnline }
        guard !monitors.isEmpty else { return }   // no monitor attached: nothing to disconnect
        let now = uptime()
        lastDisableAt = now   // R79; also if the call fails, which may still have turned some of them off
        try backend.setEnabled(monitors.map(\.id), enabled: false, scope: scope)
        for monitor in monitors { disabledAt[Self.identity(monitor)] = now }   // B-6
        var lost = false
        let alone = try await waitWhileEntering(Self.disableTimeout) { list in
            if !list.contains(where: { $0.id == target && $0.isOnline }) { lost = true }
            return lost || list.filter(\.isActive).map(\.id) == [target]
        }
        if lost { throw TransitionFailure.targetLost }
        guard alone else { throw TransitionFailure.physicalStillActive }
        events.record("physical.disabled", ["ids": Self.text(monitors.map(\.id))])
    }

    /// Step 5. Returns once `confirmer.confirm` is running: the task resumes `started` and goes straight into
    /// `confirm` on the main actor, so the caller continues only after `confirm` has begun. From the commit on, the
    /// confirmation owns the mode, and a return to Normal (a lock included) ends it.
    private func startConfirmation(seconds: Int) async throws {
        try ensureStillEntering()
        guard seconds != 0 else {
            try commit { $0.phase = .active(.remote); $0.lastError = nil }
            return
        }
        try commit { $0.phase = .confirming(.remote); $0.lastError = nil }
        confirmationCount += 1
        let id = confirmationCount
        confirmationID = id
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            pendingConfirmation = Task { @MainActor in
                started.resume()
                guard confirmationID == id else { return }   // a return to Normal came before the dialog showed
                let outcome = await confirmer.confirm(seconds: seconds)
                await finishConfirmation(outcome, id: id)
            }
        }
    }

    /// Applies the outcome, unless a return to Normal has ended this confirmation meanwhile.
    private func finishConfirmation(_ outcome: ConfirmOutcome, id: Int) async {
        events.record("confirm.\(outcome)", [:])
        guard confirmationID == id, state.phase == .confirming(.remote) else { return }
        confirmationID = nil
        switch outcome {
        case .keep where lock.isLocked: _ = await exitToNormal(.locked)   // kept as the Mac locked: I8 wins
        case .keep: commitBestEffort { $0.phase = .active(.remote) }
        case .revert: _ = await exitToNormal(.confirmRevert)
        case .timedOut, .cancelled: _ = await exitToNormal(.confirmTimeout)   // no answer: back to Normal
        }
    }

    /// Why the enter may no longer act, or nil while it may: it must own the transition (no return to Normal is
    /// running or has taken over) and the Mac must be unlocked. No other enter can start meanwhile (busy), so the
    /// phase cannot become `.entering` again.
    private var interruption: TransitionFailure? {
        if exiting != nil || state.phase != .entering(.remote) { return .preempted }
        return lock.isLocked ? .locked : nil
    }

    private func ensureStillEntering() throws {
        if let interruption { throw interruption }
    }

    /// Ends an enter that cannot go on, and replies how it ended. A return to Normal cleans up: the one that cut
    /// in, one for the lock, or the rollback. If that return did not finish, its result is the reply.
    private func abandonEnter(_ error: any Error) async -> CommandResult {
        // `start` may have returned after a return took over: the state names its display until it is gone.
        if let virtual, state.virtualPID != virtual.pid {
            commitBestEffort { $0.target = virtual.displayID; $0.virtualPID = virtual.pid }
        }
        let failure = error as? TransitionFailure
        let outcome: CommandResult?, reply: CommandResult
        switch failure {
        case .preempted?, .locked?:
            if failure == .locked {
                events.record("enter.remote.locked", [:])
                _ = await exitToNormal(.locked)   // I8: the mode ends with the lock
            } else {
                events.record("enter.remote.preempted", [:])
            }
            outcome = await latestExit?.value
            reply = lock.isLocked ? .refused(.locked, Messages.locked) : .failed(Messages.enterFailed)
        default:
            let message = failure == .virtualFailed ? Messages.virtualFailed : Messages.enterFailed
            events.record("enter.remote.failed", ["error": "\(error)"])
            commitBestEffort { $0.lastError = "\(error)" }
            outcome = await exitToNormal(.failure, failure: message)
            reply = .failed(message)
        }
        let leftover = await stopLeftoverVirtualDisplay()
        for result in [outcome, leftover] {
            if let result, !result.isOK { return result }
        }
        return reply
    }

    // MARK: The owed return to Normal (R19)

    /// Leaves the return to Normal owed as `reason`: the periodic check tries it again 10 s from now (R19).
    func oweExit(_ reason: ExitReason) {
        exitRetryReason = reason
        exitRetryDue = uptime() + Self.exitRetryInterval
    }

    /// The owed return is settled: a return reached Normal.
    func clearOwedExit() {
        exitRetryReason = nil
    }

    // MARK: A monitor left off in Normal (A-5)

    /// Normal came back with a monitor still off: while Normal, it is asked for again every 10 s, at most 3 times.
    func oweStillOffRetry() {
        stillOffRetries = Self.stillOffAttempts
        stillOffDue = uptime() + Self.exitRetryInterval
    }

    func clearStillOffRetry() {
        stillOffRetries = 0
    }

    /// One try, once due, while Normal: every physical monitor listed offline is asked to turn on (the batch, then
    /// each alone). Nothing waits for them: the next try sees whether they came on, and once none is off, none is
    /// made. Lists nothing while no try is owed.
    func retryMonitorsStillOff() {
        guard stillOffRetries > 0, uptime() >= stillOffDue else { return }
        stillOffRetries -= 1
        stillOffDue = uptime() + Self.exitRetryInterval
        guard let displays = try? backend.listDisplays() else { return }
        let off = displays.filter { $0.kind == .physical && !$0.isOnline }.map(\.id)
        guard !off.isEmpty else {
            stillOffRetries = 0
            return
        }
        events.record("physical.retry", ["ids": Self.text(off), "left": "\(stillOffRetries)"])
        _ = backend.enableMonitors(off, scope: scope) { failed, error in
            events.record("physical.enable.failed", ["ids": Self.text(failed), "error": "\(error)"])
        }
    }

    // MARK: Resolution (§7.9)

    /// Makes `r` the resolution of Remote mode: at once on the running virtual display while Remote is active,
    /// and for every later enter. The daemon saves the config after `.ok`. Refused while a transition runs; if the
    /// display rejects the mode, nothing changes.
    public func setResolution(_ r: Resolution) async -> CommandResult {
        let busy = switch state.phase {
        case .normal, .active: enterInFlight || exiting != nil
        case .entering, .confirming, .exiting: true
        }
        if busy {
            events.record("resolution.refused", ["reason": RefusalReason.busy.rawValue])
            return .refused(.busy, Messages.busy)
        }
        if state.phase == .active(.remote), let virtual {
            do { try backend.setMode(virtual.displayID, r.remoteMode, scope: scope) } catch {
                events.record("resolution.failed", ["resolution": r.text, "error": "\(error)"])
                return .failed(Messages.resolutionFailed(r))
            }
        }
        config.remote.resolution = r.text
        events.record("resolution.set", ["resolution": r.text])
        return .ok(Messages.resolutionSet(r))
    }

    // MARK: Helpers

    /// Write-ahead: the changed state is saved before the caller acts on it; `state` changes only once saved.
    func commit(_ change: (inout PersistedState) -> Void) throws {
        var next = state
        change(&next)
        next.updatedAt = Date()
        try store.save(next)
        state = next
    }

    /// For the way back to Normal, which goes on even if the state cannot be saved.
    func commitBestEffort(_ change: (inout PersistedState) -> Void) {
        do { try commit(change) } catch {
            events.record("state.save.failed", ["error": "\(error)"])
            change(&state)
        }
    }

    /// Polls `listDisplays()` every 100 ms until `ready` holds, for at most `timeout`.
    func waitUntil(_ timeout: Duration, _ ready: ([DisplayInfo]) -> Bool) async -> Bool {
        await clock.poll(timeout: timeout, every: Self.pollInterval) {
            (try? backend.listDisplays()).map(ready) ?? false
        }
    }

    /// Waits on the injected clock until `uptime()` reaches `time`, at once if it has; only a cancelled task stops
    /// waiting early. The main thread stays free meanwhile.
    func wait(until time: Duration) async {
        let left = time - uptime()
        guard left > .zero else { return }
        try? await clock.sleep(for: left)
    }

    /// `waitUntil` for the way in: it also ends as soon as the enter may no longer act, even while the displays cannot
    /// be listed, and then throws that `interruption`. Otherwise returns whether `ready` held, never true for a check
    /// that was cut short.
    private func waitWhileEntering(_ timeout: Duration, _ ready: ([DisplayInfo]) -> Bool) async throws -> Bool {
        var held = false
        _ = await clock.poll(timeout: timeout, every: Self.pollInterval) {
            guard interruption == nil else { return true }
            held = (try? backend.listDisplays()).map(ready) == true
            return held
        }
        try ensureStillEntering()
        return held
    }

    static func width(_ mode: DisplayMode?) -> Int32 {
        Int32(mode?.widthPoints ?? Resolution.defaultRemote.width)
    }

    static func text(_ ids: [DisplayID]) -> String {
        ids.map { "\($0.raw)" }.joined(separator: ",")
    }

    /// A mode as its size in points, e.g. `1180x820`; `none` without one.
    static func text(_ mode: DisplayMode?) -> String {
        mode.map { "\($0.widthPoints)x\($0.heightPoints)" } ?? "none"
    }
}

/// Why a mode change could not go on. The case name is a detail for `events` and `lastError` only.
enum TransitionFailure: Error {
    /// The virtual display could not be started, or was not online and active within 5 s.
    case virtualFailed
    /// The virtual display is not the active main display, or was not listed as main within 2 s of transaction A.
    case targetNotMain
    /// 3 s after disabling the monitors, a display other than the virtual one is still listed as active.
    case physicalStillActive
    /// While the monitors were being turned off, the virtual display went away or offline (B-10).
    case targetLost
    /// A return to Normal started or finished while entering; it owns the cleanup.
    case preempted
    /// The Mac locked while entering; no mode is entered while it is locked (I8).
    case locked
    /// On the way back no monitor became active, so the virtual display has to stay (I1).
    case monitorsNotActive
}

extension CommandResult {
    var isOK: Bool {
        switch self {
        case .ok: true
        case .refused, .failed: false
        }
    }
}
