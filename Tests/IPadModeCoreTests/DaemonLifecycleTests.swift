import Foundation
import Testing
@testable import IPadModeCore

private let virtualID = Fixtures.virtualRemote.id

/// What a run that crashed in Remote left: its `state.json`, and the monitors it had disabled.
private func crashedInRemote() -> PersistedState {
    var state = PersistedState.initial
    state.phase = .active(.remote)
    state.baseline = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    state.target = virtualID
    state.virtualPID = 4242
    state.cleanShutdown = false
    return state
}

private let monitorsLeftOff: [DisplayInfo] = [Fixtures.legion, Fixtures.p24].map { display in
    var off = display
    off.isOnline = false; off.isActive = false; off.isMain = false
    return off
}

/// What the lifecycle asked of the system.
@MainActor
private final class SystemCalls {
    /// The phase and the recorded vdisplay PID at each `stopStale`.
    var staleStops: [(phase: Phase, virtualPID: Int32?)] = []
    var exitsAfterDisable = 0
}

/// A lifecycle around a rig, with its files in a fresh temporary directory.
@MainActor
private final class Harness {
    let rig: CoordinatorRig
    let paths: Paths
    let calls = SystemCalls()
    let lifecycle: DaemonLifecycle

    init(_ rig: CoordinatorRig) {
        self.rig = rig
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = Paths(support: dir, logs: dir.appendingPathComponent("logs"))
        let calls = self.calls, coordinator = rig.coordinator
        lifecycle = DaemonLifecycle(coordinator: coordinator, backend: rig.backend, notifier: rig.notifier,
                                    events: rig.events, paths: paths, clock: rig.clock,
                                    stopStale: { calls.staleStops.append((coordinator.state.phase,
                                                                          coordinator.state.virtualPID)) },
                                    exitAfterDisable: { calls.exitsAfterDisable += 1 })
    }

    deinit { try? FileManager.default.removeItem(at: paths.support) }

    func writeIncident(enabledOK: Bool) throws {
        let incident = WatchdogFiles.Incident(time: Date(timeIntervalSince1970: 0), reason: "daemonDead",
                                              disabled: ["Legion 34W-2c"], enabledOK: enabledOK, layoutOK: true)
        try WatchdogFiles.writeIncident(incident, to: paths.incident)
    }

    var incidentExists: Bool { FileManager.default.fileExists(atPath: paths.incident.path) }
}

/// R48–R54: the daemon around its Coordinator.
@MainActor
struct DaemonLifecycleTests {
    // MARK: Startup (R48 steps 9–11, R33)

    @Test func startInNormalStopsStaleProcessesAfterTheReconcile() async {
        let harness = Harness(CoordinatorRig(persisted: .initial))
        await harness.lifecycle.start()
        #expect(harness.rig.store.saves.count == 1)   // the reconcile counted the start first
        #expect(harness.calls.staleStops.count == 1)
        #expect(harness.calls.staleStops.first?.phase == .normal)
        #expect(!harness.lifecycle.staleCleanupPending)
        #expect(harness.rig.events.names.contains("stale.cleanup"))
    }

