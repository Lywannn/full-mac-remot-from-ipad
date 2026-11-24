import Foundation
import Testing
@testable import IPadModeCore

@MainActor private final class FakeSignaller: WatchdogSignaller {
    var ownPID: Int32 = 4242
    var alive: Set<Int32> = []
    var paths: [Int32: String] = [:]
    var dieOnTerm = true
    var clock: UInt64 = 100_000_000_000
    /// Time the Mac spent asleep: CLOCK_MONOTONIC counted it, CLOCK_UPTIME_RAW did not.
    var slept: UInt64 = 0
    var sleepAdvancesClock = true
    var onSend: ((Int32, Int32) -> Void)?
    private(set) var sent: [(signal: Int32, pid: Int32)] = []
    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
    func executablePath(_ pid: Int32) -> String? { paths[pid] }
    func send(_ signal: Int32, to pid: Int32) { sent.append((signal, pid)); if dieOnTerm { alive.remove(pid) }; onSend?(signal, pid) }
    func nowNanos() -> UInt64 { clock }
    func uptimeNanos() -> UInt64 { clock - slept }
    func sleep(_ d: Duration) async {
        if sleepAdvancesClock {
            let c = d.components
            clock += UInt64(c.seconds) * 1_000_000_000 + UInt64(c.attoseconds / 1_000_000_000)
        }
    }
}

@MainActor private struct Rig {
    let paths: Paths
    let backend: FakeDisplayBackend
    let sig = FakeSignaller()
    let sink = FakeEventSink()
    let runner: WatchdogRunner

    init(_ displays: [DisplayInfo], phase: Phase = .active(.remote), baseline: Snapshot? = nil) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
        paths = Paths(support: dir, logs: dir.appendingPathComponent("logs"))
        backend = FakeDisplayBackend(displays)
        runner = WatchdogRunner(paths: paths, backend: backend, signaller: sig, log: sink, config: Config())
        var st = PersistedState.initial
        st.phase = phase; st.target = Fixtures.virtualRemote.id; st.baseline = baseline
        try? FileStateStore(url: paths.state).save(st)
    }

    /// A daemon heartbeat `age` seconds old at the signaller's current clock.
    func beat(pid: Int32, age: UInt64, path: String? = "/usr/local/bin/ipadmode", alive: Bool = true) {
        try? Heartbeat(pid: pid, monotonicNanos: sig.clock - age * 1_000_000_000).write(paths.heartbeat)
        if alive { sig.alive.insert(pid) }
        sig.paths[pid] = path
    }

    /// One tick, so that the watchdog's start window (B-1) begins; then `staleAfter` (5 s) passes.
    func primed() async {
        _ = await runner.tick()
        sig.clock += 5_000_000_000
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func incident() -> WatchdogFiles.Incident? {
        guard let d = try? Data(contentsOf: paths.incident) else { return nil }
        return try? WatchdogFiles.decoder().decode(WatchdogFiles.Incident.self, from: d)
    }
}

private let baseline = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])

@MainActor @Test func restoreWaitsForMonitorsBeforeSettingOrigins() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion), Fixtures.off(Fixtures.p24)], baseline: baseline)
    rig.backend.enableDelay = 3
    #expect(await rig.runner.tick() == .continue)
    #expect(rig.backend.calls.filter { $0.hasPrefix("setEnabled") }.count == 1)
    #expect(rig.backend.scopes.allSatisfy { $0 == .session })
    #expect(rig.backend.originRequests.count == 1)
    #expect(Set(rig.backend.originRequests[0].keys) == [Fixtures.legion.id, Fixtures.p24.id])
    #expect(rig.backend.displays.filter { $0.kind == .physical }.allSatisfy { $0.isOnline })
    #expect(rig.backend.displays.first { $0.id == Fixtures.legion.id }?.origin == Point(x: 0, y: 0))
    let inc = rig.incident()
    #expect(inc?.enabledOK == true)
    #expect(inc?.layoutOK == true)
    #expect(inc?.reason == "daemonDead")
    #expect(inc?.disabled.sorted() == ["Legion 34W-2c", "P24FBA-RAGL"])
}

