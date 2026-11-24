import Testing
@testable import IPadModeCore

/// R69: one monitor that cannot be enabled must not keep the others off.
@MainActor @Suite struct EnableMonitorsTests {
    private let both = [Fixtures.legion.id, Fixtures.p24.id]

    @Test func acceptedBatchIsOneTransaction() {
        let backend = FakeDisplayBackend([Fixtures.off(Fixtures.legion), Fixtures.off(Fixtures.p24)])
        var failures: [[DisplayID]] = []

        let accepted = backend.enableMonitors(both, scope: .session) { ids, _ in failures.append(ids) }

        #expect(accepted == both)
        #expect(failures.isEmpty)
        #expect(backend.calls == ["setEnabled([1, 3],true)"])
        #expect(backend.scopes == [.session])
    }

    @Test func failedBatchIsTriedOneMonitorAtATime() {
        let backend = FakeDisplayBackend([Fixtures.off(Fixtures.legion), Fixtures.off(Fixtures.p24)])
        backend.rejectEnable = { $0.count > 1 }   // the batch fails, each monitor alone is accepted
        var failures: [[DisplayID]] = []

        let accepted = backend.enableMonitors(both, scope: .session) { ids, _ in failures.append(ids) }

        #expect(accepted == both)
        #expect(failures == [both])
        #expect(backend.calls == ["setEnabled([1, 3],true)", "setEnabled([1],true)", "setEnabled([3],true)"])
        #expect(backend.displays.allSatisfy { $0.isOnline })
    }

    @Test func monitorThatCannotBeEnabledDoesNotKeepTheOthersOff() {
        let backend = FakeDisplayBackend([Fixtures.off(Fixtures.legion), Fixtures.off(Fixtures.p24)])
        backend.rejectEnable = { $0.contains(Fixtures.p24.id) }
        var failures: [[DisplayID]] = []

        let accepted = backend.enableMonitors(both, scope: .session) { ids, _ in failures.append(ids) }

        #expect(accepted == [Fixtures.legion.id])
        #expect(failures == [both, [Fixtures.p24.id]])
        #expect(backend.displays.first { $0.id == Fixtures.legion.id }?.isOnline == true)
        #expect(backend.displays.first { $0.id == Fixtures.p24.id }?.isOnline == false)
    }

    @Test func singleMonitorIsNotTriedTwice() {
        let backend = FakeDisplayBackend([Fixtures.off(Fixtures.p24)])
        backend.failing[.enable] = FakeError.injected
        var failures: [[DisplayID]] = []

        let accepted = backend.enableMonitors([Fixtures.p24.id], scope: .session) { ids, _ in failures.append(ids) }

        #expect(accepted.isEmpty)
        #expect(failures == [[Fixtures.p24.id]])
        #expect(backend.calls.count == 1)
    }

    @Test func nothingToEnableMakesNoCall() {
        let backend = FakeDisplayBackend([Fixtures.legion])
        #expect(backend.enableMonitors([], scope: .session) { _, _ in Issue.record("no failure expected") }.isEmpty)
        #expect(backend.calls.isEmpty)
    }
}
