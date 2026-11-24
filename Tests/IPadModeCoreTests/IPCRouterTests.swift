import Testing
@testable import IPadModeCore

/// What the router is handed besides the Coordinator, and what it did with it.
@MainActor
private final class RouterPorts {
    var saved: [Config] = []
    var saveError: (any Error)?
    var shutdowns = 0
}

@MainActor
private func respond(_ request: IPCRequest, _ rig: CoordinatorRig, _ ports: RouterPorts = RouterPorts()) async
    -> IPCResponse {
    await IPCRouter.respond(request, coordinator: rig.coordinator, notifier: rig.notifier, events: rig.events,
                            listDisplays: { try rig.backend.listDisplays() },
                            saveConfig: { config in
                                if let error = ports.saveError { throw error }
                                ports.saved.append(config)
                            },
                            requestShutdown: { ports.shutdowns += 1 })
}

/// R49: the socket's requests, mapped onto the Coordinator.
@MainActor
struct IPCRouterTests {
    // MARK: Remote and Normal

    @Test func remoteWhileRemoteIsActiveIsOKAndShown() async {
        let rig = await CoordinatorRig.started(inRemote: true)
        let calls = rig.backend.calls
        let response = await respond(.remote(confirmSeconds: nil), rig)
        #expect(response.result == .ok(Messages.remoteAlreadyActive))
        #expect(Messages.remoteAlreadyActive == "Mode Remote iPad sudah aktif.")
        #expect(rig.notifier.notices == [Messages.remoteAlreadyActive])
        #expect(rig.backend.calls == calls && rig.host.resolutions.count == 1)   // nothing entered again
    }

    @Test func remoteEntersWithTheGivenWindowAndShowsNoNotice() async {
        let rig = CoordinatorRig(confirm: nil)
        let response = await respond(.remote(confirmSeconds: 120), rig)
        #expect(response.result == .ok(Messages.remoteEntered(seconds: 120)))
        #expect(rig.confirmer.requests == [120])   // the confirmation is the feedback
        #expect(rig.notifier.notices.isEmpty)
        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value
    }

    @Test func refusalsOfRemoteAndNormalAreShown() async {
        let locked = CoordinatorRig()
        locked.lock.isLocked = true
        #expect(await respond(.remote(confirmSeconds: nil), locked).result == .refused(.locked, Messages.locked))
        #expect(locked.notifier.notices == [Messages.locked])

        let headless = await CoordinatorRig.started(inRemote: true, displays: [])   // no monitor to go back to
        let response = await respond(.normal, headless)
        #expect(response.result == .refused(.noPhysicalMonitor, Messages.noPhysicalMonitor))
        #expect(headless.notifier.notices == [Messages.noPhysicalMonitor])
    }

    @Test func normalWhileNormalIsShown() async {
        let rig = await CoordinatorRig.started()
        let response = await respond(.normal, rig)
        #expect(response.result == .ok(Messages.backToNormal))
        #expect(rig.notifier.notices == [Messages.backToNormal])   // the Dock applet has no other feedback
        #expect(rig.backend.calls.isEmpty)
    }

    @Test func normalWhileNormalWithAMonitorThatStaysOffIsShownOnce() async {
        // A-5: the Coordinator tells that the P24 stayed off; the router adds no "Kembali ke Normal."
        let rig = CoordinatorRig(displays: [Fixtures.legion, Fixtures.off(Fixtures.p24)], persisted: .initial)
        rig.backend.rejectEnable = { $0.contains(Fixtures.p24.id) }
        let text = Messages.monitorStillOff("P24FBA-RAGL")
        #expect(await respond(.normal, rig).result == .ok(text))
        #expect(rig.notifier.notices == [text])
    }