@MainActor @Test func restoreSkipsLayoutWhenMonitorsNeverComeUp() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.backend.enableDelay = 1000
    _ = await rig.runner.tick()
    #expect(rig.backend.originRequests.isEmpty)
    #expect(rig.sink.names.contains("watchdog.layout.skipped"))
    #expect(rig.incident()?.layoutOK == false)
    #expect(rig.incident()?.enabledOK == true)
}

@MainActor @Test func killOnlyDuringCoolDownTouchesNothingElse() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.backend.enableDelay = 3
    rig.sig.dieOnTerm = false                // tick 1 is long: SIGTERM, 3 s, SIGKILL
    rig.beat(pid: 777, age: 8)
    await rig.primed()
    let start = rig.sig.clock
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.map(\.signal) == [SIGTERM, SIGKILL])
    #expect(rig.sig.clock - start > 3_000_000_000)
    let incidentBefore = try? Data(contentsOf: rig.paths.incident)
    let setEnabledBefore = rig.backend.calls.filter { $0.hasPrefix("setEnabled") }.count

    // 1 s after the end of the long tick the daemon is back, hung again, and the monitor is off again.
    rig.sig.clock += 1_000_000_000
    rig.sig.dieOnTerm = true
    rig.beat(pid: 777, age: 8)
    rig.backend.displays = rig.backend.displays.map { $0.id == Fixtures.legion.id ? Fixtures.off($0) : $0 }
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.map(\.signal) == [SIGTERM, SIGKILL, SIGTERM])   // killed at once, no blackout
    #expect(rig.backend.calls.filter { $0.hasPrefix("setEnabled") }.count == setEnabledBefore)
    let incidentAfter = try? Data(contentsOf: rig.paths.incident)
    #expect(incidentAfter == incidentBefore)
    #expect(rig.sink.names.filter { $0 == "watchdog.restore" }.count == 1)
}

@MainActor @Test func hungDaemonIsStillKilledWhenMonitorsNeverWake() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.backend.enableDelay = 1000
    rig.beat(pid: 777, age: 8)
    await rig.primed()
    let start = rig.sig.clock
    _ = await rig.runner.tick()
    #expect(rig.sig.clock - start >= 10_000_000_000)   // the whole 10 s wait
    #expect(rig.sig.sent.map(\.signal) == [SIGTERM])
    rig.sig.clock += 1_000_000_000
    rig.beat(pid: 777, age: 8)                           // the daemon is back and hung again
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.map(\.signal) == [SIGTERM, SIGTERM])
}

@MainActor @Test func failedEnableIsReportedAndDoesNotWait() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.backend.failing[.enable] = FakeError.injected
    _ = await rig.runner.tick()
    let inc = rig.incident()
    #expect(inc?.enabledOK == false)
    #expect(inc?.layoutOK == false)
    #expect(rig.backend.listCount <= 3)      // tick list, one loop list, final list: no 10 s wait
    #expect(rig.backend.originRequests.isEmpty)
}

@MainActor @Test func restoreEnablesEachMonitorAloneAfterTheBatchFails() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion), Fixtures.off(Fixtures.p24)], baseline: baseline)
    rig.backend.rejectEnable = { $0.count > 1 }   // the batch fails, each monitor alone is accepted
    _ = await rig.runner.tick()
    #expect(rig.backend.calls.filter { $0.hasPrefix("setEnabled") }
            == ["setEnabled([1, 3],true)", "setEnabled([1],true)", "setEnabled([3],true)"])
    #expect(rig.backend.displays.filter { $0.kind == .physical }.allSatisfy { $0.isOnline && $0.isActive })
    #expect(rig.incident()?.enabledOK == true)
    #expect(rig.incident()?.layoutOK == true)
    #expect(rig.sink.names.filter { $0 == "watchdog.restoreFailed" }.count == 1)   // the batch, logged
}

