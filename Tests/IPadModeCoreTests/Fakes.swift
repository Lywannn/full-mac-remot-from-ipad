import os
import Testing
@testable import IPadModeCore

enum FakeError: Error {
    case injected, unknownDisplay
    /// What CoreGraphics answers when a transaction enables a display that is on already (spikes.md: 1001).
    case alreadyOn
}

/// How a monitor that was turned on is listed while it wakes, one step per `listDisplays()`. Waking from standby it
/// may show online but dark, drop out of the listing, and only then come up lit (SP4, R25 on hardware).
enum WakeStep: Equatable {
    /// Listed as when it was off.
    case offline
    /// Listed online, but not active.
    case onlineDark
    /// Not listed at all.
    case missing
}

/// Behaves like macOS for the calls the Coordinator makes, and records them.
@MainActor
final class FakeDisplayBackend: DisplayBackend {
    enum Method: Hashable { case listDisplays, enable, disable, setOrigins, setMode }

    /// What macOS would report. Tests may change it at any time (unplug a monitor, renumber IDs, ...).
    var displays: [DisplayInfo]
    /// Every display-changing call, shared with `FakeVirtualHost`, e.g. `"start(remote)"`, `"setOrigins"`,
    /// `"setEnabled([1, 3],false)"`, `"setMode(1)"`, `"stop(remote)"`.
    private(set) var calls: [String] = []
    /// `displays` right after each call: `history[i]` belongs to `calls[i]`.
    private(set) var history: [[DisplayInfo]] = []
    /// The argument of each `setOrigins` call.
    private(set) var originRequests: [[DisplayID: Point]] = []
    /// The scope of each `setEnabled`, `setOrigins` and `setMode` call.
    private(set) var scopes: [ConfigScope] = []
    private(set) var listCount = 0
    /// Errors to throw. A failing call is still recorded, but changes nothing.
    var failing: [Method: any Error] = [:]
    /// Whether an enabling `setEnabled` for these IDs fails, as one transaction naming a monitor that cannot be
    /// enabled does. A rejected call is recorded, changes nothing and throws `FakeError.injected`.
    var rejectEnable: (([DisplayID]) -> Bool)?
    /// How many `listDisplays()` calls an offline display turned on with `setEnabled(_, enabled: true)` takes to
    /// show as online and active, like a monitor waking up. 0: at once. Asked again meanwhile, it keeps waking where
    /// it is: a second request does not start its wake over.
    var enableDelay = 0
    /// Per monitor, how it wakes once turned on, by the Coordinator or by another process (`turnOnElsewhere`): one
    /// step per list, then online and active. Such a monitor counts as on from the moment it was turned on. It
    /// takes the place of `enableDelay` for that monitor.
    var wakeSteps: [DisplayID: [WakeStep]] = [:]
    /// Whether an enabling `setEnabled` that names a monitor that is on already fails as a whole, as in CoreGraphics
    /// (spikes.md: 1001): one listed online, or one waking through its `wakeSteps`. The call is recorded, changes
    /// nothing, and throws `FakeError.alreadyOn`.
    var rejectsEnablingOn = true
    /// "Late CG" (R56): how many `listDisplays()` calls the change of a `setOrigins`, or of a disabling `setEnabled`,
    /// takes to show, as CoreGraphics lists a change 0.05–0.31 s after its transaction completed. 0: at once. Each
    /// call keeps the delay set when it was made; until its change shows, `history` and the lists show the layout
    /// from before it.
    var originsDelay = 0, disableDelay = 0
    /// "Late CG" by time (R79): how long after a disabling `setEnabled`, on `clock`, the first list shows its change.
    /// Zero: at once, or after `disableDelay` lists if that is set.
    var disableLateness: Duration = .zero
    /// The rig's clock, which `disableLateness` is measured on.
    var clock: InstantClock?
    /// Runs after each recorded call, e.g. to capture state at that moment or to change `displays`.
    var onCall: ((String) -> Void)?
    /// Runs at the start of each `listDisplays()`, e.g. to change `displays` while the Coordinator waits.
    var onList: (() -> Void)?
    /// What each `listDisplays()` returned, late changes included. With `history`, every state the Coordinator saw.
    private(set) var listings: [[DisplayInfo]] = []
    private var waking: [DisplayID: Int] = [:]
    /// The monitors waking through their `wakeSteps`, with the steps they still have to show.
    private var sequences: [DisplayID: [WakeStep]] = [:]
    /// The late changes, oldest first, each with the number of lists it still takes to show...
    private var late: [(lists: Int, change: () -> Void)] = []
    /// ...or with the time on `clock` from which the lists show it.
    private var lateUntil: [(due: Duration, change: () -> Void)] = []

