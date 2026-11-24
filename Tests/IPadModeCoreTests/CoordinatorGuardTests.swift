import Foundation
import Testing
@testable import IPadModeCore

private let virtualID = Fixtures.virtualRemote.id
private let legionID = Fixtures.legion.id
private let p24ID = Fixtures.p24.id

/// A monitor that was not attached when the mode began.
private let newMonitor = DisplayInfo(
    id: DisplayID(raw: 9), uuid: "UUID-NEW", vendor: 0x10AC, model: 0x4321, serial: 0,
    location: "dispext2", name: "U2723QE", kind: .physical, isOnline: true, isActive: true, isMain: false,
    origin: Point(x: 1180, y: 0),
    mode: DisplayMode(widthPoints: 2560, heightPoints: 1440, widthPixels: 2560, heightPixels: 1440, refreshHz: 60),
    mirrorOf: nil)

/// An iPad connected over Sidecar as one more monitor.
private let sidecar = DisplayInfo(
    id: DisplayID(raw: 11), uuid: "UUID-SIDECAR", vendor: 0x6161706C, model: 0x69506164, serial: 0,
    location: nil, name: "iPad", kind: .sidecar, isOnline: true, isActive: true, isMain: false,
    origin: Point(x: 3740, y: 0),
    mode: DisplayMode(widthPoints: 1180, heightPoints: 820, widthPixels: 2360, heightPixels: 1640, refreshHz: 60),
    mirrorOf: nil)

/// Another app's virtual display.
private let otherVirtual = DisplayInfo(
    id: DisplayID(raw: 60), uuid: "UUID-OTHER", vendor: 0x5150, model: 2, serial: 0,
    location: nil, name: "Other Virtual", kind: .otherVirtual, isOnline: true, isActive: true, isMain: false,
    origin: Point(x: 4920, y: 0),
    mode: DisplayMode(widthPoints: 1920, heightPoints: 1080, widthPixels: 1920, heightPixels: 1080, refreshHz: 60),
    mirrorOf: nil)

/// As a disabled monitor is listed: known, but offline. `origin`: where it was last, if not its baseline place.
private func disconnected(_ display: DisplayInfo, at origin: Point? = nil) -> DisplayInfo {
    var off = display
    off.isOnline = false; off.isActive = false; off.isMain = false
    if let origin { off.origin = origin }
    return off
}

/// What a run that crashed in Remote left in `state.json`.
private func crashedInRemote() -> PersistedState {
    var state = PersistedState.initial
    state.phase = .active(.remote)
    state.baseline = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    state.target = virtualID
    state.virtualPID = 4242
    state.cleanShutdown = false
    return state
}

/// The monitors as a crash in Remote left them: off, where the mode had moved them.
private let monitorsLeftOff = [disconnected(Fixtures.legion, at: Point(x: 1180, y: 0)),
                               disconnected(Fixtures.p24, at: Point(x: 4620, y: 0))]

private extension FakeDisplayBackend {
    /// The world, not the Coordinator: macOS turns a disabled monitor back on by itself, under a new ID if given
    /// (a replug).
    func turnOn(_ id: DisplayID, as newID: DisplayID? = nil) {
        for i in displays.indices where displays[i].id == id {
            displays[i].isOnline = true; displays[i].isActive = true
            if let newID { displays[i].id = newID }
        }
    }

    /// Replugged, the Legion comes back as main, where it was before the mode; the virtual display moves right
    /// of it.
    func legionComesBackAsMain() {
        for i in displays.indices {
            if displays[i].id == legionID {
                displays[i].isOnline = true; displays[i].isActive = true; displays[i].isMain = true
                displays[i].origin = Point(x: 0, y: 0)
            }
            if displays[i].id == virtualID {
                displays[i].isMain = false; displays[i].origin = Point(x: 3440, y: 0)
            }
        }
    }

    /// I1 over the Coordinator's own calls: after each one, some display is active.
    var neverLeftZeroActive: Bool { history.allSatisfy { $0.contains(where: \.isActive) } }

    /// Another app's virtual display takes main: it sits at (0,0), and ours moved right of it. No monitor comes on.
    func otherAppTakesMain() {
        for i in displays.indices where displays[i].id == virtualID {
            displays[i].isMain = false; displays[i].origin = Point(x: 1920, y: 0)
        }
        var other = otherVirtual
        other.isMain = true; other.origin = Point(x: 0, y: 0)
        displays.append(other)
    }
}

/// Every way back to Normal that began, each counted once however often it asks for the monitors (A-2).
private func wayBackAttempts(_ events: FakeEventSink) -> Int {
    events.names.filter { $0.hasPrefix("exit.") && $0.hasSuffix(".begin") }.count
}

/// When each event was recorded, on the rig's clock.
@MainActor
private final class EventTimes {
    private var times: [String: [Duration]] = [:]

    init(_ rig: CoordinatorRig) {
        let clock = rig.clock
        rig.events.onRecord { [self] event in
            MainActor.assumeIsolated { times[event.name, default: []].append(clock.elapsed) }
        }
    }

    subscript(_ name: String) -> [Duration] { times[name] ?? [] }
}

@MainActor
struct CoordinatorGuardTests {
    // MARK: Target lost and lock: at once (§7.7 steps 0–1)