    @Test func startAfterACrashStopsStaleProcessesOnceTheMonitorsAreBack() async {
        let harness = Harness(CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote()))
        await harness.lifecycle.start()
        #expect(harness.rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(harness.calls.staleStops.count == 1)
        #expect(harness.calls.staleStops.first?.phase == .normal && harness.calls.staleStops.first?.virtualPID == nil)
    }

    @Test func staleCleanupWaitsForATickInNormalWhenTheRestoreFails() async {
        let harness = Harness(CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote()))
        let rig = harness.rig
        rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on yet
        await harness.lifecycle.start()
        // The stale vdisplay process may be the only active display: it is left alone (R33 amended).
        #expect(rig.coordinator.state.phase == .exiting && rig.coordinator.state.virtualPID == 4242)
        #expect(harness.calls.staleStops.isEmpty && harness.lifecycle.staleCleanupPending)

        await harness.lifecycle.tick()   // the owed return is not due yet
        #expect(harness.calls.staleStops.isEmpty && harness.lifecycle.staleCleanupPending)

        rig.backend.failing[.enable] = nil
        rig.clock.advance(by: .seconds(10))
        await harness.lifecycle.tick()   // the retry brings the monitors back
        #expect(rig.coordinator.state.phase == .normal)
        #expect(harness.calls.staleStops.count == 1)
        #expect(harness.calls.staleStops.first?.phase == .normal && harness.calls.staleStops.first?.virtualPID == nil)
        #expect(!harness.lifecycle.staleCleanupPending)

        await harness.lifecycle.tick()
        #expect(harness.calls.staleStops.count == 1)   // once only
    }

    @Test func staleCleanupWaitsUntilAMonitorIsLit() async {
        // After a crash an orphan vdisplay child is in R25: its display is the only one, and the monitors it turned on
        // are still waking, missing from the listing. Stopping it now would cut R25 short (A-4).
        let harness = Harness(CoordinatorRig(displays: [Fixtures.virtualRemote], persisted: .initial))
        let rig = harness.rig
        await harness.lifecycle.start()
        #expect(rig.coordinator.state.phase == .normal && rig.coordinator.state.virtualPID == nil)
        #expect(harness.calls.staleStops.isEmpty && harness.lifecycle.staleCleanupPending)
        await harness.lifecycle.tick()
        #expect(harness.calls.staleStops.isEmpty)   // still no monitor lit
        var dark = Fixtures.legion
        dark.isActive = false
        rig.backend.displays.insert(dark, at: 0)   // online, not lit yet
        await harness.lifecycle.tick()
        #expect(harness.calls.staleStops.isEmpty)
        rig.backend.displays[0].isActive = true   // lit
        await harness.lifecycle.tick()
        #expect(harness.calls.staleStops.count == 1 && !harness.lifecycle.staleCleanupPending)
    }

    @Test func incidentThatRestoredTheMonitorsIsToldAndRemoved() async throws {
        let harness = Harness(CoordinatorRig(persisted: .initial))
        try harness.writeIncident(enabledOK: true)
        await harness.lifecycle.start()
        #expect(harness.rig.notifier.notices == [Messages.recovered])
        #expect(!harness.incidentExists)
        #expect(harness.rig.events.all.contains(
            .init(name: "incident.seen", fields: ["reason": "daemonDead", "enabledOK": "true", "layoutOK": "true"])))
    }

    @Test func incidentThatDidNotRestoreTheMonitorsIsOnlyRemoved() async throws {
        let harness = Harness(CoordinatorRig(persisted: .initial))
        try harness.writeIncident(enabledOK: false)
        await harness.lifecycle.start()
        #expect(harness.rig.notifier.notices.isEmpty)
        #expect(!harness.incidentExists)
        #expect(harness.rig.events.all.contains { $0.name == "incident.seen" && $0.fields["enabledOK"] == "false" })
    }

    @Test func unreadableIncidentIsRemoved() async throws {
        let harness = Harness(CoordinatorRig(persisted: .initial))
        try Data("not json".utf8).write(to: harness.paths.incident)
        await harness.lifecycle.start()
        #expect(harness.rig.notifier.notices.isEmpty)
        #expect(!harness.incidentExists)
        #expect(harness.rig.events.all.contains(.init(name: "incident.seen", fields: ["error": "unreadable"])))

        let quiet = Harness(CoordinatorRig(persisted: .initial))   // no incident: nothing to tell
        await quiet.lifecycle.start()
        #expect(!quiet.rig.events.names.contains("incident.seen") && quiet.rig.notifier.notices.isEmpty)
    }

    // MARK: The tick (R54)

    @Test func tickIsSkippedWhileTheLastOneRuns() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.failing[.enable] = FakeError.injected
        _ = await rig.coordinator.exitToNormal(.confirmTimeout)   // fails: owed, retried 10 s later
        rig.backend.failing[.enable] = nil
        rig.clock.advance(by: .seconds(10))
        rig.host.stopGate.close()   // the retry will be held as it stops the virtual display
        let harness = Harness(rig)
        let lifecycle = harness.lifecycle
        let first = Task { await lifecycle.tick() }
        await rig.host.stopGate.untilHolding()
        await lifecycle.tick()   // the first is still running: skipped
        await lifecycle.tick()
        #expect(rig.events.names.filter { $0 == "tick.skipped" }.count == 1)   // once per stuck stretch
        #expect(rig.events.names.filter { $0 == "exit.retry" }.count == 1)
        rig.host.stopGate.open()
        await first.value
        #expect(rig.coordinator.state.phase == .normal)

        await lifecycle.tick()   // runs again
        #expect(rig.events.names.filter { $0 == "tick.skipped" }.count == 1)
    }

    // MARK: The hotkey (R52)

    @Test func hotkeyShowsOnlyARefusal() async {
        let normal = Harness(CoordinatorRig())
        await normal.lifecycle.hotkeyPressed()
        #expect(normal.rig.notifier.notices.isEmpty)   // already Normal: nothing to tell

        let remote = Harness(await CoordinatorRig.inRemote())
        await remote.lifecycle.hotkeyPressed()
        #expect(remote.rig.coordinator.state.phase == .normal)
        #expect(remote.rig.notifier.notices == [Messages.backToNormal])   // the Coordinator's notice only
        #expect(remote.rig.events.names.contains("exit.hotkey.begin"))

        let failing = Harness(await CoordinatorRig.inRemote())
        failing.rig.backend.failing[.enable] = FakeError.injected
        await failing.lifecycle.hotkeyPressed()
        #expect(failing.rig.notifier.notices == [Messages.exitFailed])   // told once, by the Coordinator

        let headless = Harness(await CoordinatorRig.inRemote(displays: []))
        await headless.lifecycle.hotkeyPressed()
        #expect(headless.rig.notifier.notices == [Messages.noPhysicalMonitor])
    }

    // MARK: The socket (R49)

    @Test func requestsAreRoutedUntilTheDaemonShutsDown() async {
        let harness = Harness(CoordinatorRig())
        let lifecycle = harness.lifecycle
        #expect(await lifecycle.respond(.normal).result == .ok(Messages.backToNormal))
        #expect(lifecycle.beginShutdown(signal: "SIGTERM"))
        #expect(await lifecycle.respond(.remote(confirmSeconds: nil)).result == .refused(.busy, Messages.busy))
        #expect(harness.rig.host.resolutions.isEmpty)   // nothing is entered on the way out
        let status = await lifecycle.respond(.status)
        #expect(status.result == .ok("") && status.state != nil)   // still answered
        #expect(harness.rig.events.all.contains(
            .init(name: "ipc.refused", fields: ["request": "remote", "reason": "shuttingDown"])))
        #expect(harness.rig.events.all.filter { $0.name == "ipc.request" }.map { $0.fields["request"] }
                == ["normal", "remote", "status"])   // every request is recorded, the refused one too
    }

    @Test func requestRefusedWhileShuttingDownIsShown() async {
        // B-3: the Dock applets show nothing themselves, so the refusal is a notice too (R83).
        let harness = Harness(CoordinatorRig())
        #expect(harness.lifecycle.beginShutdown(signal: "SIGTERM"))
        #expect(await harness.lifecycle.respond(.remote(confirmSeconds: nil)).result == .refused(.busy, Messages.busy))
        #expect(harness.rig.notifier.notices == [Messages.busy])
        _ = await harness.lifecycle.respond(.status)
        #expect(harness.rig.notifier.notices == [Messages.busy])   // status is answered, and shows nothing
    }

    @Test func shutdownForDisableEndsTheDaemonAndTakesNoMoreCommands() async {
        let harness = Harness(CoordinatorRig())
        let lifecycle = harness.lifecycle
        #expect(await lifecycle.respond(.shutdownForDisable).result == .ok(Messages.disabled))
        #expect(lifecycle.isShuttingDown && harness.calls.exitsAfterDisable == 1)
        #expect(await lifecycle.respond(.remote(confirmSeconds: 0)).result == .refused(.busy, Messages.busy))
        #expect(!lifecycle.beginShutdown(signal: "SIGTERM"))   // a signal meanwhile changes nothing
        #expect(harness.calls.exitsAfterDisable == 1)
    }

    // MARK: The disabled marker (R48b)

    @Test func disabledStartInNormalStopsStaleProcessesAndEndsClean() async {
        let harness = Harness(CoordinatorRig(persisted: .initial))
        await harness.lifecycle.runDisabled()
        #expect(harness.calls.staleStops.count == 1)
        #expect(harness.rig.coordinator.state.cleanShutdown)
        #expect(harness.rig.clock.elapsed == .zero)   // nothing to retry
        #expect(harness.rig.events.names.contains("disabled.begin") && harness.rig.events.names.contains("disabled.end"))
    }

    @Test func disabledStartRetriesTheWayBackEveryTwoSeconds() async {
        let harness = Harness(CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote()))
        let rig = harness.rig, backend = rig.backend, clock = rig.clock
        // The monitors cannot be turned on during the reconcile's 10 s wake window (A-2), but can by the retry.
        backend.rejectEnable = { _ in clock.elapsed < .seconds(10) }
        await harness.lifecycle.runDisabled()
        #expect(rig.clock.elapsed == .seconds(12))   // the reconcile's wake window, then 2 s to the retry
        #expect(rig.events.names.filter { $0 == "disabled.retry" }.count == 1)
        #expect(rig.coordinator.state.phase == .normal)
        #expect(backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(harness.calls.staleStops.count == 1 && harness.calls.staleStops.first?.phase == .normal)
        #expect(rig.coordinator.state.cleanShutdown)
    }

    @Test func disabledStartGivesUpAfterThirtySecondsWithoutStoppingStaleProcesses() async {
        let harness = Harness(CoordinatorRig(displays: monitorsLeftOff, persisted: crashedInRemote()))
        let rig = harness.rig
        rig.backend.failing[.enable] = FakeError.injected   // the monitors never turn on
        await harness.lifecycle.runDisabled()
        // Each way back waits out its 10 s wake window (A-2): after the reconcile's, a retry 2 s after each failure
        // while less than 30 s have passed since the reconcile, at 12, 24 and 36 s after the start.
        #expect(rig.clock.elapsed == .seconds(46))
        #expect(rig.events.names.filter { $0 == "disabled.retry" }.count == 3)
        #expect(rig.coordinator.state.phase == .exiting)
        #expect(harness.calls.staleStops.isEmpty)   // the stale display may be the only one left (R33)
        #expect(rig.coordinator.state.cleanShutdown)   // the next start reconciles anyway
        #expect(rig.events.names.contains("disabled.incomplete"))
    }

    // MARK: Signals (R50)

    @Test func signalReturnsToNormalThenMarksTheShutdownClean() async {
        let harness = Harness(await CoordinatorRig.started(inRemote: true))
        let rig = harness.rig, lifecycle = harness.lifecycle
        #expect(!rig.coordinator.state.cleanShutdown)
        #expect(lifecycle.beginShutdown(signal: "SIGTERM"))
        #expect(rig.events.all.contains(.init(name: "daemon.signal", fields: ["signal": "SIGTERM"])))
        await lifecycle.finishShutdown()
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.events.names.contains("exit.disable.begin"))
        #expect(rig.notifier.notices == [Messages.backToNormal])
        #expect(rig.coordinator.state.cleanShutdown && rig.store.saves.last?.cleanShutdown == true)
    }

    @Test func secondSignalIsIgnored() async {
        let harness = Harness(await CoordinatorRig.started(inRemote: true))
        let lifecycle = harness.lifecycle
        #expect(lifecycle.beginShutdown(signal: "SIGTERM"))
        #expect(!lifecycle.beginShutdown(signal: "SIGINT"))
        #expect(harness.rig.events.all.contains(.init(name: "daemon.signal.ignored", fields: ["signal": "SIGINT"])))
        #expect(harness.rig.events.names.filter { $0 == "daemon.signal" }.count == 1)
    }

    @Test func signalInNormalTouchesNoDisplay() async {
        let harness = Harness(await CoordinatorRig.started())
        #expect(harness.lifecycle.beginShutdown(signal: "SIGINT"))
        await harness.lifecycle.finishShutdown()
        #expect(harness.rig.backend.calls.isEmpty)
        #expect(harness.rig.coordinator.state.cleanShutdown)
    }

    @Test func signalWhoseReturnFailsStillMarksTheShutdownClean() async {
        let harness = Harness(await CoordinatorRig.started(inRemote: true))
        harness.rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on
        #expect(harness.lifecycle.beginShutdown(signal: "SIGTERM"))
        await harness.lifecycle.finishShutdown()
        // The virtual display stays (I1); once the daemon has exited 143, the vdisplay child (R25) and the watchdog
        // turn the monitors on, and the next start reconciles.
        #expect(harness.rig.coordinator.state.phase == .active(.remote))
        #expect(harness.rig.coordinator.state.cleanShutdown)
    }
}