    init(_ displays: [DisplayInfo]) { self.displays = displays }

    func listDisplays() throws -> [DisplayInfo] {
        listCount += 1
        onList?()
        if let error = failing[.listDisplays] { throw error }
        let now = clock?.elapsed ?? .zero
        let due = lateUntil.filter { $0.due <= now }
        lateUntil.removeAll { $0.due <= now }
        var shown = due.map(\.change)
        late = late.compactMap { entry in
            guard entry.lists <= 1 else { return (entry.lists - 1, entry.change) }
            shown.append(entry.change)
            return nil
        }
        for change in shown { change() }
        for (id, left) in waking {
            if left > 1 { waking[id] = left - 1; continue }
            waking[id] = nil
            for i in displays.indices where displays[i].id == id {
                displays[i].isOnline = true; displays[i].isActive = true
            }
        }
        var hidden: Set<DisplayID> = []
        for (id, steps) in sequences {
            let step = steps.first
            sequences[id] = step == nil ? nil : Array(steps.dropFirst())
            for i in displays.indices where displays[i].id == id {
                switch step {
                case .offline?: displays[i].isOnline = false; displays[i].isActive = false
                case .onlineDark?: displays[i].isOnline = true; displays[i].isActive = false
                case .missing?: hidden.insert(id)
                case nil: displays[i].isOnline = true; displays[i].isActive = true
                }
            }
        }
        let listed = displays.filter { !hidden.contains($0.id) }
        listings.append(listed)
        return listed
    }

    /// Off: offline, inactive and not main; if that was the main display, another active one takes over (see
    /// `promoteMain`). On: online and active (after `enableDelay` lists, or through its `wakeSteps`, if set).
    func setEnabled(_ ids: [DisplayID], enabled: Bool, scope: ConfigScope) throws {
        let rejected = enabled && rejectEnable?(ids) == true
        let alreadyOn = enabled && rejectsEnablingOn && ids.contains { isOn($0) }
        try perform("setEnabled(\(ids.map(\.raw)),\(enabled))", scope, enabled ? .enable : .disable,
                    rejecting: rejected ? FakeError.injected : alreadyOn ? FakeError.alreadyOn : nil,
                    late: enabled ? 0 : disableDelay, lateness: enabled ? .zero : disableLateness) { [self] in
            for i in displays.indices where ids.contains(displays[i].id) {
                if !enabled {
                    waking[displays[i].id] = nil; sequences[displays[i].id] = nil
                    displays[i].isOnline = false; displays[i].isActive = false; displays[i].isMain = false
                } else {
                    turnOn(at: i)
                }
            }
            if !enabled { promoteMain() }
        }
    }

    /// The world, not the Coordinator: another process turns these monitors on. They wake as they would for the
    /// Coordinator. Not recorded as a call.
    func turnOnElsewhere(_ ids: [DisplayID]) {
        for i in displays.indices where ids.contains(displays[i].id) { turnOn(at: i) }
    }

    /// On, or waking through its `wakeSteps`, as CoreGraphics sees it.
    private func isOn(_ id: DisplayID) -> Bool {
        sequences[id] != nil || displays.contains { $0.id == id && $0.isOnline }
    }

    /// A monitor that is asked to turn on: through its `wakeSteps`, after `enableDelay` lists, or at once. One that
    /// is waking already keeps waking where it is, unless `enableDelay` is 0 by now: then it comes on at once.
    private func turnOn(at i: Int) {
        let id = displays[i].id
        if sequences[id] != nil { return }
        if !displays[i].isOnline, let steps = wakeSteps[id] {
            sequences[id] = steps
        } else if !displays[i].isOnline, enableDelay > 0 {
            if waking[id] == nil { waking[id] = enableDelay }
        } else {
            waking[id] = nil
            displays[i].isOnline = true; displays[i].isActive = true
        }
    }