@MainActor @Test func monitorThatCannotBeEnabledDoesNotKeepTheOthersOff() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion), Fixtures.off(Fixtures.p24)], baseline: baseline)
    rig.backend.rejectEnable = { $0.contains(Fixtures.p24.id) }
    _ = await rig.runner.tick()
    #expect(rig.backend.displays.first { $0.id == Fixtures.legion.id }?.isActive == true)
    #expect(rig.backend.displays.first { $0.id == Fixtures.p24.id }?.isOnline == false)
    #expect(rig.incident()?.enabledOK == false)
    #expect(rig.incident()?.layoutOK == true)          // Legion was waited for, then laid out
    #expect(rig.backend.listCount <= 4)                 // no 10 s wait for the monitor that stays off
    let failed = rig.sink.all.filter { $0.name == "watchdog.restoreFailed" }.map { $0.fields["ids"] }
    #expect(failed == ["1,3", "3"])
}

@MainActor @Test func skippedLayoutIsRetriedOnceTheCoolDownExpired() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.backend.enableDelay = 1000
    _ = await rig.runner.tick()
    #expect(rig.incident()?.layoutOK == false)
    #expect(rig.backend.originRequests.isEmpty)
    rig.sig.clock += 1_000_000_000
    rig.backend.enableDelay = 0              // the monitor wakes up this time
    _ = await rig.runner.tick()
    #expect(rig.backend.calls.filter { $0.hasPrefix("setEnabled") }.count == 2)
    #expect(rig.backend.originRequests.count == 1)
    #expect(rig.incident()?.layoutOK == true)
}

@MainActor @Test func sigkillIsSkippedWhenThePidNoLongerBelongsToUs() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)])
    rig.sig.dieOnTerm = false
    rig.sig.onSend = { [sig = rig.sig] signal, pid in
        if signal == SIGTERM { sig.paths[pid] = "/usr/bin/reused-pid" }
    }
    rig.beat(pid: 777, age: 8)
    await rig.primed()
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.map(\.signal) == [SIGTERM])
    #expect(rig.sink.names.contains("watchdog.kill.skipped"))
}

@MainActor @Test func longRestoreKeepsTheBreadcrumbFilesFresh() async throws {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.backend.enableDelay = 1000
    var beats: [UInt64] = []
    rig.backend.onList = { [paths = rig.paths] in
        if let hb = Heartbeat.read(paths.watchdogHeartbeat) { beats.append(hb.monotonicNanos) }
    }
    _ = await rig.runner.tick()
    #expect(Set(beats).count > 1)            // rewritten during the wait, not only at the end
}

@MainActor @Test func sigkillFollowsWhenDaemonIgnoresSigterm() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)])
    rig.sig.dieOnTerm = false
    rig.beat(pid: 777, age: 8)
    await rig.primed()
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.map(\.signal) == [SIGTERM, SIGKILL])
}

@MainActor @Test func listFailureWritesNothingAndActsOnNothing() async throws {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)])
    try WatchdogFiles.writeDisplays([Fixtures.legion], at: Date(timeIntervalSince1970: 5), to: rig.paths.displays)
    let before = try Data(contentsOf: rig.paths.displays)
    rig.backend.failing[.listDisplays] = FakeError.injected
    #expect(await rig.runner.tick() == .continue)
    #expect(try Data(contentsOf: rig.paths.displays) == before)
    #expect(rig.sink.names == ["watchdog.list.failed"])
    #expect(rig.backend.calls.isEmpty)
    #expect(Heartbeat.read(rig.paths.watchdogHeartbeat)?.pid == 4242)
}

@MainActor @Test func tickWritesDisplaysAndMonotonicHeartbeat() async throws {
    let rig = Rig([Fixtures.legion])
    rig.beat(pid: 777, age: 1)
    #expect(await rig.runner.tick() == .continue)
    let file = try WatchdogFiles.decoder().decode(WatchdogFiles.DisplaysFile.self,
                                                  from: Data(contentsOf: rig.paths.displays))
    #expect(file.displays == [Fixtures.legion])
    #expect(Heartbeat.read(rig.paths.watchdogHeartbeat)?.pid == 4242)
    #expect(rig.incident() == nil)
}

