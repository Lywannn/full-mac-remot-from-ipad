import Testing
@testable import IPadModeCore

private let virtualID = Fixtures.virtualRemote.id
private let legionID = Fixtures.legion.id
private let p24ID = Fixtures.p24.id

@MainActor
struct CoordinatorRemoteTests {
    @Test func enterRemoteHappyPath() async {
        let rig = CoordinatorRig()
        let result = await rig.coordinator.enterRemote()
        await rig.coordinator.pendingConfirmation?.value
        #expect(result == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(rig.host.resolutions == [.defaultRemote])
    }

    @Test func callOrderIsStartMainDisable() async {
        let rig = await CoordinatorRig.inRemote()
        #expect(rig.backend.calls == ["start(remote)", "setOrigins", "setEnabled([1, 3],false)"])
        // The virtual display shows up beside the layout (Legion ends at 3440)...
        #expect(rig.backend.history.first?.first { $0.id == virtualID }?.origin == Point(x: 3440, y: 0))
        // ...then goes to (0,0), with Legion (3440 wide) and P24 to its right, in baseline order.
        #expect(rig.backend.originRequests == [[virtualID: Point(x: 0, y: 0), legionID: Point(x: 1180, y: 0),
                                                p24ID: Point(x: 4620, y: 0)]])
    }

    @Test func neverZeroActiveDisplays() async {
        let rig = await CoordinatorRig.inRemote()
        _ = await rig.coordinator.exitToNormal(.user)
        #expect(rig.backend.calls.last == "stop(remote)")
        for (call, displays) in zip(rig.backend.calls, rig.backend.history) {
            let active = displays.filter(\.isActive).count
            #expect(active > 0, "no active display after \(call)")
        }
    }

    @Test func physicalDisabledOnlyAfterTargetMainAndActive() async throws {
        let rig = await CoordinatorRig.inRemote()
        let disable = try #require(rig.backend.calls.firstIndex(of: "setEnabled([1, 3],false)"))
        try #require(disable > 0)
        let target = try #require(rig.backend.history[disable - 1].first { $0.id == virtualID })
        #expect(target.isActive && target.isMain)

        // macOS keeps the Legion as main display: the mode stops once transaction A's 2 s wait (R56) runs out, before
        // any settle delay, and the monitors stay on.
        let stubborn = CoordinatorRig()
        stubborn.backend.onCall = { [backend = stubborn.backend] call in
            guard call == "setOrigins" else { return }
            for i in backend.displays.indices { backend.displays[i].isMain = backend.displays[i].id == legionID }
        }
        let result = await stubborn.coordinator.enterRemote()
        #expect(result == .failed(Messages.enterFailed))
        #expect(!stubborn.events.names.contains("target.main") && stubborn.clock.elapsed == .seconds(2))
        #expect(!stubborn.backend.calls.contains { $0.hasPrefix("setEnabled") })
        #expect(stubborn.backend.displays.filter(\.isActive).map(\.id) == [legionID, p24ID])
        #expect(stubborn.coordinator.state.phase == .normal)

        // The virtual display loses main during the settle delay: checked again right before disabling.
        let unsettled = CoordinatorRig()
        unsettled.backend.onList = { [backend = unsettled.backend, clock = unsettled.clock] in
            guard clock.elapsed >= .seconds(1) else { return }
            for i in backend.displays.indices { backend.displays[i].isMain = backend.displays[i].id == legionID }
        }
        #expect(await unsettled.coordinator.enterRemote() == .failed(Messages.enterFailed))
        #expect(unsettled.events.names.contains("target.main"))
        #expect(!unsettled.backend.calls.contains { $0.hasPrefix("setEnabled") })
        #expect(unsettled.backend.displays.filter(\.isActive).map(\.id) == [legionID, p24ID])
        #expect(unsettled.coordinator.state.phase == .normal)
    }

    @Test func monitorStillActiveAfterDisablingEndsTheMode() async {
        let rig = CoordinatorRig()
        // macOS turns the P24 straight back on.
        rig.backend.onCall = { [backend = rig.backend] call in
            guard call == "setEnabled([1, 3],false)" else { return }
            for i in backend.displays.indices where backend.displays[i].id == p24ID {
                backend.displays[i].isOnline = true; backend.displays[i].isActive = true
            }
        }
        let result = await rig.coordinator.enterRemote()
        #expect(result == .failed(Messages.enterFailed))
        #expect(rig.notifier.notices == [Messages.enterFailed])
        #expect(rig.coordinator.state.lastError == "physicalStillActive")
        #expect(rig.confirmer.requests.isEmpty)
        #expect(rig.backend.calls.last == "stop(remote)")
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [legionID, p24ID])
        #expect(rig.coordinator.state.phase == .normal)
    }

    @Test func lateKeepAfterExitStaysNormal() async {
        let rig = CoordinatorRig(confirm: nil)
        rig.confirmer.cancelAnswers = false   // the dialog was answered just as Normal closed it
        _ = await rig.coordinator.enterRemote()
        _ = await rig.coordinator.exitToNormal(.user)
        #expect(rig.confirmer.cancels == 1)
        rig.confirmer.resolve(.keep)   // the dialog is answered after Normal already took over
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.store.saves.last?.phase == .normal)
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [legionID, p24ID])
    }

    @Test func exitEnablesPhysicalBeforeStoppingVirtual() async throws {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.enableDelay = 3   // the monitors need two more polls to wake up
        let before = rig.clock.elapsed
        let result = await rig.coordinator.exitToNormal(.user)
        #expect(result == .ok(Messages.backToNormal))
        let enable = try #require(rig.backend.calls.firstIndex(of: "setEnabled([1, 3],true)"))
        let stop = try #require(rig.backend.calls.firstIndex(of: "stop(remote)"))
        try #require(enable < stop)
        // macOS brought both monitors back at their own modes, so only the layout is set.
        #expect(Array(rig.backend.calls[(enable + 1)..<stop]) == ["setOrigins"])
        // The virtual display went away only after the monitors were awake, polled every 100 ms.
        #expect(rig.backend.history[stop - 1].filter { $0.kind == .physical }.allSatisfy { $0.isOnline && $0.isActive })
        #expect(rig.clock.elapsed - before == .milliseconds(200))
        // Origins, modes and the main display are as before.
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.backToNormal])
    }

    @Test func writeAheadBeforeEachAction() async throws {
        let rig = CoordinatorRig(confirm: nil)
        var savedAt: [String: PersistedState] = [:]
        rig.backend.onCall = { [store = rig.store] call in savedAt[call] = store.saves.last }
        _ = await rig.coordinator.enterRemote()

        let atStart = try #require(savedAt["start(remote)"])
        #expect(atStart.phase == .entering(.remote))
        #expect(atStart.baseline?.displays == [Fixtures.legion, Fixtures.p24])
        #expect(atStart.target == nil && atStart.virtualPID == nil)
        let afterStart = try #require(savedAt["setOrigins"])
        #expect(afterStart.target == virtualID && afterStart.virtualPID == 4242)
        #expect(savedAt["setEnabled([1, 3],false)"]?.phase == .entering(.remote))
        #expect(rig.confirmer.isHolding)
        #expect(rig.store.saves.last?.phase == .confirming(.remote))

        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.store.saves.last?.phase == .active(.remote))

        _ = await rig.coordinator.exitToNormal(.user)
        #expect(savedAt["setEnabled([1, 3],true)"]?.phase == .exiting)
        #expect(savedAt["stop(remote)"]?.phase == .exiting)
        let last = try #require(rig.store.saves.last)
        #expect(last.phase == .normal)
        #expect(last.baseline == nil && last.target == nil && last.virtualPID == nil)
        #expect(rig.coordinator.state == last)
    }

    @Test func recordsTransitionSteps() async {
        let rig = await CoordinatorRig.inRemote()
        #expect(Array(rig.events.names.prefix(5))
                == ["enter.remote.begin", "virtual.ready", "target.main", "physical.disabled", "confirm.keep"])
        #expect(rig.events.all.first { $0.name == "virtual.ready" }?.fields == ["id": "50"])
        #expect(rig.events.all.first { $0.name == "target.main" }?.fields == ["id": "50"])
        #expect(rig.events.all.first { $0.name == "physical.disabled" }?.fields == ["ids": "1,3"])
        _ = await rig.coordinator.exitToNormal(.user)
        #expect(Array(rig.events.names.dropFirst(5)) == ["exit.user.begin", "physical.enabled", "virtual.stopped"])
        #expect(rig.events.all.first { $0.name == "virtual.stopped" }?.fields == ["id": "50"])
    }

    @Test func enterRemoteWithNoPhysicalMonitors() async {
        let rig = CoordinatorRig(displays: [])
        let result = await rig.coordinator.enterRemote()
        await rig.coordinator.pendingConfirmation?.value
        #expect(result == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(!rig.backend.calls.contains { $0.hasPrefix("setEnabled") })
        #expect(rig.backend.displays.map(\.id) == [virtualID])
        #expect(rig.backend.displays.first?.isMain == true)
        #expect(rig.coordinator.state.phase == .active(.remote))
    }

    @Test func exitAfterDisplayIDsChanged() async {
        let rig = await CoordinatorRig.inRemote()
        // macOS renumbers the monitors while the mode is on (replug, wake from sleep).
        for i in rig.backend.displays.indices {
            if rig.backend.displays[i].id == legionID { rig.backend.displays[i].id = DisplayID(raw: 7) }
            if rig.backend.displays[i].id == p24ID { rig.backend.displays[i].id = DisplayID(raw: 9) }
        }
        let result = await rig.coordinator.exitToNormal(.user)
        #expect(result == .ok(Messages.backToNormal))
        #expect(rig.backend.calls.contains("setEnabled([7, 9],true)"))
        let legion = rig.backend.displays.first { $0.id == DisplayID(raw: 7) }
        #expect(legion?.isActive == true && legion?.isMain == true && legion?.origin == Point(x: 0, y: 0))
        #expect(rig.backend.displays.first { $0.id == DisplayID(raw: 9) }?.origin == Point(x: -1920, y: -326))
        #expect(!rig.backend.displays.contains { $0.id == virtualID })
    }

    @Test func exitWithMonitorUnpluggedSucceeds() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.displays.removeAll { $0.id == p24ID }
        let result = await rig.coordinator.exitToNormal(.user)
        #expect(result == .ok(Messages.backToNormal))
        #expect(rig.backend.calls.contains("setEnabled([1],true)"))
        #expect(rig.backend.displays == [Fixtures.legion])
        #expect(rig.events.all.contains(.init(name: "restore.unmatched", fields: ["name": "P24FBA-RAGL"])))
        #expect(rig.coordinator.state.phase == .normal)
    }

    @Test func exitIsIdempotent() async {
        let rig = await CoordinatorRig.inRemote()
        _ = await rig.coordinator.exitToNormal(.user)
        let calls = rig.backend.calls, lists = rig.backend.listCount
        let saves = rig.store.saves.count, notices = rig.notifier.notices
        let again = await rig.coordinator.exitToNormal(.user)
        #expect(again == .ok(Messages.backToNormal))
        // An explicit Normal while Normal looks at the monitors once more (A-5); every one is on: nothing else.
        #expect(rig.backend.calls == calls && rig.backend.listCount == lists + 1)
        #expect(rig.store.saves.count == saves && rig.notifier.notices == notices)
    }

    // MARK: rulings and timings

    @Test func enterReturnsWhileTheConfirmationIsShowing() async {
        let rig = CoordinatorRig(confirm: nil)
        let result = await rig.coordinator.enterRemote()
        #expect(result == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(rig.coordinator.state.phase == .confirming(.remote))
        #expect(rig.confirmer.isHolding && rig.confirmer.requests == [20])
        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .active(.remote))

        let custom = CoordinatorRig(confirm: nil)
        #expect(await custom.coordinator.enterRemote(confirmSeconds: 120) == .ok(Messages.remoteEntered(seconds: 120)))
        #expect(custom.confirmer.requests == [120])
        custom.confirmer.resolve(.keep)
        await custom.coordinator.pendingConfirmation?.value
    }

    @Test func zeroConfirmSecondsSkipsTheConfirmation() async {
        let rig = CoordinatorRig(confirm: nil)
        let result = await rig.coordinator.enterRemote(confirmSeconds: 0)
        #expect(result == .ok(Messages.remoteEntered(seconds: 0)))
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.store.saves.last?.phase == .active(.remote))
        #expect(rig.confirmer.requests.isEmpty && rig.coordinator.pendingConfirmation == nil)
    }

    @Test func settlesOneSecondBeforeDisablingMonitors() async throws {
        let rig = CoordinatorRig()
        var at: [String: Duration] = [:]
        rig.backend.onCall = { [clock = rig.clock] call in at[call] = clock.elapsed }
        _ = await rig.coordinator.enterRemote()
        let main = try #require(at["setOrigins"]), disable = try #require(at["setEnabled([1, 3],false)"])
        #expect(disable - main == .seconds(1))
    }

    @Test func virtualDisplayThatNeverAppearsFailsAfterFiveSeconds() async {
        let rig = CoordinatorRig()
        rig.host.appears = false
        let result = await rig.coordinator.enterRemote()
        #expect(result == .failed(Messages.virtualFailed))
        #expect(rig.clock.elapsed == .seconds(5))
        #expect(!rig.backend.calls.contains { $0.hasPrefix("setEnabled") })
        #expect(rig.backend.calls.last == "stop(remote)")
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(!rig.events.names.contains("restore.failed"))   // the layout left out the display that never came
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.virtualFailed])
    }

    @Test func exitKeepsVirtualWhenMonitorsCannotBeTurnedOn() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.failing[.enable] = FakeError.injected
        let result = await rig.coordinator.exitToNormal(.user)
        #expect(result == .failed(Messages.exitFailed))
        #expect(rig.notifier.notices == [Messages.exitFailed])
        #expect(!rig.backend.calls.contains("stop(remote)"))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(rig.coordinator.state.phase == .active(.remote))
        // The listing decides (A-2): the failed enables are logged, and the way back fails for want of a lit monitor.
        #expect(rig.coordinator.state.lastError == "monitorsNotActive")
        #expect(rig.events.all.contains(.init(name: "physical.enable.failed", fields: ["ids": "1,3", "error": "injected"])))
        // Owed (A-1): the guard tries it again, and never enforces the mode against the user's request.
        #expect(rig.coordinator.exitRetryReason == .user)
        #expect(rig.events.all.last
                == .init(name: "exit.failed", fields: ["reason": "user", "error": "monitorsNotActive"]))

        rig.backend.failing[.enable] = nil
        let retry = await rig.coordinator.exitToNormal(.user)
        #expect(retry == .ok(Messages.backToNormal))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func failedAutomaticExitIsLeftForARetry() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.backend.failing[.enable] = FakeError.injected
        rig.confirmer.resolve(.timedOut)   // nobody answered the dialog, and the monitors will not turn on
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.coordinator.exitRetryReason == .confirmTimeout)
        #expect(rig.notifier.notices == [Messages.exitFailed])
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])

        rig.backend.failing[.enable] = nil
        let retry = await rig.coordinator.exitToNormal(.confirmTimeout)   // as the periodic check will
        #expect(retry == .ok(Messages.revertedTimeout))
        #expect(rig.coordinator.exitRetryReason == nil)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func exitNeverStopsTheOnlyActiveDisplay() async {
        let rig = await CoordinatorRig.inRemote(displays: [])
        let result = await rig.coordinator.exitToNormal(.locked)
        #expect(result == .refused(.noPhysicalMonitor, Messages.noPhysicalMonitor))
        #expect(!rig.backend.calls.contains("stop(remote)"))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.coordinator.exitRetryReason == .locked)   // owed (A-1): tried again once a monitor comes
        #expect(!rig.notifier.notices.contains(Messages.exitFailed))
    }

    @Test func exitMovesTheVirtualDisplayOffTheMainPosition() async throws {
        let rig = await CoordinatorRig.inRemote()
        _ = await rig.coordinator.exitToNormal(.user)
        // One call: the baseline origins, and the virtual display right of the restored layout (Legion ends at 3440).
        #expect(rig.backend.originRequests.last == [legionID: Point(x: 0, y: 0), p24ID: Point(x: -1920, y: -326),
                                                    virtualID: Point(x: 3440, y: 0)])
        let restore = try #require(rig.backend.calls.lastIndex(of: "setOrigins"))
        let layout = rig.backend.history[restore]
        #expect(layout.first { $0.id == virtualID }?.origin == Point(x: 3440, y: 0))
        #expect(layout.filter(\.isMain).map(\.id) == [legionID])
        #expect(!rig.events.names.contains("restore.main.mismatch"))

        // macOS keeps the virtual display as main anyway: logged, and Normal still comes back.
        let stubborn = await CoordinatorRig.inRemote()
        stubborn.backend.onCall = { [backend = stubborn.backend] call in
            guard call == "setOrigins" else { return }
            for i in backend.displays.indices { backend.displays[i].isMain = backend.displays[i].id == virtualID }
        }
        #expect(await stubborn.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(stubborn.events.all.contains(.init(name: "restore.main.mismatch", fields: ["id": "1"])))
    }

    @Test func mainListedLateOnTheWayBackIsNoMismatch() async {
        // B-8: CoreGraphics lists the restored layout a little late (R56); the check waits for it, up to 2 s.
        let rig = await CoordinatorRig.inRemote()
        rig.backend.originsDelay = 3
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(!rig.events.names.contains("restore.main.mismatch"))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func concurrentExitsRestoreOnce() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.enableDelay = 3   // the first exit is still waiting for the monitors when the second comes
        let coordinator = rig.coordinator
        async let first = coordinator.exitToNormal(.user)
        async let second = coordinator.exitToNormal(.hotkey)
        let results = await [first, second]
        #expect(results == [.ok(Messages.backToNormal), .ok(Messages.backToNormal)])
        #expect(rig.backend.calls.filter { $0 == "setEnabled([1, 3],true)" }.count == 1)
        #expect(rig.backend.calls.filter { $0 == "stop(remote)" }.count == 1)
        #expect(rig.notifier.notices == [Messages.backToNormal])
    }

    @Test func callersJoiningAFailedExitGetItsMessage() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.enableDelay = 1000   // the monitors do not wake up within 10 s
        let coordinator = rig.coordinator
        async let first = coordinator.exitToNormal(.user)
        async let second = coordinator.exitToNormal(.hotkey)
        let results = await [first, second]
        #expect(results == [.failed(Messages.exitFailed), .failed(Messages.exitFailed)])
        // One way back, which the other caller joined, whichever came first (it asks for the monitors again every
        // second, A-2, so its enable calls do not count ways back).
        #expect(rig.events.names.filter { $0.hasPrefix("exit.") && $0.hasSuffix(".begin") }.count == 1)
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.coordinator.state.lastError == "monitorsNotActive")
        #expect(rig.notifier.notices == [Messages.exitFailed])
    }

    @Test func exitDuringSettleNeverLeavesZeroActiveDisplays() async {
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator, backend = rig.backend, host = rig.host
        host.stopGate.close()   // like the real host, `stop` returns only once the display is gone
        rig.clock.duringNextSleep {   // the settle delay: the monitors are still on
            backend.failing[.setOrigins] = FakeError.injected   // and the exit cannot restore the layout
            Task { _ = await coordinator.exitToNormal(.user) }
            await host.stopGate.untilHolding()   // the exit is stopping the virtual display, which is still there
        }
        // The enter resumes while that stop is held, gives up and waits for the exit; only then may the stop end.
        rig.events.onRecord { event in
            guard event.name == "enter.remote.preempted" else { return }
            MainActor.assumeIsolated { host.stopGate.open() }
        }
        let entered = await coordinator.enterRemote()
        let exited = await coordinator.exitToNormal(.hotkey)   // Normal by now

        #expect(entered == .failed(Messages.enterFailed))
        #expect(exited == .ok(Messages.backToNormal))
        #expect(rig.events.names.contains("target.main") && rig.clock.elapsed == .seconds(1))   // it was the settle
        #expect(!backend.calls.contains { $0.hasSuffix(",false)") })
        for (call, displays) in zip(backend.calls, backend.history) {
            let active = displays.filter(\.isActive).count
            #expect(active > 0, "no active display after \(call)")
        }
        #expect(backend.displays.filter(\.isActive).map(\.id) == [legionID, p24ID])
        #expect(coordinator.state.phase == .normal)
        #expect(rig.confirmer.requests.isEmpty)
    }

    @Test func exitWhileWaitingForTheVirtualDisplayEndsTheEnterAtOnce() async {
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator
        rig.host.appears = false   // the virtual display has not shown up yet...
        rig.clock.duringNextSleep { _ = await coordinator.exitToNormal(.user) }   // ...when Normal is clicked
        let entered = await coordinator.enterRemote()
        #expect(entered == .failed(Messages.enterFailed))
        #expect(rig.clock.elapsed == .milliseconds(100))   // not the 5 s a slow display would get
        #expect(rig.backend.originRequests.allSatisfy { $0[virtualID] != Point(x: 0, y: 0) })   // never made main
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(!rig.events.names.contains("restore.failed"))   // the layout left out the display that never came
        #expect(coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.backToNormal])
    }

    @Test func usesConfiguredResolutionAndItsWidthForTheLayout() async throws {
        var config = Config.default
        config.remote.resolution = "1321x918"
        let rig = CoordinatorRig(config: config)
        _ = await rig.coordinator.enterRemote()
        #expect(rig.host.resolutions == [try #require(Resolution(parsing: "1321x918"))])
        #expect(rig.backend.originRequests.first == [virtualID: Point(x: 0, y: 0), legionID: Point(x: 1321, y: 0),
                                                     p24ID: Point(x: 4761, y: 0)])
    }

    // MARK: The configured resolution (A-3)

    /// The mode macOS remembers for this display identity from System Settings (SP3, acceptance A1).
    private static let remembered = DisplayMode(widthPoints: 1321, heightPoints: 918, widthPixels: 2642,
                                                heightPixels: 1836, refreshHz: 60)

    /// macOS switches the virtual display to `mode` after each call `matching` (transaction A, unless told otherwise).
    private func switchesTheVirtualDisplay(_ backend: FakeDisplayBackend, to mode: DisplayMode,
                                           after matching: @escaping (String) -> Bool = { $0 == "setOrigins" }) {
        backend.onCall = { [backend] call in
            guard matching(call) else { return }
            for i in backend.displays.indices where backend.displays[i].id == virtualID { backend.displays[i].mode = mode }
        }
    }

    @Test func rememberedModeIsReplacedByTheConfiguredOneBeforeTheMonitorsGo() async throws {
        let rig = CoordinatorRig()
        switchesTheVirtualDisplay(rig.backend, to: Self.remembered)
        #expect(await rig.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.backend.calls == ["start(remote)", "setOrigins", "setMode(50)", "setEnabled([1, 3],false)"])
        #expect(rig.backend.scopes == [.appOnly, .session, .appOnly])   // session scope, whatever the others use
        // Applied while the monitors were still on (I1), and still the mode once they are off.
        let disable = try #require(rig.backend.calls.firstIndex(of: "setEnabled([1, 3],false)"))
        #expect(rig.backend.history[disable - 1].first { $0.id == virtualID }?.mode == Fixtures.virtualRemote.mode)
        #expect(rig.backend.displays.first { $0.id == virtualID }?.mode == Fixtures.virtualRemote.mode)
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(!rig.events.names.contains("resolution.enforce.failed"))
    }

    @Test func resolutionThatCannotBeSetAgainIsLoggedAndTheEnterGoesOn() async {
        let rig = CoordinatorRig()
        switchesTheVirtualDisplay(rig.backend, to: Self.remembered)
        rig.backend.failing[.setMode] = FakeError.injected   // macOS refuses the mode
        #expect(await rig.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.events.all.contains(.init(name: "resolution.enforce.failed", fields: ["id": "50", "error": "injected"])))
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])

        // Accepted, but switched back at once: waited for 2 s, then logged, and the enter goes on.
        let stubborn = CoordinatorRig()
        switchesTheVirtualDisplay(stubborn.backend, to: Self.remembered) { $0 == "setOrigins" || $0 == "setMode(50)" }
        var at: [String: Duration] = [:]
        let onCall = stubborn.backend.onCall
        stubborn.backend.onCall = { [clock = stubborn.clock] call in
            onCall?(call)
            at[call] = clock.elapsed
        }
        #expect(await stubborn.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(stubborn.events.all.contains(
            .init(name: "resolution.enforce.failed", fields: ["id": "50", "error": "notApplied"])))
        #expect(at["setEnabled([1, 3],false)"].map { $0 - (at["setMode(50)"] ?? .zero) } == .seconds(2))
    }

    @Test func driftOnceTheMonitorsAreOffIsOnlyRecordedOncePerEpisode() async {
        let rig = await CoordinatorRig.inRemote()
        let calls = rig.backend.calls
        for i in rig.backend.displays.indices where rig.backend.displays[i].id == virtualID {
            rig.backend.displays[i].mode = Self.remembered
        }
        for _ in 1...3 {
            await rig.coordinator.handle(.tick)
            rig.clock.advance(by: .seconds(1))
        }
        #expect(rig.events.all.filter { $0.name == "resolution.drift" }
                == [.init(name: "resolution.drift", fields: ["id": "50", "listed": "1321x918", "wanted": "1180x820"])])
        #expect(rig.backend.calls == calls)   // the mode of the only display is left alone

        // The next episode records it again.
        _ = await rig.coordinator.exitToNormal(.user)
        _ = await rig.coordinator.enterRemote(confirmSeconds: 0)
        for i in rig.backend.displays.indices where rig.backend.displays[i].id == virtualID {
            rig.backend.displays[i].mode = Self.remembered
        }
        rig.clock.advance(by: .seconds(2))
        await rig.coordinator.handle(.tick)
        #expect(rig.events.all.filter { $0.name == "resolution.drift" }.count == 2)
    }

    @Test(arguments: [ConfigScope.appOnly, .session])
    func everyBackendCallUsesTheGivenScope(scope: ConfigScope) async {
        let rig = await CoordinatorRig.inRemote(scope: scope)
        _ = await rig.coordinator.exitToNormal(.user)
        #expect(rig.backend.scopes.count > 3)
        #expect(rig.backend.scopes.allSatisfy { $0 == scope })
    }
}