    /// The world, not the Coordinator: macOS loses a display (unplugged, or the process behind it ended). Not
    /// recorded as a call. If it was the main display, another active one takes over (see `promoteMain`).
    func remove(_ id: DisplayID) {
        waking[id] = nil; sequences[id] = nil
        displays.removeAll { $0.id == id }
        promoteMain()
    }

    /// macOS always keeps a main display, at (0,0): when there is none, the first active display takes over and
    /// the whole layout moves with it, so that it lands at (0,0) and nothing else changes place relative to it.
    private func promoteMain() {
        guard !displays.contains(where: \.isMain), let next = displays.firstIndex(where: \.isActive) else { return }
        let shift = displays[next].origin
        for i in displays.indices {
            displays[i].origin = Point(x: displays[i].origin.x - shift.x, y: displays[i].origin.y - shift.y)
        }
        displays[next].isMain = true
    }

    /// Moves the given displays; the online display at (0,0) becomes the only main one. Like one CoreGraphics
    /// transaction, a display that is not in `displays` fails the whole call (`FakeError.unknownDisplay`).
    func setOrigins(_ origins: [DisplayID: Point], scope: ConfigScope) throws {
        originRequests.append(origins)
        let unknown = origins.keys.contains { id in !displays.contains { $0.id == id } }
        try perform("setOrigins", scope, .setOrigins, rejecting: unknown ? FakeError.unknownDisplay : nil,
                    late: originsDelay) { [self] in
            for i in displays.indices {
                if let origin = origins[displays[i].id] { displays[i].origin = origin }
            }
            // As in CoreGraphics, the display at (0,0) is the main one; an online display this call puts there wins.
            let zero = Point(x: 0, y: 0)
            let placed = displays.first { $0.isOnline && origins[$0.id] == zero }
            guard let main = placed ?? displays.first(where: { $0.isOnline && $0.origin == zero }) else { return }
            for i in displays.indices { displays[i].isMain = displays[i].id == main.id }
        }
    }

    func setMode(_ id: DisplayID, _ mode: DisplayMode, scope: ConfigScope) throws {
        try perform("setMode(\(id.raw))", scope, .setMode) { [self] in
            for i in displays.indices where displays[i].id == id { displays[i].mode = mode }
        }
    }

    /// Records a call and the displays right after it.
    func record(_ call: String) {
        calls.append(call)
        history.append(displays)
        onCall?(call)
    }

    /// `rejecting`: an error for this call alone, thrown like an injected one. `late`: the lists its change takes to
    /// show (`originsDelay`, `disableDelay`); `lateness`: the time it takes (`disableLateness`). A failing call has no
    /// change to show.
    private func perform(_ call: String, _ scope: ConfigScope, _ method: Method, rejecting: (any Error)? = nil,
                         late lists: Int = 0, lateness: Duration = .zero, _ change: @escaping () -> Void) throws {
        scopes.append(scope)
        let error = rejecting ?? failing[method]
        if error == nil {
            if lists > 0 {
                late.append((lists, change))
            } else if lateness > .zero, let clock {
                lateUntil.append((clock.elapsed + lateness, change))
            } else {
                change()
            }
        }
        record(call)
        if let error { throw error }
    }
}

/// A point where a fake call can be held until the test lets it go on. Open unless closed.
@MainActor
final class Gate {
    private(set) var isClosed = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [Int: CheckedContinuation<Void, Never>] = [:]
    private var watcherCount = 0

    func close() { isClosed = true }

    /// Opens the gate and lets the held calls go on.
    func open() {
        isClosed = false
        let calls = held
        held = []
        for call in calls { call.resume() }
    }

    /// Returns once a call is held at the gate. If none comes within `limit`, it records an issue and returns, so
    /// that a regression fails the test instead of hanging the run.
    func untilHolding(within limit: Duration = .seconds(2)) async {
        guard held.isEmpty else { return }
        watcherCount += 1
        let id = watcherCount
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            self?.giveUp(id, after: limit)
        }
        await withCheckedContinuation { watchers[id] = $0 }
        timer.cancel()
    }

    /// For the fakes: waits here while the gate is closed.
    func pass() async {
        guard isClosed else { return }
        await withCheckedContinuation { call in
            held.append(call)
            let waiting = watchers.values
            watchers = [:]
            for watcher in waiting { watcher.resume() }
        }
    }

    private func giveUp(_ id: Int, after limit: Duration) {
        guard let watcher = watchers.removeValue(forKey: id) else { return }
        Issue.record("no call reached the gate within \(limit)")
        watcher.resume()
    }
}