@MainActor @Test func daemonThatIsNotOurBinaryIsNeverSignalled() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)])
    rig.beat(pid: 777, age: 8, path: "/usr/bin/someone-else")
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.isEmpty)
    #expect(rig.sink.names.contains("watchdog.kill.skipped"))
    #expect(rig.sink.names.contains("watchdog.restore"))   // treated as dead: monitors still come back
}

@MainActor @Test func ownPIDAndLowPIDsAreNeverSignalled() async {
    for pid: Int32 in [4242, 1, 0] {
        let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)])
        rig.beat(pid: pid, age: 8)
        _ = await rig.runner.tick()
        #expect(rig.sig.sent.isEmpty)
        #expect(rig.sink.names.contains("watchdog.kill.skipped"))
    }
}

@MainActor @Test func disabledMarkerExitsOnceRestored() async {
    let rig = Rig([Fixtures.legion], phase: .normal)
    FileManager.default.createFile(atPath: rig.paths.disabledMarker.path, contents: Data())
    #expect(await rig.runner.tick() == .exit)
    #expect(rig.sink.names == ["watchdog.exitDisabled"])
}

@Test func watchdogFilesRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
    let t = Date(timeIntervalSince1970: 1_000)
    try WatchdogFiles.writeDisplays([Fixtures.legion, Fixtures.p24], at: t, to: dir.appendingPathComponent("d.json"))
    let d = try WatchdogFiles.decoder().decode(WatchdogFiles.DisplaysFile.self,
                                               from: Data(contentsOf: dir.appendingPathComponent("d.json")))
    #expect(d == .init(time: t, displays: [Fixtures.legion, Fixtures.p24]))
    let inc = WatchdogFiles.Incident(time: t, reason: "daemonDead", disabled: ["A"], enabledOK: true, layoutOK: false)
    try WatchdogFiles.writeIncident(inc, to: dir.appendingPathComponent("i.json"))
    #expect(try WatchdogFiles.decoder().decode(WatchdogFiles.Incident.self,
                                               from: Data(contentsOf: dir.appendingPathComponent("i.json"))) == inc)
}

@MainActor @Test func heartbeatWrittenDuringTheListIsNeverFutureDated() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.beat(pid: 777, age: 1)
    // The daemon's heartbeat lands while the (slow) display list runs.
    rig.backend.onList = { [rig] in
        rig.sig.clock += 3_000_000_000
        try? Heartbeat(pid: 777, monotonicNanos: rig.sig.clock).write(rig.paths.heartbeat)
    }
    for _ in 0..<4 { _ = await rig.runner.tick() }
    #expect(rig.sig.sent.isEmpty)
    #expect(!rig.sink.names.contains("watchdog.restore"))
    #expect(rig.backend.calls.isEmpty)
}

@MainActor @Test func resumeFromSleepDoesNotKillTheDaemon() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.beat(pid: 777, age: 1)
    _ = await rig.runner.tick()
    rig.sig.clock += 3_600_000_000_000; rig.sig.slept += 3_600_000_000_000   // an hour asleep
    rig.beat(pid: 777, age: 3600)
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.isEmpty)
    #expect(!rig.sink.names.contains("watchdog.restore"))
}

// B-1: a watchdog that starts gives the daemon `staleAfter` to beat

@MainActor @Test func freshlyStartedWatchdogDoesNotKillAtOnce() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.beat(pid: 777, age: 8)   // launchd restarted the watchdog at wake: the heartbeat is old from the sleep
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.isEmpty && !rig.sink.names.contains("watchdog.restore"))
    rig.sig.clock += 5_000_000_000
    rig.beat(pid: 777, age: 8)   // still no beat 5 s later: hung
    _ = await rig.runner.tick()
    #expect(rig.sig.sent.first?.signal == SIGTERM)
}