    @Test func targetLostExitsImmediately() async {
        let rig = await CoordinatorRig.inRemote()
        let before = rig.clock.elapsed
        rig.backend.remove(virtualID)   // the vdisplay process ended, and its display with it
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.targetLost])
        #expect(rig.clock.elapsed == before)   // nothing waited: no debounce
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.events.all.contains(.init(name: "guard.target.lost", fields: ["id": "50"])))
    }

    @Test func onlyAnAbsentOrOfflineTargetIsLost() async {
        let rig = await CoordinatorRig.inRemote()
        func setTarget(online: Bool, active: Bool) {
            for i in rig.backend.displays.indices where rig.backend.displays[i].id == virtualID {
                rig.backend.displays[i].isOnline = online; rig.backend.displays[i].isActive = active
                rig.backend.displays[i].isMain = active
            }
        }
        // Display sleep, or a blink during a mode change: online but not active. Not lost (R31); and with the
        // target not active, a monitor that came back is not disabled either (I2). The watchdog's grace covers it.
        setTarget(online: true, active: false)
        rig.backend.turnOn(legionID)
        let calls = rig.backend.calls
        for _ in 1...3 {
            await rig.coordinator.handle(.tick)
            rig.clock.advance(by: .seconds(1))
        }
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.backend.calls == calls && rig.notifier.notices.isEmpty)
        setTarget(online: true, active: true)
        await rig.coordinator.handle(.tick)
        #expect(rig.backend.calls.last == "setEnabled([1],false)")   // active again: the monitor goes
        // Offline: lost, and Normal at once.
        setTarget(online: false, active: false)
        await rig.coordinator.handle(.tick)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.targetLost])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func targetLostWithMonitorsThatNeverComeOnStaysOwed() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.enableDelay = 1000   // the monitors do not wake within the 10 s wait
        rig.backend.remove(virtualID)    // and the virtual display is gone: nothing is on at all
        let before = rig.clock.elapsed
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.clock.elapsed - before == .seconds(10))
        // Not Normal, since nothing shows: the return stays owed, and the user hears it failed.
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.coordinator.exitRetryReason == .targetLost)
        #expect(rig.coordinator.state.lastError == "monitorsNotActive")
        #expect(rig.notifier.notices == [Messages.exitFailed])
        // Ten seconds later the monitors do wake, and Normal is reached.
        rig.backend.enableDelay = 0
        rig.clock.advance(by: .seconds(10))
        await rig.coordinator.handle(.tick)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.notifier.notices == [Messages.exitFailed, Messages.targetLost])
    }

    @Test func targetLostWhileConfirmingReverts() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()   // the dialog shows on the virtual display
        rig.backend.remove(virtualID)
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.confirmer.cancels == 1 && !rig.confirmer.isHolding)   // the dialog was closed
        #expect(rig.notifier.notices == [Messages.targetLost])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func targetLostNotDelayedByRateLimit() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.turnOn(legionID)
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.backend.calls.last == "setEnabled([1],false)")   // an enforcement action: its 500 ms begin
        rig.clock.advance(by: .milliseconds(100))
        // The Legion comes back on, and as the virtual display goes, macOS makes the Legion main.
        rig.backend.turnOn(legionID)
        rig.backend.remove(virtualID)
        let before = rig.clock.elapsed
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.targetLost])
        // The rate limit adds nothing; the one wait is R79's: until 1 s after the guard's disable, 0.1 s ago.
        #expect(rig.clock.elapsed - before == .milliseconds(900))
        #expect(rig.backend.calls.filter { $0.hasSuffix(",false)") } == ["setEnabled([1, 3],false)",
                                                                       "setEnabled([1],false)"])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func lockedExitsImmediately() async {
        let rig = await CoordinatorRig.inRemote()
        rig.lock.isLocked = true
        await rig.coordinator.handle(.screenLocked)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.revertedLocked])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])

        // The notification was missed: the periodic check finds the lock, also right after an enforcement action.
        let missed = await CoordinatorRig.inRemote()
        missed.backend.turnOn(legionID)
        await missed.coordinator.handle(.displaysChanged)
        missed.clock.advance(by: .milliseconds(100))
        missed.lock.isLocked = true
        await missed.coordinator.handle(.tick)
        #expect(missed.coordinator.state.phase == .normal)
        #expect(missed.notifier.notices == [Messages.revertedLocked])
        #expect(missed.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func keepWhileLockedReturnsToNormal() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.lock.isLocked = true   // locked, and the notification has not come yet
        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .normal)
        #expect(!rig.store.saves.contains { $0.phase == .active(.remote) })   // never kept while locked (I8)
        #expect(rig.notifier.notices == [Messages.revertedLocked])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    // MARK: Enforcement (§7.7 steps 2–3)

    @Test func physicalReenabledIsDisabledAgain() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.turnOn(legionID)   // macOS turned the Legion back on by itself
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.backend.calls.last == "setEnabled([1],false)")
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(rig.backend.neverLeftZeroActive)
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.events.all.contains(.init(name: "guard.physical.disabled", fields: ["ids": "1"])))
        #expect(rig.notifier.notices.isEmpty)
    }

    @Test func enforcementMatchesMonitorsByKind() async {
        let rig = await CoordinatorRig.inRemote()
        // The Legion comes back under a new ID, a monitor that was never there is plugged in, and Sidecar and
        // another app's virtual display come on. Only the physical monitors go.
        rig.backend.turnOn(legionID, as: DisplayID(raw: 7))
        rig.backend.displays += [newMonitor, sidecar, otherVirtual]
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.backend.calls.last == "setEnabled([7, 9],false)")
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID, sidecar.id, otherVirtual.id])
        #expect(rig.coordinator.state.phase == .active(.remote))
    }

    @Test func noEnforcementBeforeTheModeIsKept() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.backend.turnOn(legionID)
        await rig.coordinator.handle(.displaysChanged)
        #expect(!rig.backend.calls.contains("setEnabled([1],false)"))   // nobody has kept the mode yet
        // Kept a few seconds later, as a person answers: right after its disable a monitor is only listed late (B-6).
        rig.clock.advance(by: CoordinatorRig.keptAfter)
        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value
        await rig.coordinator.handle(.tick)
        #expect(rig.backend.calls.last == "setEnabled([1],false)")
    }

    @Test func enforcementRateLimitedTo500ms() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.turnOn(legionID)
        await rig.coordinator.handle(.displaysChanged)
        rig.clock.advance(by: .milliseconds(200))
        // The other monitor comes on: the same one listed on again this soon is only listed late (B-6).
        rig.backend.turnOn(p24ID)
        await rig.coordinator.handle(.displaysChanged)
        #expect(!rig.backend.calls.contains("setEnabled([3],false)"))
        #expect(rig.backend.displays.first { $0.id == p24ID }?.isActive == true)   // left on for now
        rig.clock.advance(by: .milliseconds(300))
        await rig.coordinator.handle(.tick)   // 500 ms after the last action
        #expect(rig.backend.calls.filter { $0.hasSuffix(",false)") }
                == ["setEnabled([1, 3],false)", "setEnabled([1],false)", "setEnabled([3],false)"])
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
    }

    @Test func flappingStopsAfterThreePerMinute() async {
        let rig = await CoordinatorRig.inRemote()
        for _ in 1...3 {
            rig.backend.turnOn(legionID)
            await rig.coordinator.handle(.displaysChanged)
            rig.clock.advance(by: .seconds(10))
        }
        #expect(rig.backend.calls.filter { $0 == "setEnabled([1],false)" }.count == 3)
        #expect(rig.notifier.notices.isEmpty)
        // The fourth time within a minute, back under a new ID after a replug: left on, and the user is told.
        rig.backend.turnOn(legionID, as: DisplayID(raw: 7))
        await rig.coordinator.handle(.displaysChanged)
        #expect(!rig.backend.calls.contains("setEnabled([7],false)"))
        #expect(rig.notifier.notices == [Messages.flapping("Legion 34W-2c")])
        #expect(rig.events.all.contains(.init(name: "guard.flapping", fields: ["id": "7", "name": "Legion 34W-2c"])))
        // From then on it is left alone, without another notice, while the P24 is still kept off.
        rig.clock.advance(by: .seconds(1))
        rig.backend.turnOn(p24ID)
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.backend.calls.last == "setEnabled([3],false)")
        rig.clock.advance(by: .seconds(1))
        await rig.coordinator.handle(.tick)
        #expect(rig.backend.calls.last == "setEnabled([3],false)")
        #expect(rig.notifier.notices == [Messages.flapping("Legion 34W-2c")])
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [DisplayID(raw: 7), virtualID])
        #expect(rig.coordinator.state.phase == .active(.remote))
    }

    @Test func monitorComingBackLessOftenIsStillKeptOff() async {
        let rig = await CoordinatorRig.inRemote()
        for _ in 1...5 {   // every 25 s: never four times within a minute
            rig.backend.turnOn(legionID)
            await rig.coordinator.handle(.displaysChanged)
            rig.clock.advance(by: .seconds(25))
        }
        #expect(rig.backend.calls.filter { $0 == "setEnabled([1],false)" }.count == 5)
        #expect(rig.notifier.notices.isEmpty)
    }

    @Test func monitorStillListedOnRightAfterItsDisableIsNotDisabledAgain() async {
        // B-6: CoreGraphics lists a disable up to 0.31 s late; this one takes 0.8 s to show.
        let rig = await CoordinatorRig.inRemote()
        rig.backend.disableLateness = .milliseconds(800)
        rig.backend.turnOn(legionID)
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.backend.calls.last == "setEnabled([1],false)")
        rig.clock.advance(by: .milliseconds(600))   // past the 500 ms rate limit, but the listing is late
        await rig.coordinator.handle(.tick)
        rig.clock.advance(by: .milliseconds(300))   // and now it shows
        await rig.coordinator.handle(.tick)
        #expect(rig.backend.calls.filter { $0 == "setEnabled([1],false)" }.count == 1)
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(rig.notifier.notices.isEmpty)
    }

    @Test func onlyAReturnThatWasDisabledCountsTowardFlapping() async {
        // B-6: three disables that do not go through are no three returns.
        let rig = await CoordinatorRig.inRemote()
        rig.backend.failing[.disable] = FakeError.injected
        rig.backend.turnOn(legionID)
        for _ in 1...3 {
            await rig.coordinator.handle(.displaysChanged)
            rig.clock.advance(by: .seconds(1))
        }
        #expect(rig.backend.calls.filter { $0 == "setEnabled([1],false)" }.count == 3)   // tried, and refused
        rig.backend.failing[.disable] = nil
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.backend.calls.filter { $0 == "setEnabled([1],false)" }.count == 4)   // not taken for flapping
        #expect(rig.notifier.notices.isEmpty)
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
    }

    @Test func targetNotMainIsMadeMainAgain() async {
        let rig = await CoordinatorRig.inRemote()
        // Another app's virtual display takes main: it sits at (0,0), and ours moved right of it.
        for i in rig.backend.displays.indices where rig.backend.displays[i].id == virtualID {
            rig.backend.displays[i].isMain = false; rig.backend.displays[i].origin = Point(x: 1920, y: 0)
        }
        var other = otherVirtual
        other.isMain = true; other.origin = Point(x: 0, y: 0)
        rig.backend.displays.append(other)
        await rig.coordinator.handle(.displaysChanged)
        // The layout moves as a whole, so that the target is at (0,0) again and the other display stays beside it.
        #expect(rig.backend.originRequests.last == [virtualID: Point(x: 0, y: 0), other.id: Point(x: -1920, y: 0)])
        #expect(rig.backend.displays.filter(\.isMain).map(\.id) == [virtualID])
        #expect(rig.backend.displays.first { $0.id == other.id }?.isActive == true)   // never disabled (D3)
        #expect(rig.events.all.contains(.init(name: "guard.target.main", fields: ["id": "50"])))
        #expect(rig.coordinator.state.phase == .active(.remote))
    }

    @Test func monitorThatCameBackAsMainGoesOnlyOnceTheTargetIsMainAgain() async throws {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.legionComesBackAsMain()
        await rig.coordinator.handle(.displaysChanged)
        // First the target becomes main again; the monitor stays on until a later pass (I2, one action per 500 ms).
        #expect(rig.backend.calls.last == "setOrigins")
        #expect(rig.backend.originRequests.last == [virtualID: Point(x: 0, y: 0), legionID: Point(x: -3440, y: 0)])
        #expect(!rig.backend.calls.contains("setEnabled([1],false)"))
        rig.clock.advance(by: .milliseconds(500))
        await rig.coordinator.handle(.tick)
        let disable = try #require(rig.backend.calls.lastIndex(of: "setEnabled([1],false)"))
        #expect(rig.backend.history[disable - 1].contains { $0.id == virtualID && $0.isActive && $0.isMain })
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(rig.backend.neverLeftZeroActive)

        // If the target cannot be made main, the monitor stays on.
        let stuck = await CoordinatorRig.inRemote()
        stuck.backend.legionComesBackAsMain()
        stuck.backend.failing[.setOrigins] = FakeError.injected
        for _ in 1...3 {
            await stuck.coordinator.handle(.tick)
            stuck.clock.advance(by: .seconds(1))
        }
        #expect(!stuck.backend.calls.contains("setEnabled([1],false)"))
        #expect(stuck.backend.displays.first { $0.id == legionID }?.isActive == true)
        #expect(stuck.events.all.contains(.init(name: "guard.failed", fields: ["step": "main", "error": "injected"])))
    }

    @Test func tickInNormalDoesNothing() async {
        let rig = CoordinatorRig()
        rig.lock.isLocked = true
        for event in [SystemEvent.tick, .displaysChanged, .screenUnlocked, .screenLocked] {
            await rig.coordinator.handle(event)
        }
        #expect(rig.backend.calls.isEmpty && rig.backend.listCount == 0)
        #expect(rig.store.saves.isEmpty && rig.notifier.notices.isEmpty && rig.events.all.isEmpty)
        #expect(rig.coordinator.state.phase == .normal)
    }

    // MARK: A failed return to Normal (R19)

    @Test func failedExitIsRetriedEveryTenSeconds() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on
        rig.confirmer.resolve(.timedOut)
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.exitRetryReason == .confirmTimeout)
        let events = rig.events
        func attempts() -> Int { wayBackAttempts(events) }
        #expect(attempts() == 1)

        // While the return is owed, it is all the guard does: another app's display that took main stays main.
        rig.backend.otherAppTakesMain()
        let owed = rig.backend.calls
        for second in 1...9 {
            rig.clock.advance(by: .seconds(1))
            await rig.coordinator.handle(second == 5 ? .displaysChanged : .tick)
        }
        #expect(rig.backend.calls == owed)   // no retry before 10 s, and no enforcement

        rig.clock.advance(by: .seconds(1))   // 10 s after the failure
        await rig.coordinator.handle(.tick)
        #expect(attempts() == 2)   // tried again, and failed again
        #expect(rig.coordinator.exitRetryReason == .confirmTimeout)
        rig.clock.advance(by: .seconds(9))
        await rig.coordinator.handle(.displaysChanged)
        #expect(attempts() == 2)   // the next try waits another 10 s

        rig.backend.failing[.enable] = nil
        rig.clock.advance(by: .seconds(1))
        await rig.coordinator.handle(.tick)
        #expect(attempts() == 3)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.coordinator.exitRetryReason == nil)
        #expect(rig.backend.displays.filter { $0.kind == .physical } == [Fixtures.legion, Fixtures.p24])
        // One notice for the failure, none for the retry that failed again, then the outcome.
        #expect(rig.notifier.notices == [Messages.exitFailed, Messages.revertedTimeout])

        // Back in Normal, nothing more is tried.
        let done = rig.backend.calls
        for _ in 1...3 {
            rig.clock.advance(by: .seconds(10))
            await rig.coordinator.handle(.tick)
        }
        #expect(rig.backend.calls == done)

        // A later failure is a new episode, and is told again.
        rig.backend.remove(otherVirtual.id)   // the other app's display is gone again
        _ = await rig.coordinator.enterRemote(confirmSeconds: 0)
        rig.backend.failing[.enable] = FakeError.injected
        #expect(await rig.coordinator.exitToNormal(.locked) == .failed(Messages.exitFailed))
        #expect(rig.notifier.notices == [Messages.exitFailed, Messages.revertedTimeout, Messages.exitFailed])
    }

    @Test func failedUserReturnStaysOwedAndGoesOnOnceAMonitorIsLit() async {
        // S9: the user's Normal fails, then another process turns a monitor back on.
        let rig = await CoordinatorRig.inRemote()
        rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on
        #expect(await rig.coordinator.exitToNormal(.user) == .failed(Messages.exitFailed))
        #expect(rig.coordinator.exitRetryReason == .user)   // owed, whatever its reason (A-1)
        let failedAt = rig.clock.elapsed, calls = rig.backend.calls.count
        rig.backend.failing[.enable] = nil
        rig.backend.turnOnElsewhere([legionID])
        rig.clock.advance(by: .seconds(1))
        await rig.coordinator.handle(.displaysChanged)
        // The guard never acts against the user's last request: the Legion is not disabled again...
        #expect(!rig.backend.calls[calls...].contains { $0.hasSuffix(",false)") })
        // ...and the owed return goes on at once, not 10 s after its failure.
        #expect(rig.events.all.contains(.init(name: "exit.retry", fields: ["reason": "user"])))
        #expect(rig.clock.elapsed - failedAt < .seconds(10))
        #expect(rig.coordinator.state.phase == .normal && rig.coordinator.exitRetryReason == nil)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.notifier.notices == [Messages.exitFailed, Messages.backToNormal])
    }

    @Test func failedHotkeyReturnIsOnlyRetriedEveryTenSeconds() async {
        let rig = await CoordinatorRig.inRemote()
        let times = EventTimes(rig)
        rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on
        #expect(await rig.coordinator.exitToNormal(.hotkey) == .failed(Messages.exitFailed))
        #expect(rig.coordinator.exitRetryReason == .hotkey)
        // What the guard acts on in a kept mode: another app's display takes main, and the Legion is online but dark.
        rig.backend.otherAppTakesMain()
        for i in rig.backend.displays.indices where rig.backend.displays[i].id == legionID {
            rig.backend.displays[i].isOnline = true
        }
        let calls = rig.backend.calls.count
        for _ in 1...35 {
            rig.clock.advance(by: .seconds(1))
            await rig.coordinator.handle(.tick)
        }
        // No enforcement while the return is owed: nothing disabled again, nothing made main.
        let later = rig.backend.calls[calls...]
        #expect(!later.contains { $0.hasSuffix(",false)") } && !later.contains("setOrigins"))
        // Tried again 10 s after each failure, each attempt waiting out its wake window: three times in 35 s of ticks.
        let retries = times["exit.retry"], failures = times["exit.failed"]
        #expect(retries.count == 3 && failures.count == 4)
        for (retry, failure) in zip(retries, failures) { #expect(retry - failure == .seconds(10)) }
        #expect(rig.events.all.filter { $0.name == "exit.retry" }.allSatisfy { $0.fields["reason"] == "hotkey" })
        #expect(rig.notifier.notices == [Messages.exitFailed])   // told once for the whole episode
        #expect(rig.coordinator.state.phase == .active(.remote))
    }

    @Test func newLockOrTargetLossWhileOwedGetsOneAttemptAtOnce() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on
        rig.confirmer.resolve(.timedOut)
        await rig.coordinator.pendingConfirmation?.value
        let events = rig.events
        func attempts() -> Int { wayBackAttempts(events) }
        #expect(attempts() == 1 && rig.coordinator.exitRetryReason == .confirmTimeout)

        // The Mac locks and the notification is missed: the next check tries at once, not 10 s after the failure.
        rig.clock.advance(by: .seconds(1))
        rig.lock.isLocked = true
        await rig.coordinator.handle(.tick)
        #expect(attempts() == 2)
        #expect(rig.coordinator.exitRetryReason == .locked)
        // That attempt saw the lock, so the next ones are spaced again.
        for _ in 1...9 {
            rig.clock.advance(by: .seconds(1))
            await rig.coordinator.handle(.tick)
        }
        #expect(attempts() == 2)
        rig.clock.advance(by: .seconds(1))
        await rig.coordinator.handle(.tick)
        #expect(attempts() == 3)   // 10 s after the last attempt

        // The virtual display goes: a loss the last attempt did not see gets one attempt at once as well.
        rig.clock.advance(by: .seconds(1))
        rig.backend.remove(virtualID)
        await rig.coordinator.handle(.displaysChanged)
        #expect(attempts() == 4)
        #expect(rig.coordinator.exitRetryReason == .targetLost)
        rig.clock.advance(by: .seconds(1))
        await rig.coordinator.handle(.displaysChanged)
        #expect(attempts() == 4)
        #expect(rig.notifier.notices == [Messages.exitFailed])   // one notice for the whole episode

        rig.backend.failing[.enable] = nil
        rig.clock.advance(by: .seconds(9))
        await rig.coordinator.handle(.tick)
        #expect(attempts() == 5)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.exitFailed, Messages.targetLost])
    }

    @Test func headlessRefusalStaysOwedUntilAMonitorComes() async {
        let rig = await CoordinatorRig.inRemote(displays: [])
        rig.lock.isLocked = true
        await rig.coordinator.handle(.screenLocked)
        #expect(rig.coordinator.state.phase == .active(.remote))   // the only display stays (I1)
        #expect(rig.coordinator.exitRetryReason == .locked)   // owed all the same (A-1)
        let calls = rig.backend.calls
        for _ in 1...30 {
            rig.clock.advance(by: .seconds(1))
            await rig.coordinator.handle(.tick)
        }
        // Tried again every 10 s and refused again, changing no display and telling nobody.
        #expect(rig.events.all.filter { $0.name == "exit.retry" }.count == 3)
        #expect(rig.events.all.filter { $0.name == "exit.refused" }.count == 4)
        #expect(rig.backend.calls == calls && rig.notifier.notices.isEmpty)
        #expect(rig.coordinator.state.phase == .active(.remote))

        // Once a monitor is plugged in, the locked Mac goes back to Normal, at once.
        var legion = Fixtures.legion
        legion.isMain = false; legion.origin = Point(x: 1180, y: 0)
        rig.backend.displays.insert(legion, at: 0)
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.revertedLocked])
        #expect(rig.backend.displays == [Fixtures.legion])
    }

    // MARK: Resolution (§7.9, R5)

    @Test func changeResolutionWhileActiveAppliesMode() async throws {
        let rig = await CoordinatorRig.inRemote()
        let r = try #require(Resolution(parsing: "1321x918"))
        #expect(await rig.coordinator.setResolution(r) == .ok(Messages.resolutionSet(r)))
        #expect(rig.backend.calls.last == "setMode(50)")
        #expect(rig.backend.displays.first { $0.id == virtualID }?.mode
                == DisplayMode(widthPoints: 1321, heightPoints: 918, widthPixels: 2642, heightPixels: 1836,
                               refreshHz: 60))
        #expect(rig.coordinator.config.remote.resolution == "1321x918")
        #expect(rig.coordinator.state.phase == .active(.remote))
    }

    @Test func resolutionInNormalIsUsedByTheNextEnter() async throws {
        let rig = CoordinatorRig()
        let r = try #require(Resolution(parsing: "1416x984"))
        #expect(await rig.coordinator.setResolution(r) == .ok(Messages.resolutionSet(r)))
        #expect(rig.backend.calls.isEmpty && rig.store.saves.isEmpty)
        #expect(rig.coordinator.config.remote.resolution == "1416x984")
        _ = await rig.coordinator.enterRemote()
        #expect(rig.host.resolutions == [r])
    }

    @Test func resolutionRefusedDuringATransitionAndKeptWhenItFails() async throws {
        let rig = CoordinatorRig(confirm: nil)
        let r = try #require(Resolution(parsing: "1321x918"))
        _ = await rig.coordinator.enterRemote()   // the confirmation is showing
        #expect(await rig.coordinator.setResolution(r) == .refused(.busy, Messages.busy))
        #expect(!rig.backend.calls.contains { $0.hasPrefix("setMode") })
        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value

        rig.backend.failing[.setMode] = FakeError.injected   // macOS rejects the mode
        #expect(await rig.coordinator.setResolution(r) == .failed(Messages.resolutionFailed(r)))
        #expect(rig.events.all.contains(
            .init(name: "resolution.failed", fields: ["resolution": "1321x918", "error": "injected"])))
        #expect(rig.coordinator.config.remote.resolution == "1180x820")   // nothing changed
        #expect(rig.backend.displays.first { $0.id == virtualID }?.mode == Fixtures.virtualRemote.mode)
    }

    // MARK: Startup (§7.8 L5)

    @Test func startupReconcileFromActiveState() async throws {
        // The last run crashed in Remote with the monitors off; stopStale() has ended its vdisplay process.
        let rig = CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote())
        var savedAtEnable: PersistedState?
        rig.backend.onCall = { [store = rig.store] call in
            if call == "setEnabled([1, 3],true)" { savedAtEnable = store.saves.last }
        }
        await rig.coordinator.reconcileAtStartup()
        #expect(rig.backend.calls == ["setEnabled([1, 3],true)", "setOrigins"])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])   // on, with origins and main as before
        #expect(rig.notifier.notices == [Messages.recovered])
        // Write-ahead: the start was counted and the way back saved before the monitors were touched.
        let saved = try #require(savedAtEnable)
        #expect(saved.phase == .exiting && !saved.cleanShutdown && saved.uncleanStarts.count == 1)
        #expect(!rig.store.saves.contains { $0.phase == .active(.remote) })   // after a restart, status never shows Remote
        let state = rig.coordinator.state
        #expect(state.phase == .normal && state.baseline == nil && state.target == nil && state.virtualPID == nil)
        #expect(state.lastError == nil && !state.cleanShutdown)
        #expect(rig.store.saves.last == state)
        #expect(!rig.coordinator.isSafeMode)
    }

    @Test func startupReconcileCleanStateNoCalls() async {
        let rig = CoordinatorRig(persisted: .initial)   // stopped cleanly, in Normal
        await rig.coordinator.reconcileAtStartup()
        #expect(rig.backend.calls.isEmpty)
        #expect(rig.notifier.notices.isEmpty)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.coordinator.state.uncleanStarts.isEmpty)
        #expect(rig.store.saves.map(\.cleanShutdown) == [false])   // running now: a crash from here on counts
        #expect(!rig.coordinator.isSafeMode)
    }

    @Test func startupReconcileWithCorruptState() async {
        // state.json cannot be read, and the monitors are off.
        let rig = CoordinatorRig(displays: [disconnected(Fixtures.legion), disconnected(Fixtures.p24)],
                                 persisted: nil)
        await rig.coordinator.reconcileAtStartup()
        #expect(rig.backend.calls == ["setEnabled([1, 3],true)"])   // all of them; no baseline to lay out
        #expect(rig.backend.displays.allSatisfy { $0.isOnline && $0.isActive })
        var expected = PersistedState.initial   // as after a first start, but running
        expected.cleanShutdown = false
        expected.updatedAt = rig.coordinator.state.updatedAt
        #expect(rig.coordinator.state == expected)
        #expect(rig.notifier.notices == [Messages.recovered])
    }

    @Test func startupReconcileCleansUpAfterAStaleVirtualDisplay() async {
        // A crash between a cut-off enter and its cleanup: Normal on disk, but a vdisplay process recorded.
        var leftover = PersistedState.initial
        leftover.target = virtualID; leftover.virtualPID = 4242; leftover.cleanShutdown = false
        let rig = CoordinatorRig(persisted: leftover)
        await rig.coordinator.reconcileAtStartup()
        #expect(rig.events.all.contains(.init(name: "reconcile.stale.virtual", fields: ["pid": "4242"])))
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.coordinator.state.virtualPID == nil && rig.coordinator.state.target == nil)
        #expect(rig.store.saves.last?.virtualPID == nil)
        #expect(rig.backend.calls.isEmpty)   // the monitors are on; the host's stopStale() ends the process
        #expect(rig.notifier.notices == [Messages.recovered])
    }

    @Test func failedStartupRestoreIsRetried() async {
        let rig = CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote())
        rig.backend.failing[.enable] = FakeError.injected
        await rig.coordinator.reconcileAtStartup()
        // No mode exists after a restart: the owed return is `.exiting`, never Remote (I5), and told as such.
        #expect(rig.coordinator.state.phase == .exiting)
        #expect(rig.coordinator.exitRetryReason == .startup)   // nobody waits on it: the periodic check retries
        #expect(rig.notifier.notices == [Messages.startupRestoreFailed])
        // A Normal clicked meanwhile fails the same way, and still records no mode.
        #expect(await rig.coordinator.exitToNormal(.user) == .failed(Messages.startupRestoreFailed))
        #expect(rig.coordinator.state.phase == .exiting)
        rig.backend.failing[.enable] = nil
        rig.clock.advance(by: .seconds(10))
        await rig.coordinator.handle(.tick)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(!rig.store.saves.contains { $0.phase == .active(.remote) })   // status never showed Remote
        #expect(rig.notifier.notices == [Messages.startupRestoreFailed, Messages.startupRestoreFailed,
                                         Messages.recovered])
    }

    @Test func startupRestoreWithMonitorsThatNeverComeOnStaysOwed() async {
        let rig = CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote())
        rig.backend.enableDelay = 1000   // the monitors do not wake within the 10 s wait
        await rig.coordinator.reconcileAtStartup()
        // Nothing is on: not Normal, and no mode either (I5). Owed, and told as a restart's failure.
        #expect(rig.coordinator.state.phase == .exiting)
        #expect(rig.coordinator.exitRetryReason == .startup)
        #expect(rig.coordinator.state.lastError == "monitorsNotActive")
        #expect(rig.notifier.notices == [Messages.startupRestoreFailed])
        #expect(!rig.store.saves.contains { $0.phase == .active(.remote) || $0.phase == .normal })
    }

    @Test func startupWithoutADisplayListIsRetried() async {
        // The display list cannot be read at start, so a disabled monitor cannot be ruled out: retried, not skipped.
        let rig = CoordinatorRig(displays: [disconnected(Fixtures.legion), Fixtures.p24], persisted: .initial)
        rig.backend.failing[.listDisplays] = FakeError.injected
        await rig.coordinator.reconcileAtStartup()
        #expect(rig.coordinator.state.phase == .exiting)
        #expect(rig.coordinator.exitRetryReason == .startup)
        #expect(rig.notifier.notices == [Messages.startupRestoreFailed])
        rig.backend.failing[.listDisplays] = nil
        rig.clock.advance(by: .seconds(10))
        await rig.coordinator.handle(.tick)
        #expect(rig.backend.calls == ["setEnabled([1],true)"])
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.startupRestoreFailed, Messages.recovered])
    }

    @Test func futureDatedUncleanStartsAreDropped() async {
        // The wall clock stepped back: entries "from the future" must not hold safe mode beyond 10 minutes.
        let now = Date()
        var stepped = PersistedState.initial
        stepped.cleanShutdown = false
        stepped.uncleanStarts = [now.addingTimeInterval(3600), now.addingTimeInterval(7200)]
        let rig = CoordinatorRig(persisted: stepped)
        await rig.coordinator.reconcileAtStartup()
        #expect(rig.coordinator.state.uncleanStarts.count == 1)   // this start only
        #expect(!rig.coordinator.isSafeMode)
    }

    @Test func startIsCountedBeforeTheDisplaysAreListed() async throws {
        let rig = CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote())
        var atFirstList: PersistedState?, listed = false
        rig.backend.onList = { [store = rig.store] in
            guard !listed else { return }
            listed = true
            atFirstList = store.saves.last
        }
        await rig.coordinator.reconcileAtStartup()
        // The listing is the first private-API call at start: a crash in it must already count (R34).
        let saved = try #require(atFirstList)
        #expect(saved.uncleanStarts.count == 1 && !saved.cleanShutdown)
        #expect(saved.phase == .exiting)   // the state already owed the way back: saved without the mode (I5)
        #expect(!rig.store.saves.contains { $0.phase == .active(.remote) })
    }

    @Test func crashInTheFirstDisplayListStillLeadsToSafeMode() async {
        /// A start whose first display listing traps, as after a macOS update broke the API: it throws, and from
        /// then on nothing reaches the disk, as when the process dies inside the call.
        func startWithATrappingList(after persisted: PersistedState?) async -> CoordinatorRig {
            let rig = CoordinatorRig(persisted: persisted)
            rig.backend.failing[.listDisplays] = FakeError.injected
            rig.backend.onList = { [store = rig.store] in store.saveFailure = { _ in FakeError.injected } }
            await rig.coordinator.reconcileAtStartup()
            return rig
        }
        var crashed = PersistedState.initial
        crashed.cleanShutdown = false   // the run before this loop crashed as well
        let first = await startWithATrappingList(after: crashed)
        let second = await startWithATrappingList(after: first.store.load())
        let third = await startWithATrappingList(after: second.store.load())
        #expect(!first.coordinator.isSafeMode && !second.coordinator.isSafeMode)
        #expect(third.coordinator.isSafeMode)
        #expect(third.store.load()?.uncleanStarts.count == 3)
        #expect(third.notifier.notices.first == Messages.safeMode)   // and `ipadmode doctor` is suggested
    }

    @Test func crashLoopEntersSafeMode() async {
        let now = Date()
        var crashing = crashedInRemote()
        crashing.uncleanStarts = [now.addingTimeInterval(-11 * 60), now.addingTimeInterval(-9 * 60),
                                  now.addingTimeInterval(-60)]
        let rig = CoordinatorRig(displays: monitorsLeftOff, persisted: crashing)
        await rig.coordinator.reconcileAtStartup()
        // This start is the third unclean one within 10 minutes; the one 11 minutes ago no longer counts.
        #expect(rig.coordinator.state.uncleanStarts.count == 3)
        #expect(rig.store.saves.last?.uncleanStarts.count == 3)
        #expect(rig.coordinator.isSafeMode)
        // The way back still works, and the user is told to run `ipadmode doctor`.
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.notifier.notices == [Messages.safeMode, Messages.recovered])
        let calls = rig.backend.calls
        #expect(await rig.coordinator.enterRemote() == .refused(.safeMode, Messages.safeMode))
        #expect(rig.backend.calls == calls && rig.host.resolutions.isEmpty)
        #expect(rig.events.all.contains(.init(name: "enter.remote.refused", fields: ["reason": "safeMode"])))

        // Two unclean starts within 10 minutes are no loop yet, and a clean shutdown is no crash.
        var twice = PersistedState.initial
        twice.cleanShutdown = false
        twice.uncleanStarts = [now.addingTimeInterval(-9 * 60)]
        let second = CoordinatorRig(persisted: twice)
        await second.coordinator.reconcileAtStartup()
        #expect(second.coordinator.state.uncleanStarts.count == 2 && !second.coordinator.isSafeMode)
        var stopped = PersistedState.initial
        stopped.uncleanStarts = [now.addingTimeInterval(-9 * 60), now.addingTimeInterval(-60)]
        let clean = CoordinatorRig(persisted: stopped)
        await clean.coordinator.reconcileAtStartup()
        #expect(clean.coordinator.state.uncleanStarts.count == 2 && !clean.coordinator.isSafeMode)
        #expect(await clean.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))
    }

    @Test func cleanShutdownIsNotCountedAtTheNextStart() async throws {
        let first = CoordinatorRig()
        await first.coordinator.reconcileAtStartup()
        try first.coordinator.markCleanShutdown()
        #expect(first.store.saves.last?.cleanShutdown == true)
        let next = CoordinatorRig(persisted: first.store.load())
        await next.coordinator.reconcileAtStartup()
        #expect(next.coordinator.state.uncleanStarts.isEmpty)
        // That run ends without marking a clean shutdown, as a crash does: the start after it counts.
        let afterCrash = CoordinatorRig(persisted: next.store.load())
        await afterCrash.coordinator.reconcileAtStartup()
        #expect(afterCrash.coordinator.state.uncleanStarts.count == 1)
        // A save that fails is reported to the daemon.
        afterCrash.store.saveFailure = { _ in FakeError.injected }
        #expect(throws: FakeError.injected) { try afterCrash.coordinator.markCleanShutdown() }
    }
}