/// Adds and removes the virtual display in the backend's list, recording into the backend's `calls`.
@MainActor
final class FakeVirtualHost: VirtualDisplayHost {
    private let backend: FakeDisplayBackend
    var startError: (any Error)?
    /// `false`: `start` returns a handle, but the display never shows up in `listDisplays()`.
    var appears = true
    /// Closed, they hold `start` before its display appears, and `stop` while its display is still there.
    let startGate: Gate, stopGate: Gate
    private(set) var resolutions: [Resolution] = []

    init(backend: FakeDisplayBackend) {
        self.backend = backend
        startGate = Gate(); stopGate = Gate()
    }

    func start(role: VirtualRole, resolution: Resolution) async throws -> VirtualDisplayHandle {
        resolutions.append(resolution)
        await startGate.pass()
        if startError == nil, appears {
            // macOS adds the new display beside the layout, right of the rightmost display.
            let right = backend.displays.filter(\.isOnline).map { $0.origin.x + Int32($0.mode?.widthPoints ?? 0) }.max()
            var display = Fixtures.virtualRemote
            display.origin = Point(x: right ?? 0, y: 0)
            display.mode = DisplayMode(widthPoints: resolution.width, heightPoints: resolution.height,
                                       widthPixels: resolution.width * 2, heightPixels: resolution.height * 2,
                                       refreshHz: 60)
            backend.displays.append(display)
        }
        backend.record("start(\(role.rawValue))")
        if let startError { throw startError }
        return VirtualDisplayHandle(role: role, pid: 4242, displayID: Fixtures.virtualRemote.id)
    }

    /// The display goes as macOS loses it: if it was main, another active display takes over.
    func stop(_ handle: VirtualDisplayHandle) async {
        await stopGate.pass()
        backend.remove(handle.displayID)
        backend.record("stop(\(handle.role.rawValue))")
    }
}

@MainActor
final class FakeLock: ScreenLockProvider {
    var isLocked = false
}

/// Answers at once with a fixed outcome, or holds each `confirm` until `resolve(_:)` or `cancel()`, like one
/// dialog per call. A new `confirm` never replaces one that is still held.
@MainActor
final class FakeConfirmer: Confirmer {
    /// `nil` holds the confirmation.
    var outcome: ConfirmOutcome?
    /// `false`: `cancel()` is only counted, and a held dialog still answers later through `resolve(_:)`, like one
    /// that was answered just as it was closed.
    var cancelAnswers = true
    /// The `seconds` of each `confirm` call.
    private(set) var requests: [Int] = []
    private(set) var cancels = 0
    /// The held dialogs, oldest first.
    private var held: [CheckedContinuation<ConfirmOutcome, Never>] = []
    var isHolding: Bool { !held.isEmpty }

    init(_ outcome: ConfirmOutcome?) { self.outcome = outcome }

    func confirm(seconds: Int) async -> ConfirmOutcome {
        requests.append(seconds)
        if let outcome { return outcome }
        return await withCheckedContinuation { held.append($0) }
    }

    /// Answers the oldest held dialog.
    func resolve(_ outcome: ConfirmOutcome) {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(returning: outcome)
    }

    func cancel() {
        cancels += 1
        guard cancelAnswers else { return }
        let dialogs = held
        held = []
        for dialog in dialogs { dialog.resume(returning: .cancelled) }
    }
}

@MainActor
final class FakeNotifier: Notifier {
    private(set) var notices: [String] = []
    func notice(_ text: String) { notices.append(text) }
}

final class FakeEventSink: EventSink {
    struct Event: Equatable, Sendable {
        var name: String
        var fields: [String: String]
    }

    private struct Log: Sendable {
        var events: [Event] = []
        var onRecord: (@Sendable (Event) -> Void)?
    }

    private let log = OSAllocatedUnfairLock(initialState: Log())

    func record(_ name: String, _ fields: [String: String]) {
        let event = Event(name: name, fields: fields)
        let hook = log.withLock { log -> (@Sendable (Event) -> Void)? in
            log.events.append(event)
            return log.onRecord
        }
        hook?(event)
    }

