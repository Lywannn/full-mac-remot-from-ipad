import Testing
@testable import IPadModeCore

private let virtualID = Fixtures.virtualRemote.id
private let legionID = Fixtures.legion.id
private let p24ID = Fixtures.p24.id

/// An iPad connected over Sidecar as one more monitor.
private let sidecar = DisplayInfo(
    id: DisplayID(raw: 7), uuid: "UUID-SIDECAR", vendor: 0x6161706C, model: 0x69506164, serial: 0,
    location: nil, name: "iPad", kind: .sidecar, isOnline: true, isActive: true, isMain: false,
    origin: Point(x: 3440, y: 0),
    mode: DisplayMode(widthPoints: 1180, heightPoints: 820, widthPixels: 2360, heightPixels: 1640, refreshHz: 60),
    mirrorOf: nil)

/// Keeps a task that a fake's hook starts, so that the test can wait for it.
@MainActor
private final class Later {
    var task: Task<Void, Never>?
}

@MainActor
struct CoordinatorRefusalTests {
    // MARK: Refusals change nothing (§7.4 preconditions, §7.3, I8)

    @Test func refusedWhenLocked() async {
        let rig = CoordinatorRig()
        rig.lock.isLocked = true
        #expect(await rig.coordinator.enterRemote() == .refused(.locked, Messages.locked))
        #expect(rig.backend.calls.isEmpty && rig.backend.listCount == 0)
        #expect(rig.store.saves.isEmpty && rig.notifier.notices.isEmpty)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.events.all == [.init(name: "enter.remote.refused", fields: ["reason": "locked"])])
    }

    @Test func refusedWhenPrivateAPIsMissing() async {
        let rig = CoordinatorRig(capabilities: Capabilities(privateAPIs: false))
        #expect(await rig.coordinator.enterRemote() == .refused(.unavailable, Messages.unavailable))
        #expect(rig.backend.calls.isEmpty && rig.host.resolutions.isEmpty)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.coordinator.state.phase == .normal)
    }

    @Test func refusedWhenSidecarActive() async {
        let rig = CoordinatorRig(displays: [Fixtures.legion, Fixtures.p24, sidecar])
        #expect(await rig.coordinator.enterRemote() == .refused(.sidecarActive, Messages.sidecarActive))
        #expect(rig.backend.calls.isEmpty && rig.host.resolutions.isEmpty)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24, sidecar])

        var idle = sidecar
        idle.isOnline = false; idle.isActive = false   // known to macOS, but not connected
        let free = CoordinatorRig(displays: [Fixtures.legion, Fixtures.p24, idle])
        #expect(await free.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))
    }

    @Test func refusedWhileTransitionInFlight() async {
        // While the confirmation shows, and once it is kept.
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        let confirmation = rig.coordinator.pendingConfirmation
        let calls = rig.backend.calls, saves = rig.store.saves.count
        #expect(await rig.coordinator.enterRemote() == .refused(.busy, Messages.busy))
        #expect(rig.backend.calls == calls && rig.store.saves.count == saves)
        #expect(rig.host.resolutions.count == 1 && rig.confirmer.requests == [20])
        rig.confirmer.resolve(.keep)
        await confirmation?.value
        #expect(await rig.coordinator.enterRemote() == .refused(.busy, Messages.busy))
        #expect(rig.coordinator.state.phase == .active(.remote))

        // While entering: during the settle delay.
        let entering = CoordinatorRig()
        let second = entering.coordinator
        entering.clock.duringNextSleep {
            #expect(await second.enterRemote() == .refused(.busy, Messages.busy))
        }
        #expect(await entering.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(entering.host.resolutions.count == 1)
        #expect(entering.events.names.filter { $0 == "enter.remote.refused" }.count == 1)

        // While returning to Normal: the monitors are waking up.
        let exiting = await CoordinatorRig.inRemote()
        exiting.backend.enableDelay = 3
        let during = exiting.coordinator
        exiting.clock.duringNextSleep {
            #expect(await during.enterRemote() == .refused(.busy, Messages.busy))
        }
        #expect(await exiting.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(exiting.host.resolutions.count == 1)
        #expect(exiting.events.names.filter { $0 == "enter.remote.refused" }.count == 1)
    }

    // MARK: Normal always wins (§7.3, §7.6 step 1)