// B-7: a restore whose enable failed for every monitor starts no cool-down

@MainActor @Test func restoreWhoseEnableFailedIsTriedAgainWithoutTheCoolDown() async {
    let rig = Rig([Fixtures.virtualRemote, Fixtures.off(Fixtures.legion)], baseline: baseline)
    rig.backend.failing[.enable] = FakeError.injected   // the daemon is dead, and the monitor refuses to turn on
    _ = await rig.runner.tick()
    rig.sig.clock += 1_000_000_000
    _ = await rig.runner.tick()
    #expect(rig.sink.names.filter { $0 == "watchdog.restore" }.count == 2)
    rig.backend.failing[.enable] = nil
    rig.sig.clock += 1_000_000_000
    _ = await rig.runner.tick()   // accepted this time: it is on now
    rig.sig.clock += 1_000_000_000
    rig.backend.displays = rig.backend.displays.map { $0.id == Fixtures.legion.id ? Fixtures.off($0) : $0 }
    _ = await rig.runner.tick()   // off again 1 s later: that one cools down
    #expect(rig.sink.names.filter { $0 == "watchdog.restore" }.count == 3)
}

// B-12: fewer writes

@MainActor @Test func unchangedFilesAreWrittenEveryTwoSecondsOnly() async throws {
    let rig = Rig([Fixtures.legion], phase: .normal)
    rig.beat(pid: 777, age: 1)
    _ = await rig.runner.tick()
    #expect(rig.exists(rig.paths.displays) && rig.exists(rig.paths.watchdogHeartbeat))
    try FileManager.default.removeItem(at: rig.paths.displays)
    try FileManager.default.removeItem(at: rig.paths.watchdogHeartbeat)
    rig.sig.clock += 500_000_000
    rig.beat(pid: 777, age: 1)
    _ = await rig.runner.tick()   // 0.5 s later, and nothing changed: nothing written
    #expect(!rig.exists(rig.paths.displays) && !rig.exists(rig.paths.watchdogHeartbeat))
    rig.sig.clock += 1_500_000_000
    rig.beat(pid: 777, age: 1)
    _ = await rig.runner.tick()   // 2 s after the last write: both again
    #expect(rig.exists(rig.paths.displays) && rig.exists(rig.paths.watchdogHeartbeat))
}

@MainActor @Test func changedDisplaysAreWrittenAtOnce() async throws {
    let rig = Rig([Fixtures.legion], phase: .normal)
    rig.beat(pid: 777, age: 1)
    _ = await rig.runner.tick()
    try FileManager.default.removeItem(at: rig.paths.displays)
    try FileManager.default.removeItem(at: rig.paths.watchdogHeartbeat)
    rig.sig.clock += 500_000_000
    rig.beat(pid: 777, age: 1)
    rig.backend.displays.append(Fixtures.p24)   // a monitor is plugged in
    _ = await rig.runner.tick()
    let file = try #require(WatchdogFiles.readDisplays(at: rig.paths.displays))
    #expect(file.displays == [Fixtures.legion, Fixtures.p24])
    #expect(!rig.exists(rig.paths.watchdogHeartbeat))   // that one keeps its 2 s
}

@MainActor @Test func exitDisabledWritesAFreshDisplaysFileFirst() async throws {
    let rig = Rig([Fixtures.legion], phase: .normal)
    rig.beat(pid: 777, age: 1)
    _ = await rig.runner.tick()   // the daemon is still up
    try FileManager.default.removeItem(at: rig.paths.displays)
    FileManager.default.createFile(atPath: rig.paths.disabledMarker.path, contents: Data())
    rig.sig.alive.remove(777)   // the disabled daemon has ended
    rig.sig.clock += 500_000_000
    #expect(await rig.runner.tick() == .exit)
    // `ipadmode disable` waits for a displays.json written after the daemon ended (DisableWait).
    #expect(WatchdogFiles.readDisplays(at: rig.paths.displays)?.displays == [Fixtures.legion])
}