    /// Runs `action` right after each event is recorded, on the thread that records it.
    func onRecord(_ action: @escaping @Sendable (Event) -> Void) {
        log.withLock { $0.onRecord = action }
    }

    var all: [Event] { log.withLock { $0.events } }
    var names: [String] { all.map(\.name) }
}

/// A `Clock` whose `sleep` moves `now` to the deadline and returns at once, so a 5-second poll takes no time.
final class InstantClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    typealias Action = @Sendable @MainActor () async -> Void

    private struct State: Sendable {
        var now = Instant(offset: .zero)
        var duringNextSleep: Action?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }
    /// Time slept so far.
    var elapsed: Swift.Duration { now.offset }

    /// Runs `action` inside the next `sleep`, before it returns: what it does happens while the sleeper waits.
    func duringNextSleep(_ action: @escaping Action) {
        state.withLock { $0.duringNextSleep = action }
    }

    /// Lets `duration` pass, as between two events.
    func advance(by duration: Swift.Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        try Task.checkCancellation()
        let action = state.withLock { s -> Action? in
            s.now = max(s.now, deadline)
            defer { s.duringNextSleep = nil }
            return s.duringNextSleep
        }
        if let action { await action() }
    }
}

/// A Coordinator wired to fresh fakes: by default the Legion and P24 are attached and the confirmation is kept.
@MainActor
struct CoordinatorRig {
    let backend: FakeDisplayBackend
    let host: FakeVirtualHost
    let lock: FakeLock
    let confirmer: FakeConfirmer
    let notifier: FakeNotifier
    let events: FakeEventSink
    let store: MemoryStateStore
    let clock: InstantClock
    let coordinator: Coordinator

    /// `confirm: nil` holds the confirmation until `confirmer.resolve(_:)`. `persisted`: what the last run left
    /// in `state.json`; nil, as if it were missing or unreadable.
    init(displays: [DisplayInfo] = [Fixtures.legion, Fixtures.p24], confirm outcome: ConfirmOutcome? = .keep,
         config: Config = .default, scope: ConfigScope = .appOnly,
         capabilities: Capabilities = Capabilities(privateAPIs: true), persisted: PersistedState? = nil) {
        backend = FakeDisplayBackend(displays)
        host = FakeVirtualHost(backend: backend)
        lock = FakeLock()
        confirmer = FakeConfirmer(outcome)
        notifier = FakeNotifier()
        events = FakeEventSink()
        store = MemoryStateStore(persisted)
        clock = InstantClock()
        backend.clock = clock
        coordinator = Coordinator(backend: backend, virtualHost: host, lock: lock, confirmer: confirmer,
                                  notifier: notifier, events: events, store: store, clock: clock, config: config,
                                  capabilities: capabilities, scope: scope)
    }

    /// How long the user takes to keep the mode in `inRemote` and `started(inRemote:)`. The fake confirmer answers at
    /// once, but a person answers a dialog after a few seconds, so the monitors were disabled well before anything
    /// that follows, and R79's settle after a fresh disable does not apply to it.
    static let keptAfter: Duration = .seconds(2)

    /// A rig in `.active(.remote)`: entered, confirmation kept `keptAfter` later.
    static func inRemote(displays: [DisplayInfo] = [Fixtures.legion, Fixtures.p24],
                         scope: ConfigScope = .appOnly) async -> CoordinatorRig {
        let rig = CoordinatorRig(displays: displays, scope: scope)
        _ = await rig.coordinator.enterRemote()
        await rig.coordinator.pendingConfirmation?.value
        rig.clock.advance(by: keptAfter)
        return rig
    }

    /// A rig as the running daemon has it: started with `reconcileAtStartup` (so a crash from here on would count),
    /// then in `.active(.remote)` if asked, kept as in `inRemote`.
    static func started(inRemote: Bool = false,
                        displays: [DisplayInfo] = [Fixtures.legion, Fixtures.p24]) async -> CoordinatorRig {
        let rig = CoordinatorRig(displays: displays, persisted: .initial)
        await rig.coordinator.reconcileAtStartup()
        if inRemote {
            _ = await rig.coordinator.enterRemote()
            await rig.coordinator.pendingConfirmation?.value
            rig.clock.advance(by: keptAfter)
        }
        return rig
    }
}