    @Test func normalDuringEnteringPreempts() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()   // the dialog is showing, the monitors are off
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.confirmer.cancels == 1 && !rig.confirmer.isHolding)   // the dialog was closed
        rig.confirmer.resolve(.keep)   // nothing is left to answer, and a late keep would not count
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays.filter { $0.kind == .physical }.allSatisfy { $0.isOnline && $0.isActive })
        #expect(!rig.backend.displays.contains { $0.id == virtualID })
        #expect(rig.backend.calls.last == "stop(remote)")
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.notifier.notices == [Messages.backToNormal])
    }

    @Test func exitDuringStartStopsTheDisplayItStarted() async {
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator
        rig.host.startGate.close()
        let enter = Task { await coordinator.enterRemote() }
        await rig.host.startGate.untilHolding()   // `start` is still bringing the virtual display up
        #expect(await coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))   // nothing to stop yet
        #expect(coordinator.state.phase == .normal)
        rig.host.startGate.open()   // now `start` returns its display...
        #expect(await coordinator.enterRemote() == .refused(.busy, Messages.busy))   // ...to the enter still running
        #expect(await enter.value == .failed(Messages.enterFailed))

        #expect(rig.backend.calls.suffix(2) == ["start(remote)", "stop(remote)"])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])   // nothing left running
        #expect(coordinator.state.phase == .normal)
        #expect(coordinator.state.target == nil && coordinator.state.virtualPID == nil)
        #expect(rig.store.saves.contains { $0.phase == .exiting && $0.virtualPID == 4242 })   // saved before the stop
        #expect(rig.notifier.notices == [Messages.backToNormal])
        for (call, displays) in zip(rig.backend.calls, rig.backend.history) {
            #expect(displays.filter(\.isActive).count > 0, "no active display after \(call)")
        }
        let calls = rig.backend.calls
        #expect(await coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.backend.calls == calls)
    }

    @Test func leftoverDisplayStaysWhenItIsTheOnlyDisplay() async {
        let rig = CoordinatorRig(displays: [])   // no monitor attached
        let coordinator = rig.coordinator
        rig.host.startGate.close()
        let enter = Task { await coordinator.enterRemote() }
        await rig.host.startGate.untilHolding()
        #expect(await coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        rig.host.startGate.open()
        #expect(await enter.value == .refused(.noPhysicalMonitor, Messages.noPhysicalMonitor))
        // Stopping it would leave no display at all (I1): it stays, and the state names it for a later Normal.
        #expect(!rig.backend.calls.contains("stop(remote)"))
        #expect(rig.backend.displays.map(\.id) == [virtualID])
        #expect(coordinator.state.phase == .active(.remote))
        #expect(coordinator.state.target == virtualID && coordinator.state.virtualPID == 4242)

        rig.backend.displays.insert(Fixtures.legion, at: 0)   // a monitor is plugged in
        #expect(await coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.backend.displays == [Fixtures.legion])
        #expect(coordinator.state.phase == .normal)
    }

    @Test func failedExitDuringStartLeavesTheDisplayNamedForALaterNormal() async {
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator
        rig.host.startGate.close()
        let enter = Task { await coordinator.enterRemote() }
        await rig.host.startGate.untilHolding()
        rig.backend.failing[.listDisplays] = FakeError.injected   // Normal cannot read the displays
        #expect(await coordinator.exitToNormal(.user) == .failed(Messages.exitFailed))
        rig.backend.failing[.listDisplays] = nil
        rig.host.startGate.open()
        #expect(await enter.value == .failed(Messages.exitFailed))
        // The display `start` returned stays with the mode (R19), and the saved state names it.
        #expect(coordinator.state.phase == .active(.remote))
        #expect(rig.store.saves.last?.target == virtualID && rig.store.saves.last?.virtualPID == 4242)
        #expect(rig.backend.displays.contains { $0.id == virtualID })
        #expect(await coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func preemptedEnterRepliesWithTheExitThatFailed() async {
        let rig = CoordinatorRig()
        let coordinator = rig.coordinator, backend = rig.backend
        rig.clock.duringNextSleep {   // the settle delay: Normal is clicked, and it cannot read the displays
            backend.failing[.listDisplays] = FakeError.injected
            _ = await coordinator.exitToNormal(.user)
            backend.failing[.listDisplays] = nil
        }
        #expect(await coordinator.enterRemote() == .failed(Messages.exitFailed))
        #expect(!backend.calls.contains { $0.hasSuffix(",false)") })   // the monitors stayed on
        #expect(coordinator.state.phase == .active(.remote))   // and so does the virtual display (R19)
        #expect(coordinator.state.virtualPID == 4242)
        #expect(rig.notifier.notices == [Messages.exitFailed])
        // Nobody has confirmed this mode, so its automatic return is still owed.
        #expect(coordinator.exitRetryReason == .confirmTimeout)
        #expect(await coordinator.exitToNormal(.confirmTimeout) == .ok(Messages.revertedTimeout))
        #expect(backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    // MARK: The confirmation (§7.4 step 5)

    @Test func confirmTimeoutReverts() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.confirmer.resolve(.timedOut)   // nobody answered within 20 s
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.revertedTimeout])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.confirmer.cancels == 0)   // it had answered: nothing to close
    }

    @Test func confirmRevertReverts() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.confirmer.resolve(.revert)
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.backToNormal])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func dialogThatClosesUnansweredReverts() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.confirmer.resolve(.cancelled)   // closed without an answer, and not by a return to Normal
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.revertedTimeout])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func oldDialogAnswerNeverAffectsALaterSession() async {
        let rig = CoordinatorRig(confirm: nil)
        rig.confirmer.cancelAnswers = false   // the first dialog answers late, after it was closed
        _ = await rig.coordinator.enterRemote()
        let first = rig.coordinator.pendingConfirmation
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.confirmer.cancels == 1)
        #expect(await rig.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))   // a new session

        rig.confirmer.resolve(.revert)   // the first dialog's late answer
        await first?.value
        #expect(rig.coordinator.state.phase == .confirming(.remote))
        #expect(rig.confirmer.isHolding)   // the second dialog is still up
        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.notifier.notices == [Messages.backToNormal])
    }

    @Test func exitBeforeTheDialogShowsKeepsItClosed() async {
        let rig = CoordinatorRig(confirm: nil)
        let coordinator = rig.coordinator
        // Normal is clicked just as `.confirming` is saved, before the dialog has come up.
        rig.store.saveFailure = { state in
            if state.phase == .confirming(.remote) { Task { @MainActor in _ = await coordinator.exitToNormal(.user) } }
            return nil
        }
        _ = await coordinator.enterRemote()
        _ = await coordinator.exitToNormal(.hotkey)   // joins that return, or finds Normal
        #expect(coordinator.state.phase == .normal)
        #expect(rig.confirmer.requests.isEmpty && !rig.confirmer.isHolding)   // no dialog once back in Normal
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func failedUserExitWhileConfirmingIsStillRetried() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on
        #expect(await rig.coordinator.exitToNormal(.user) == .failed(Messages.exitFailed))
        #expect(rig.confirmer.cancels == 1)
        #expect(rig.coordinator.state.phase == .active(.remote))
        // Nobody confirmed the mode: the automatic return of §7.4 step 5 is still owed.
        #expect(rig.coordinator.exitRetryReason == .confirmTimeout)
        rig.confirmer.resolve(.keep)   // nothing is left to answer, and a late keep would not count
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.exitRetryReason == .confirmTimeout)

        rig.backend.failing[.enable] = nil
        #expect(await rig.coordinator.exitToNormal(.confirmTimeout) == .ok(Messages.revertedTimeout))   // the retry
        #expect(rig.coordinator.exitRetryReason == nil)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    // MARK: A locked Mac means Normal (I8, §7.10)

    @Test func lockDuringConfirmReverts() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()
        rig.lock.isLocked = true
        await rig.coordinator.handle(.screenLocked)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.revertedLocked])
        #expect(rig.confirmer.cancels == 1 && !rig.confirmer.isHolding)
        rig.confirmer.resolve(.keep)   // nothing is left to answer, and a late keep would not count
        await rig.coordinator.pendingConfirmation?.value
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func lockBeforeDisableAborts() async {
        // The Mac locks while the virtual display starts...
        let rig = CoordinatorRig()
        rig.backend.onCall = { [lock = rig.lock] call in if call == "start(remote)" { lock.isLocked = true } }
        #expect(await rig.coordinator.enterRemote() == .refused(.locked, Messages.locked))
        #expect(!rig.backend.calls.contains { $0.hasSuffix(",false)") })
        #expect(rig.backend.originRequests.allSatisfy { $0[virtualID] != Point(x: 0, y: 0) })   // never made main
        #expect(rig.backend.calls.last == "stop(remote)")
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.revertedLocked])
        #expect(rig.confirmer.requests.isEmpty)

        // ...or during the settle delay, right before the monitors would go off...
        let settling = CoordinatorRig()
        let lock = settling.lock
        settling.clock.duringNextSleep { lock.isLocked = true }
        #expect(await settling.coordinator.enterRemote() == .refused(.locked, Messages.locked))
        #expect(settling.events.names.contains("target.main") && settling.clock.elapsed == .seconds(1))
        #expect(!settling.backend.calls.contains { $0.hasSuffix(",false)") })
        #expect(settling.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(settling.coordinator.state.phase == .normal)
        #expect(settling.notifier.notices == [Messages.revertedLocked])

        // ...or the lock event arrives then.
        let notified = CoordinatorRig()
        let coordinator = notified.coordinator, locked = notified.lock
        notified.clock.duringNextSleep {
            locked.isLocked = true
            await coordinator.handle(.screenLocked)
        }
        #expect(await coordinator.enterRemote() == .refused(.locked, Messages.locked))
        #expect(!notified.backend.calls.contains { $0.hasSuffix(",false)") })
        #expect(notified.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(coordinator.state.phase == .normal)
        #expect(notified.notifier.notices == [Messages.revertedLocked])
    }

    @Test func automaticReturnJoiningAFailingExitIsRetried() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.enableDelay = 1000   // the monitors do not wake up in time
        let coordinator = rig.coordinator
        let later = Later()
        rig.clock.duringNextSleep {   // the Mac locks while Normal waits for the monitors
            later.task = Task { await coordinator.handle(.screenLocked) }
        }
        #expect(await coordinator.exitToNormal(.user) == .failed(Messages.exitFailed))
        await later.task?.value
        // The lock joined it: one way back (which asks for the monitors again every second, A-2).
        #expect(rig.events.names.filter { $0.hasPrefix("exit.") && $0.hasSuffix(".begin") } == ["exit.user.begin"])
        #expect(coordinator.exitRetryReason == .locked)   // and its return is left for a retry
        #expect(rig.notifier.notices == [Messages.exitFailed])
    }

    // MARK: Rollback (§7.4, failures in steps 2–4)

    @Test func rollbackWhenVirtualFailsToAppear() async {
        let rig = CoordinatorRig()
        rig.host.startError = FakeError.injected   // vdisplay could not create its display
        #expect(await rig.coordinator.enterRemote() == .failed(Messages.virtualFailed))
        #expect(!rig.backend.calls.contains { $0.hasPrefix("setEnabled") })
        #expect(!rig.backend.calls.contains("stop(remote)"))   // nothing was started
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.coordinator.state.lastError == "virtualFailed")
        #expect(rig.store.saves.last?.lastError == "virtualFailed")
        #expect(rig.notifier.notices == [Messages.virtualFailed])
        #expect(rig.events.all.contains(.init(name: "virtual.failed", fields: ["error": "injected"])))
    }

    @Test func rollbackWhenDisableFails() async throws {
        let rig = CoordinatorRig()
        rig.backend.failing[.disable] = FakeError.injected
        // The call reports an error, though macOS had already turned the P24 off.
        rig.backend.onCall = { [backend = rig.backend] call in
            guard call == "setEnabled([1, 3],false)" else { return }
            for i in backend.displays.indices where backend.displays[i].id == p24ID {
                backend.displays[i].isOnline = false; backend.displays[i].isActive = false
            }
        }
        #expect(await rig.coordinator.enterRemote() == .failed(Messages.enterFailed))
        let enable = try #require(rig.backend.calls.firstIndex(of: "setEnabled([3],true)"))
        let stop = try #require(rig.backend.calls.firstIndex(of: "stop(remote)"))
        #expect(enable < stop)   // I3
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.coordinator.state.lastError == "injected")
        #expect(rig.notifier.notices == [Messages.enterFailed])
        for (call, displays) in zip(rig.backend.calls, rig.backend.history) {
            #expect(displays.filter(\.isActive).count > 0, "no active display after \(call)")
        }
    }

    @Test func rollbackRepliesWithTheExitThatFailed() async {
        let rig = CoordinatorRig(confirm: nil)
        // With the monitors off, `.confirming` cannot be saved, and the monitors will not turn back on.
        rig.store.saveFailure = { $0.phase == .confirming(.remote) ? FakeError.injected : nil }
        rig.backend.failing[.enable] = FakeError.injected
        #expect(await rig.coordinator.enterRemote() == .failed(Messages.exitFailed))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])   // I1: the virtual display stays
        #expect(!rig.backend.calls.contains("stop(remote)"))
        #expect(rig.coordinator.state.phase == .active(.remote))
        #expect(rig.coordinator.exitRetryReason == .failure)
        #expect(rig.notifier.notices == [Messages.exitFailed])
        #expect(rig.confirmer.requests.isEmpty)
    }

    @Test func saveFailureBeforeAnyActionLeavesTheDisplaysAlone() async {
        let rig = CoordinatorRig()
        rig.store.saveFailure = { _ in FakeError.injected }   // the disk is full
        #expect(await rig.coordinator.enterRemote() == .failed(Messages.enterFailed))
        #expect(rig.backend.calls.isEmpty && rig.host.resolutions.isEmpty)   // `start` was never called
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal && rig.store.saves.isEmpty)
        #expect(rig.events.all.contains(.init(name: "enter.remote.failed", fields: ["error": "injected"])))
    }

    @Test func saveFailureAfterDisablingStillRestoresTheMonitors() async {
        let rig = CoordinatorRig(confirm: nil)
        // The disk fills up right after the monitors went off.
        rig.backend.onCall = { [store = rig.store] call in
            if call == "setEnabled([1, 3],false)" { store.saveFailure = { _ in FakeError.injected } }
        }
        #expect(await rig.coordinator.enterRemote() == .failed(Messages.enterFailed))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.confirmer.requests.isEmpty)
        #expect(rig.events.names.contains("state.save.failed"))
        #expect(rig.notifier.notices == [Messages.enterFailed])
    }

    @Test func lastErrorIsSavedAndClearedByTheNextSuccess() async {
        let rig = CoordinatorRig()
        var savedAtRollback: PersistedState?
        // macOS turns the P24 straight back on, so the enter fails and rolls back.
        rig.backend.onCall = { [backend = rig.backend, store = rig.store] call in
            if call == "setEnabled([1, 3],false)" {
                for i in backend.displays.indices where backend.displays[i].id == p24ID {
                    backend.displays[i].isOnline = true; backend.displays[i].isActive = true
                }
            }
            if call == "setEnabled([1],true)" { savedAtRollback = store.saves.last }
        }
        #expect(await rig.coordinator.enterRemote() == .failed(Messages.enterFailed))
        #expect(savedAtRollback?.lastError == "physicalStillActive")   // saved before the rollback acts
        #expect(rig.store.saves.last?.lastError == "physicalStillActive")   // and kept once back in Normal
        #expect(rig.coordinator.state.lastError == "physicalStillActive")

        rig.backend.onCall = nil
        #expect(await rig.coordinator.enterRemote() == .ok(Messages.remoteEntered(seconds: 20)))
        #expect(rig.coordinator.state.lastError == nil && rig.store.saves.last?.lastError == nil)

        await rig.coordinator.pendingConfirmation?.value
        rig.backend.failing[.enable] = FakeError.injected
        #expect(await rig.coordinator.exitToNormal(.user) == .failed(Messages.exitFailed))
        #expect(rig.store.saves.last?.lastError == "monitorsNotActive")   // no monitor came on (A-2)
        rig.backend.failing[.enable] = nil
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.coordinator.state.lastError == nil && rig.store.saves.last?.lastError == nil)
    }

    // MARK: The way back (§7.6)

    @Test func exitWaitsUpToTenSecondsForMonitorsToWake() async {
        let slow = await CoordinatorRig.inRemote()
        slow.backend.enableDelay = 71   // online at the 71st poll, 7 s in, like a monitor waking from standby
        let before = slow.clock.elapsed
        #expect(await slow.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(slow.clock.elapsed - before == .seconds(7))
        #expect(slow.backend.displays == [Fixtures.legion, Fixtures.p24])

        let asleep = await CoordinatorRig.inRemote()
        asleep.backend.enableDelay = 1000
        let start = asleep.clock.elapsed
        #expect(await asleep.coordinator.exitToNormal(.user) == .failed(Messages.exitFailed))
        #expect(asleep.clock.elapsed - start == .seconds(10))
        #expect(asleep.events.names.contains("physical.enable.timeout"))
    }

    @Test func restoreSetsOnlyModesThatChanged() async {
        // The Legion comes back at another mode; the P24 comes back as it was, as the real portrait P24 does.
        let other = DisplayMode(widthPoints: 2560, heightPoints: 1080, widthPixels: 2560, heightPixels: 1080,
                                refreshHz: 60)
        func wakeLegionAtOtherMode(_ backend: FakeDisplayBackend) {
            backend.onCall = { [backend] call in
                guard call == "setEnabled([1, 3],true)" else { return }
                for i in backend.displays.indices where backend.displays[i].id == legionID {
                    backend.displays[i].mode = other
                }
            }
        }
        let rig = await CoordinatorRig.inRemote()
        wakeLegionAtOtherMode(rig.backend)
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.backend.calls.filter { $0.hasPrefix("setMode") } == ["setMode(1)"])
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])

        // A mode that cannot be set is logged, and Normal still comes back.
        let stuck = await CoordinatorRig.inRemote()
        wakeLegionAtOtherMode(stuck.backend)
        stuck.backend.failing[.setMode] = FakeError.injected
        #expect(await stuck.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(stuck.events.all.contains(
            .init(name: "restore.failed", fields: ["step": "mode", "id": "1", "error": "injected"])))
        #expect(stuck.backend.calls.last == "stop(remote)")
        #expect(stuck.coordinator.state.phase == .normal)
    }

    @Test func restoreMovesOnlyDisplaysThatExist() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.displays.removeAll { $0.id == virtualID }   // the virtual display is already gone
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.backend.originRequests.last == [legionID: Point(x: 0, y: 0), p24ID: Point(x: -1920, y: -326)])
        #expect(!rig.events.names.contains("restore.failed"))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.coordinator.state.phase == .normal)
    }
}

