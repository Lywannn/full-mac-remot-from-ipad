import Testing
@testable import IPadModeCore

private let virtualID = Fixtures.virtualRemote.id

/// R56: CoreGraphics lists a change 0.05–0.31 s after its transaction, so the checks after transactions A and B poll
/// (target main ≤2 s, the target alone active ≤3 s, every 100 ms) and stop as soon as a return to Normal or a lock
/// cuts in. R79: a way back that starts within 1 s of a disable waits until 1 s after it before it lists anything.
/// The fake backend shows each late change only after a given number of lists, or a given time.
@MainActor
struct CoordinatorLateCGTests {
    // MARK: Transaction A: the target becomes main

    @Test func targetListedAsMainLateIsWaitedFor() async throws {
        let rig = CoordinatorRig()
        rig.backend.originsDelay = 6   // listed as main on the 6th list: 0.5 s after the transaction
        var at: [String: Duration] = [:]
        rig.backend.onCall = { [clock = rig.clock] call in at[call] = clock.elapsed }
        let result = await rig.coordinator.enterRemote()
        await rig.coordinator.pendingConfirmation?.value
        #expect(result == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        // The settle delay starts once the target is listed as main.
        let main = try #require(at["setOrigins"]), disable = try #require(at["setEnabled([1, 3],false)"])
        #expect(disable - main == .milliseconds(1500))
    }

