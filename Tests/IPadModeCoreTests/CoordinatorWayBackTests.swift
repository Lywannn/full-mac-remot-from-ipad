import Testing
@testable import IPadModeCore

private let virtualID = Fixtures.virtualRemote.id
private let legionID = Fixtures.legion.id
private let p24ID = Fixtures.p24.id

/// The way back's step 2 judged by the display listing (A-2). On hardware a monitor that is on or waking already makes
/// an enable fail (1001), the whole batch with it, and a monitor waking from standby may show online but dark, drop out
/// of the listing, and come up lit only 2–4 s later.
@MainActor
struct CoordinatorWayBackTests {
    // MARK: A-2: step 2 is decided by the listing

    @Test func monitorsTurnedOnElsewhereAreNoFailure() async {
        // S9: another process turned both monitors back on while the mode ran. As they wake, they are listed off,
        // then online but dark (the P24 drops out of the listing for a moment), then lit; asked to turn on again,
        // CoreGraphics refuses (1001).
        let rig = await CoordinatorRig.inRemote()
        rig.backend.wakeSteps = [legionID: [.offline, .onlineDark, .onlineDark], p24ID: [.offline, .missing, .onlineDark]]
        rig.backend.turnOnElsewhere([legionID, p24ID])
        let before = rig.clock.elapsed
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(!rig.events.names.contains("exit.failed"))
        // Planned from a listing that shows them off: asked for, refused as a batch and one by one...
        #expect(Array(rig.backend.calls.filter { $0.hasSuffix(",true)") }.prefix(3))
                == ["setEnabled([1, 3],true)", "setEnabled([1],true)", "setEnabled([3],true)"])
        #expect(rig.events.all.contains(.init(name: "physical.enable.failed", fields: ["ids": "1,3", "error": "alreadyOn"])))
        // ...and judged by the listing: lit 0.2 s later, so the virtual display went then.
        #expect(rig.clock.elapsed - before == .milliseconds(200))
        #expect(rig.events.names.contains("physical.enabled"))
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
        #expect(rig.notifier.notices == [Messages.backToNormal])
    }

    @Test func monitorMissingForASecondWhileItWakesIsWaitedFor() async throws {
        // The P24 was turned on elsewhere just before: listed off at first, so the batch naming it is refused (1001),
        // and then missing from the listing for 1.1 s before it comes up lit.
        let rig = await CoordinatorRig.inRemote()
        rig.backend.wakeSteps = [p24ID: [.offline] + Array(repeating: .missing, count: 12)]
        rig.backend.turnOnElsewhere([p24ID])
        let before = rig.clock.elapsed
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        // The Legion was turned on alone, and the P24, missing meanwhile, was asked for again a second later.
        #expect(rig.backend.calls.filter { $0.hasSuffix(",true)") }
                == ["setEnabled([1, 3],true)", "setEnabled([1],true)", "setEnabled([3],true)", "setEnabled([3],true)"])
        // Waited for it although the Legion was lit at once: a known monitor missing from the listing is not back.
        #expect(rig.clock.elapsed - before == .milliseconds(1200))
        let stop = try #require(rig.backend.calls.firstIndex(of: "stop(remote)"))
        #expect(rig.backend.history[stop - 1].filter { $0.kind == .physical }.allSatisfy { $0.isOnline && $0.isActive })
        #expect(!rig.events.names.contains("exit.failed"))
        #expect(rig.backend.displays == [Fixtures.legion, Fixtures.p24])
    }

    @Test func monitorThatNeverComesBackStillEndsInNormalWhileAnotherIsLit() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.rejectEnable = { $0.contains(p24ID) }   // the P24 cannot be turned on
        let before = rig.clock.elapsed
        let result = await rig.coordinator.exitToNormal(.user)
        // The whole wake window, the P24 asked for again every second; then Normal, since the Legion is lit (I1).
        #expect(rig.clock.elapsed - before == .seconds(10))
        #expect(rig.backend.calls.filter { $0 == "setEnabled([3],true)" }.count == 10)
        #expect(rig.events.names.contains("physical.enable.timeout"))
        #expect(!rig.events.names.contains("exit.failed"))
        guard case .ok = result else { Issue.record("expected Normal, got \(result)"); return }
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [legionID])
        #expect(!rig.backend.displays.contains { $0.id == virtualID })
        // A-5: and it says so, rather than "Kembali ke Normal."
        let text = Messages.monitorStillOff("P24FBA-RAGL")
        #expect(result == .ok(text))
        #expect(rig.notifier.notices == [text])
    }

    // MARK: A-5: a monitor left off

    @Test func monitorLeftOffIsAskedForAgainEveryTenSecondsAtMostThreeTimes() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.rejectEnable = { $0.contains(p24ID) }   // the P24 cannot be turned on
        _ = await rig.coordinator.exitToNormal(.user)     // Normal, with the P24 still off
        let backend = rig.backend
        func asked() -> Int { backend.calls.filter { $0 == "setEnabled([3],true)" }.count }
        let byTheWayBack = asked()
        for _ in 1...9 {
            rig.clock.advance(by: .seconds(1))
            await rig.coordinator.handle(.tick)
        }
        #expect(asked() == byTheWayBack)
        rig.clock.advance(by: .seconds(1))   // 10 s after the way back
        await rig.coordinator.handle(.tick)
        #expect(asked() == byTheWayBack + 1)
        for _ in 1...40 {
            rig.clock.advance(by: .seconds(1))
            await rig.coordinator.handle(.tick)
        }
        #expect(asked() == byTheWayBack + 3)   // at 10, 20 and 30 s, then no more
        #expect(rig.coordinator.state.phase == .normal)
        #expect(rig.notifier.notices == [Messages.monitorStillOff("P24FBA-RAGL")])   // told once
    }

    @Test func monitorThatComesOnEndsTheRetries() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.rejectEnable = { $0.contains(p24ID) }
        _ = await rig.coordinator.exitToNormal(.user)
        rig.backend.rejectEnable = nil   // from now on the P24 can be turned on
        let backend = rig.backend
        let calls = backend.calls.count
        for _ in 1...40 {
            rig.clock.advance(by: .seconds(1))
            await rig.coordinator.handle(.tick)
        }
        #expect(Array(backend.calls[calls...]) == ["setEnabled([3],true)"])   // the first retry brought it back
        #expect(backend.displays.allSatisfy { $0.kind != .physical || ($0.isOnline && $0.isActive) })
    }

    @Test func normalWhileNormalTurnsAnOfflineMonitorBackOn() async {
        // Something left the P24 off while the Mac is in Normal.
        let rig = CoordinatorRig(displays: [Fixtures.legion, Fixtures.off(Fixtures.p24)])
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.backend.calls == ["setEnabled([3],true)"])
        #expect(rig.backend.displays.allSatisfy { $0.isOnline && $0.isActive })
        #expect(rig.coordinator.state.phase == .normal && rig.store.saves.isEmpty)   // Normal all along
        #expect(rig.notifier.notices.isEmpty)   // the router answers the click (R49)

        // The hotkey does the same.
        let hotkey = CoordinatorRig(displays: [Fixtures.off(Fixtures.legion), Fixtures.p24])
        #expect(await hotkey.coordinator.exitToNormal(.hotkey) == .ok(Messages.backToNormal))
        #expect(hotkey.backend.calls == ["setEnabled([1],true)"])

        // Every other return finds Normal, and looks at nothing.
        let locked = CoordinatorRig(displays: [Fixtures.legion, Fixtures.off(Fixtures.p24)])
        #expect(await locked.coordinator.exitToNormal(.locked) == .ok(Messages.backToNormal))
        #expect(locked.backend.calls.isEmpty && locked.backend.listCount == 0)
    }

    @Test func normalWhileNormalWithAMonitorThatStaysOffSaysSoAndTriesAgain() async {
        let rig = CoordinatorRig(displays: [Fixtures.legion, Fixtures.off(Fixtures.p24)])
        rig.backend.rejectEnable = { $0.contains(p24ID) }
        let text = Messages.monitorStillOff("P24FBA-RAGL")
        #expect(await rig.coordinator.exitToNormal(.user) == .ok(text))   // the Legion is lit: Normal is fine (I1)
        #expect(rig.clock.elapsed == .seconds(10))   // the wake window
        #expect(rig.notifier.notices == [text])
        rig.backend.rejectEnable = nil
        rig.clock.advance(by: .seconds(10))
        await rig.coordinator.handle(.tick)
        #expect(rig.backend.displays.allSatisfy { $0.isOnline && $0.isActive })   // the retry it left owed
    }

    @Test func normalWhileNormalIsOneTransitionAtATime() async {
        let rig = CoordinatorRig(displays: [Fixtures.legion, Fixtures.off(Fixtures.p24)])
        let coordinator = rig.coordinator
        rig.backend.enableDelay = 3   // the P24 takes two more polls to wake
        rig.clock.duringNextSleep {   // while it wakes, Remote is refused and a second Normal joins
            #expect(await coordinator.enterRemote() == .refused(.busy, Messages.busy))
        }
        #expect(await coordinator.exitToNormal(.user) == .ok(Messages.backToNormal))
        #expect(rig.backend.calls == ["setEnabled([3],true)"])
        #expect(rig.host.resolutions.isEmpty)
    }

    @Test func hotkeyUnavailableText() {
        // B-11
        #expect(Messages.hotkeyUnavailable == "Hotkey ⌃⌥⌘N tidak bisa didaftarkan — pakai tombol Layar Normal.")
    }

    @Test func monitorStillOffText() {
        #expect(Messages.monitorStillOff("P24FBA-RAGL") == "Monitor P24FBA-RAGL belum menyala — coba Layar Normal lagi.")
    }

    @Test func noMonitorLitAtTheDeadlineKeepsTheVirtualDisplay() async {
        let rig = await CoordinatorRig.inRemote()
        rig.backend.wakeSteps = [legionID: Array(repeating: .onlineDark, count: 200),
                                 p24ID: Array(repeating: .onlineDark, count: 200)]
        // Both turn on, but stay dark past the wake window: Normal would show nothing (I1).
        #expect(await rig.coordinator.exitToNormal(.user) == .failed(Messages.exitFailed))
        #expect(rig.backend.displays.filter(\.isActive).map(\.id) == [virtualID])
        #expect(!rig.backend.calls.contains("stop(remote)"))
        #expect(rig.coordinator.state.lastError == "monitorsNotActive")
        #expect(rig.coordinator.state.phase == .active(.remote))
    }
}