/// The fakes behave like macOS where the Coordinator relies on it.
@MainActor
struct FakeFidelityTests {
    @Test func disablingTheMainDisplayPromotesAnother() throws {
        let backend = FakeDisplayBackend([Fixtures.legion, Fixtures.p24])
        try backend.setEnabled([legionID], enabled: false, scope: .session)
        #expect(backend.displays.filter(\.isMain).map(\.id) == [p24ID])
        // The new main display is at (0,0), and the rest of the layout moved with it.
        #expect(backend.displays.map(\.origin) == [Point(x: 1920, y: 326), Point(x: 0, y: 0)])
    }

    @Test func stoppingTheMainVirtualDisplayPromotesAnother() async throws {
        let backend = FakeDisplayBackend([Fixtures.legion, Fixtures.p24])
        let host = FakeVirtualHost(backend: backend)
        let handle = try await host.start(role: .remote, resolution: .defaultRemote)
        try backend.setOrigins([virtualID: Point(x: 0, y: 0), legionID: Point(x: 1180, y: 0),
                                p24ID: Point(x: 4620, y: 0)], scope: .session)
        try #require(backend.displays.filter(\.isMain).map(\.id) == [virtualID])
        await host.stop(handle)
        #expect(backend.displays.filter(\.isMain).map(\.id) == [legionID])
        #expect(backend.displays.map(\.origin) == [Point(x: 0, y: 0), Point(x: 3440, y: 0)])

        // Losing a display that is not main changes nothing else.
        backend.remove(p24ID)
        #expect(backend.displays.map(\.id) == [legionID])
        #expect(backend.displays.first?.isMain == true && backend.displays.first?.origin == Point(x: 0, y: 0))
    }

    @Test func setOriginsWithAnUnknownDisplayFailsAsAWhole() {
        let backend = FakeDisplayBackend([Fixtures.legion, Fixtures.p24])
        #expect(throws: FakeError.unknownDisplay) {
            try backend.setOrigins([p24ID: Point(x: 3440, y: 0), virtualID: Point(x: 0, y: 0)], scope: .session)
        }
        #expect(backend.displays == [Fixtures.legion, Fixtures.p24])
    }
}