    @Test func normalFromRemoteIsShownOnce() async {
        let rig = await CoordinatorRig.started(inRemote: true)
        #expect(await respond(.normal, rig).result == .ok(Messages.backToNormal))
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.backToNormal])   // the Coordinator's notice only
    }

    @Test func failuresAreNotShownAgain() async {
        let rig = await CoordinatorRig.started(inRemote: true)
        rig.backend.failing[.enable] = FakeError.injected
        #expect(await respond(.normal, rig).result == .failed(Messages.exitFailed))
        #expect(rig.notifier.notices == [Messages.exitFailed])   // told once, by the Coordinator

        let broken = CoordinatorRig()
        broken.host.startError = FakeError.injected
        #expect(await respond(.remote(confirmSeconds: nil), broken).result == .failed(Messages.virtualFailed))
        #expect(broken.notifier.notices == [Messages.virtualFailed])
    }

    // MARK: Sidecar and status

    @Test func sidecarIsUnsupported() async {
        let rig = CoordinatorRig()
        let response = await respond(.sidecar, rig)
        #expect(response == IPCResponse(result: .refused(.unsupported, Messages.sidecarUnsupported)))
        #expect(rig.notifier.notices.isEmpty)
        #expect(rig.backend.calls.isEmpty && rig.backend.listCount == 0)
    }

    @Test func statusReportsTheStateAndTheDisplays() async {
        let rig = await CoordinatorRig.started(inRemote: true)
        let response = await respond(.status, rig)
        #expect(response.result == .ok(""))
        #expect(response.state == rig.coordinator.state && response.state?.phase == .active(.remote))
        #expect(response.displays == rig.backend.displays)

        rig.backend.failing[.listDisplays] = FakeError.injected
        let blind = await respond(.status, rig)
        #expect(blind.result == .ok("") && blind.state != nil && blind.displays == nil)
        #expect(rig.notifier.notices.isEmpty)
    }

    // MARK: Resolution

    @Test func invalidResolutionIsRefused() async {
        let rig = CoordinatorRig()
        let ports = RouterPorts()
        let response = await respond(.resolution("800x600"), rig, ports)
        #expect(response.result == .refused(.invalid, Messages.resolutionInvalid))
        #expect(ports.saved.isEmpty)
        #expect(rig.coordinator.config.remote.resolution == "1180x820")
    }

    @Test func validResolutionIsSet() async throws {
        let rig = CoordinatorRig()
        let ports = RouterPorts()
        let resolution = try #require(Resolution(parsing: "1321x918"))
        let response = await respond(.resolution("1321x918"), rig, ports)
        #expect(response.result == .ok(Messages.resolutionSet(resolution)))
        #expect(ports.saved.map(\.remote.resolution) == ["1321x918"])   // the new value is saved
        #expect(rig.coordinator.config.remote.resolution == "1321x918")
    }

    @Test func resolutionThatCannotBeSavedIsStillSet() async throws {
        let rig = CoordinatorRig()
        let ports = RouterPorts()
        ports.saveError = FakeError.injected
        let resolution = try #require(Resolution(parsing: "1416x984"))
        #expect(await respond(.resolution("1416x984"), rig, ports).result == .ok(Messages.resolutionSet(resolution)))
        #expect(rig.events.all.contains(.init(name: "config.save.failed", fields: ["error": "injected"])))
        #expect(rig.coordinator.config.remote.resolution == "1416x984")   // in effect until the next start (R5)
    }

    @Test func refusedResolutionIsNotSaved() async {
        let rig = CoordinatorRig(confirm: nil)
        _ = await rig.coordinator.enterRemote()   // the confirmation is showing: busy
        let ports = RouterPorts()
        #expect(await respond(.resolution("1321x918"), rig, ports).result == .refused(.busy, Messages.busy))
        #expect(ports.saved.isEmpty)
        rig.confirmer.resolve(.keep)
        await rig.coordinator.pendingConfirmation?.value
    }

    // MARK: Shutdown for disable

    @Test func shutdownForDisableFromRemoteReturnsToNormalFirst() async {
        let rig = await CoordinatorRig.started(inRemote: true)
        let ports = RouterPorts()
        let response = await respond(.shutdownForDisable, rig, ports)
        #expect(response.result == .ok(Messages.disabled))
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.events.names.contains("exit.disable.begin"))
        #expect(rig.coordinator.state.cleanShutdown && rig.store.saves.last?.cleanShutdown == true)
        #expect(ports.shutdowns == 1)
    }

    @Test func shutdownForDisableInNormalMarksTheShutdownClean() async {
        let rig = await CoordinatorRig.started()
        let ports = RouterPorts()
        #expect(!rig.coordinator.state.cleanShutdown)   // running: a crash would count
        #expect(await respond(.shutdownForDisable, rig, ports).result == .ok(Messages.disabled))
        #expect(rig.coordinator.state.cleanShutdown && rig.store.saves.last?.cleanShutdown == true)
        #expect(ports.shutdowns == 1)
        #expect(rig.backend.calls.isEmpty)
    }

    @Test func shutdownForDisableWhoseReturnFailsDoesNotShutDown() async {
        let rig = await CoordinatorRig.started(inRemote: true)
        rig.backend.failing[.enable] = FakeError.injected   // the monitors will not turn on
        let ports = RouterPorts()
        #expect(await respond(.shutdownForDisable, rig, ports).result == .failed(Messages.exitFailed))
        #expect(ports.shutdowns == 0)
        #expect(!rig.coordinator.state.cleanShutdown)
        #expect(rig.coordinator.state.phase == .active(.remote))   // the virtual display stays (I1)
    }

    @Test func shutdownForDisableGoesAheadWhenTheCleanMarkCannotBeSaved() async {
        let rig = await CoordinatorRig.started()
        rig.store.saveFailure = { _ in FakeError.injected }
        let ports = RouterPorts()
        #expect(await respond(.shutdownForDisable, rig, ports).result == .ok(Messages.disabled))
        #expect(rig.events.all.contains(.init(name: "daemon.clean.failed", fields: ["error": "injected"])))
        #expect(ports.shutdowns == 1)   // the marker makes the next start reconcile and exit anyway
    }

    // MARK: Events

    @Test func everyRequestIsRecordedByItsCaseNameOnly() async {
        let rig = CoordinatorRig()
        let requests: [(IPCRequest, String)] = [
            (.status, "status"), (.sidecar, "sidecar"), (.resolution("bogus"), "resolution"),
            (.normal, "normal"), (.remote(confirmSeconds: 0), "remote"), (.shutdownForDisable, "shutdownForDisable"),
        ]
        for (request, _) in requests { _ = await respond(request, rig) }
        let recorded = rig.events.all.filter { $0.name == "ipc.request" }
        #expect(recorded == requests.map { .init(name: "ipc.request", fields: ["request": $0.1]) })
    }
}