/// The fake backend behaves like CoreGraphics where step 2 relies on it.
@MainActor
struct FakeWakeFidelityTests {
    @Test func enablingAMonitorThatIsOnFailsAsAWhole() {
        let backend = FakeDisplayBackend([Fixtures.legion, Fixtures.off(Fixtures.p24)])
        #expect(throws: FakeError.alreadyOn) {
            try backend.setEnabled([legionID, p24ID], enabled: true, scope: .session)
        }
        #expect(backend.displays == [Fixtures.legion, Fixtures.off(Fixtures.p24)])   // nothing changed
        #expect(backend.calls == ["setEnabled([1, 3],true)"])
    }

    @Test func aWakingMonitorFlickersAndCountsAsOn() throws {
        let backend = FakeDisplayBackend([Fixtures.legion, Fixtures.off(Fixtures.p24)])
        backend.wakeSteps = [p24ID: [.onlineDark, .missing]]
        try backend.setEnabled([p24ID], enabled: true, scope: .session)
        #expect(throws: FakeError.alreadyOn) { try backend.setEnabled([p24ID], enabled: true, scope: .session) }
        let dark = try backend.listDisplays().first { $0.id == p24ID }
        #expect(dark?.isOnline == true && dark?.isActive == false)
        #expect(try backend.listDisplays().contains { $0.id == p24ID } == false)
        let lit = try backend.listDisplays().first { $0.id == p24ID }
        #expect(lit?.isOnline == true && lit?.isActive == true)
    }

    @Test func askingAgainWhileItWakesDoesNotStartTheWakeOver() throws {
        let backend = FakeDisplayBackend([Fixtures.off(Fixtures.p24)])
        backend.enableDelay = 3
        try backend.setEnabled([p24ID], enabled: true, scope: .session)
        _ = try backend.listDisplays()
        try backend.setEnabled([p24ID], enabled: true, scope: .session)   // offline still: accepted
        _ = try backend.listDisplays()
        #expect(try backend.listDisplays().first?.isActive == true)   // the third list, as without the second request
    }
}