    @Test func targetNotListedAsMainWithinTwoSecondsEndsTheEnter() async {
        let rig = CoordinatorRig()
        rig.backend.originsDelay = 22   // the 21 polls of the 2 s miss it; the rollback's first list shows it
        rig.backend.onCall = { [backend = rig.backend] call in
            if call == "setOrigins" { backend.originsDelay = 0 }   // the rollback's own layout is listed at once
        }
        let result = await rig.coordinator.enterRemote()
        #expect(result == .failed(Messages.enterFailed))
        #expect(rig.clock.elapsed == .seconds(2))
        #expect(rig.coordinator.state.lastError == "targetNotMain")
        #expect(!rig.events.names.contains("target.main"))
        #expect(!rig.backend.calls.contains { $0.hasSuffix(",false)") })   // the monitors stayed on
        #expect(rig.backend.calls.last == "stop(remote)")
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])   // the late layout was undone too
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.enterFailed])
    }

    @Test func returnToNormalOrLockDuringTheMainPollEndsTheEnterAtOnce() async {
        // Normal is clicked while the target is not yet listed as main.
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator
        rig.backend.originsDelay = 1000
        rig.backend.onCall = { [backend = rig.backend] call in
            if call == "setOrigins" { backend.originsDelay = 0 }
        }
        rig.clock.duringNextSleep { _ = await coordinator.exitToNormal(.user) }   // the first sleep of the poll
        #expect(await coordinator.enterRemote() == .failed(Messages.enterFailed))
        #expect(rig.clock.elapsed == .milliseconds(100))   // not the 2 s of a target that stays put
        #expect(!rig.events.names.contains("target.main"))
        #expect(!rig.backend.calls.contains { $0.hasSuffix(",false)") })
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.backToNormal])

        // The Mac locks meanwhile.
        let locked = CoordinatorRig()
        let lock = locked.lock
        locked.backend.originsDelay = 1000
        locked.backend.onCall = { [backend = locked.backend] call in
            if call == "setOrigins" { backend.originsDelay = 0 }
        }
        locked.clock.duringNextSleep { lock.isLocked = true }
        #expect(await locked.coordinator.enterRemote() == .refused(.locked, Messages.locked))
        #expect(locked.clock.elapsed == .milliseconds(100))
        #expect(!locked.backend.calls.contains { $0.hasSuffix(",false)") })
        #expect(locked.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(locked.coordinator.state.phase == .normal)
        #expect(locked.notifier.notices == [Messages.revertedLocked])
    }

    // MARK: Transaction B: the monitors go off

    @Test func monitorsListedOffLateAreWaitedFor() async {
        let rig = CoordinatorRig()
        rig.backend.disableDelay = 10   // listed off on the 10th list: 0.9 s after the transaction
        let result = await rig.coordinator.enterRemote()
        await rig.coordinator.pendingConfirmation?.value
        #expect(result == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(rig.clock.elapsed == .milliseconds(1900))   // the 1 s settle, then 0.9 s
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        // The confirmation comes only once the monitors are listed off.
        #expect(Array(rig.events.names.prefix(5))
                == ["enter.remote.begin", "virtual.ready", "target.main", "physical.disabled", "confirm.keep"])
    }

    @Test func monitorsNotListedOffWithinThreeSecondsEndTheEnter() async throws {
        let rig = CoordinatorRig()
        rig.backend.disableDelay = 32   // the 31 polls of the 3 s miss it; the rollback's first list shows it
        let result = await rig.coordinator.enterRemote()
        #expect(result == .failed(Messages.enterFailed))
        #expect(rig.clock.elapsed == .seconds(4))   // the 1 s settle, then the 3 s
        #expect(rig.coordinator.state.lastError == "physicalStillActive")
        #expect(!rig.events.names.contains("physical.disabled"))
        #expect(rig.confirmer.requests.isEmpty)
        // The monitors that went off late are turned back on before the virtual display goes (I3).
        let enable = try #require(rig.backend.calls.firstIndex(of: "setEnabled([1, 3],true)"))
        let stop = try #require(rig.backend.calls.firstIndex(of: "stop(remote)"))
        #expect(enable < stop)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.enterFailed])
    }

    @Test func targetLostWhileTheMonitorsGoOffEndsTheEnterAtOnce() async throws {
        // B-10: the virtual display goes just as the monitors are turned off; the poll must not wait 3 s for a target
        // that is gone, with nothing lit meanwhile.
        let rig = CoordinatorRig()
        rig.backend.disableLateness = .milliseconds(300)
        var at: [String: Duration] = [:]
        rig.backend.onCall = { [backend = rig.backend, clock = rig.clock] call in
            at[call] = clock.elapsed
            if call == "setEnabled([1, 3],false)" { backend.remove(virtualID) }
        }
        #expect(await rig.coordinator.enterRemote() == .failed(Messages.enterFailed))
        #expect(rig.coordinator.state.lastError == "targetLost")
        // The way back began at once, and turned the monitors on as soon as R79 trusts the listing, 1 s after the
        // disable: not after the 3 s of a monitor that stays on.
        let disabled = try #require(at["setEnabled([1, 3],false)"])
        #expect(at["setEnabled([1, 3],true)"] == disabled + .seconds(1))
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays.filter { $0.kind == .physical }.allSatisfy { $0.isOnline && $0.isActive })
    }

    @Test func returnToNormalOrLockDuringTheDisablePollEndsTheEnterAtOnce() async {
        // Normal is clicked while the monitors are not yet listed off; the way back lists them off.
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator
        rig.backend.disableDelay = 2
        rig.backend.onCall = { [clock = rig.clock] call in
            guard call == "setEnabled([1, 3],false)" else { return }
            clock.duringNextSleep { _ = await coordinator.exitToNormal(.user) }   // the first sleep of the poll
        }
        #expect(await coordinator.enterRemote() == .failed(Messages.enterFailed))
        // The way back settles until 1 s after the disable (R79), at 2 s, and the poll ends with it: not at its 3 s
        // deadline, 4 s.
        #expect(rig.clock.elapsed == .seconds(2))
        #expect(!rig.events.names.contains("physical.disabled"))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(coordinator.state.phase == .normal)
        #expect(rig.confirmer.requests.isEmpty)
        #expect(rig.notifier.notices == [Messages.backToNormal])

        // The Mac locks meanwhile.
        let locked = CoordinatorRig()
        let lock = locked.lock
        locked.backend.disableDelay = 2
        locked.backend.onCall = { [clock = locked.clock] call in
            guard call == "setEnabled([1, 3],false)" else { return }
            clock.duringNextSleep { lock.isLocked = true }
        }
        #expect(await locked.coordinator.enterRemote() == .refused(.locked, Messages.locked))
        #expect(locked.clock.elapsed == .seconds(2))   // stopped at 1.1 s; then the way back settles until 2 s
        #expect(locked.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(locked.coordinator.state.phase == .normal)
        #expect(locked.confirmer.requests.isEmpty)
        #expect(locked.notifier.notices == [Messages.revertedLocked])
    }

    // MARK: The way back right after a disable (R79)

    @Test func wayBackRightAfterADisableWaitsUntilTheMonitorsAreListedOff() async throws {
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator, clock = rig.clock, backend = rig.backend
        backend.disableLateness = .milliseconds(300)   // listed on and active for 0.3 s after the disable, then off
        backend.enableDelay = 3   // turned back on, the monitors take two more polls to wake
        var at: [String: Duration] = [:]
        var listedAt: [Duration] = []
        backend.onList = { listedAt.append(clock.elapsed) }
        backend.onCall = { call in
            at[call] = clock.elapsed
            guard call == "setEnabled([1, 3],false)" else { return }
            clock.duringNextSleep { _ = await coordinator.exitToNormal(.user) }   // Normal, 0.1 s after the disable
        }
        #expect(await coordinator.enterRemote() == .failed(Messages.enterFailed))
        let disabled = try #require(at["setEnabled([1, 3],false)"])
        // The way back waited until 1 s after the disable, and listed nothing before...
        #expect(listedAt.filter { $0 > disabled }.allSatisfy { $0 >= disabled + .seconds(1) })
        #expect(rig.events.all.contains(.init(name: "exit.settle", fields: ["ms": "900"])))
        // ...so it planned from a list that shows the monitors off, and turned them back on...
        let enable = try #require(backend.calls.firstIndex(of: "setEnabled([1, 3],true)"))
        let stop = try #require(backend.calls.firstIndex(of: "stop(remote)"))
        #expect(enable < stop)
        #expect(at["setEnabled([1, 3],true)"] == disabled + .seconds(1))
        // ...and stopped the virtual display only once they were listed active, two polls later.
        #expect(rig.events.names.contains("physical.enabled"))
        #expect(at["stop(remote)"] == disabled + .milliseconds(1200))
        let monitorsBeforeStop = backend.history[stop - 1].filter { $0.kind == .physical }
        #expect(monitorsBeforeStop.count == 2 && monitorsBeforeStop.allSatisfy { $0.isActive })
        // Some display was active at every point, and once macOS has caught up the monitors are back as before.
        clock.advance(by: .seconds(1))
        #expect(try backend.listDisplays() == [Fixtures.legion, Fixtures.p24])
        let everyStateShowedADisplay = (backend.history + backend.listings).allSatisfy { $0.contains { $0.isActive } }
        #expect(everyStateShowedADisplay)
        #expect(coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.backToNormal])
    }

    @Test func wayBackLongAfterADisableDoesNotWait() async {
        let rig = await CoordinatorRig.inRemote()
        rig.clock.advance(by: .seconds(5))
        let before = rig.clock.elapsed
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.clock.elapsed == before)   // no extra wait
        #expect(!rig.events.names.contains("exit.settle"))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])

        // Exactly 1 s after the disable is long enough.
        let boundary = CoordinatorRig()
        _ = await boundary.coordinator.enterRemote()   // kept at once: the monitors went off just now
        await boundary.coordinator.pendingConfirmation?.value
        boundary.clock.advance(by: .seconds(1))
        let start = boundary.clock.elapsed
        #expect(await boundary.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(boundary.clock.elapsed == start)
        #expect(!boundary.events.names.contains("exit.settle"))
    }

    @Test func wayBackRightAfterTheGuardDisabledAMonitorWaitsToo() async throws {
        let rig = await CoordinatorRig.inRemote()
        let backend = rig.backend
        backend.disableLateness = .milliseconds(300)
        // The Legion comes back on, and the guard turns it off again; it stays listed on for 0.3 s.
        for i in backend.displays.indices where backend.displays[i].id == Fixtures.legion.id {
            backend.displays[i].isOnline = true; backend.displays[i].isActive = true
        }
        await rig.coordinator.handle(.displaysChanged)
        #expect(backend.calls.last == "setEnabled([1],false)")
        // 0.1 s later the virtual display is lost.
        rig.clock.advance(by: .milliseconds(100))
        backend.remove(virtualID)
        let before = rig.clock.elapsed
        await rig.coordinator.handle(.displaysChanged)
        #expect(rig.clock.elapsed - before == .milliseconds(900))   // until 1 s after the guard's disable
        // Planned from a list that shows the Legion off: both monitors are turned back on, not the P24 alone.
        #expect(backend.calls.contains("setEnabled([1, 3],true)"))
        #expect(rig.coordinator.state.phase == .normal)
        rig.clock.advance(by: .seconds(1))
        #expect(try backend.listDisplays() == [Fixtures.legion, Fixtures.p24])
        #expect(rig.notifier.notices == [Messages.targetLost])
    }
}
