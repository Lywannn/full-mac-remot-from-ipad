import Foundation
import Testing
@testable import IPadModeCore

private func disabled(_ id: UInt32, _ name: String = "Off") -> DisplayInfo {
    var d = Fixtures.p24
    d.id = DisplayID(raw: id); d.name = name; d.isOnline = false; d.isActive = false
    return d
}
private func active(_ id: UInt32) -> DisplayInfo {
    var d = Fixtures.legion; d.id = DisplayID(raw: id); return d
}
private func state(_ phase: Phase, target: DisplayID? = nil, baseline: Snapshot? = nil) -> PersistedState {
    var s = PersistedState.initial
    s.phase = phase; s.target = target; s.baseline = baseline
    return s
}
private func input(_ s: PersistedState?, alive: Bool = true, age: Duration? = .seconds(1),
                   displays: [DisplayInfo], marker: Bool = false) -> WatchdogInput {
    WatchdogInput(persisted: s, daemonAlive: alive, heartbeatAge: age, displays: displays, disabledMarker: marker)
}
private let remote = Fixtures.virtualRemote

/// A policy that made its first evaluation `staleAfter` (5 s) before `now`: the start window (B-1) is over by then.
private func running(at now: Duration = .zero) -> WatchdogPolicy {
    var p = WatchdogPolicy()
    _ = p.evaluate(input(state(.normal), displays: [active(1)]), now: now - .seconds(5))
    return p
}

@Test func healthyNormalDoesNothing() {
    var p = WatchdogPolicy()
    #expect(p.evaluate(input(state(.normal), displays: [active(1), disabled(3)]), now: .seconds(0)) == .none)
}

@Test func activeDaemonDeadRestores() {
    var p = WatchdogPolicy()
    let i = input(state(.active(.remote), target: remote.id), alive: false, displays: [remote, disabled(1)])
    #expect(p.evaluate(i, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
}

@Test func activeHeartbeatStaleRestoresAndKills() {
    var p = running()
    let i = input(state(.active(.remote), target: remote.id), age: .seconds(6), displays: [remote, disabled(1)])
    #expect(p.evaluate(i, now: .seconds(0)) == .restoreMonitors(killDaemon: true))
}

@Test func freshHeartbeatDoesNothing() {
    var p = WatchdogPolicy()
    let i = input(state(.active(.remote), target: remote.id), age: .seconds(4), displays: [remote, disabled(1)])
    #expect(p.evaluate(i, now: .seconds(0)) == .none)
}

@Test func enteringWithoutTargetYetDoesNothing() {
    var p = WatchdogPolicy()
    // The target is set but absent; in .entering it must not be tracked, however long it stays missing.
    let i = input(state(.entering(.remote), target: DisplayID(raw: 50)), displays: [active(1), disabled(3)])
    for t in 0...10 { #expect(p.evaluate(i, now: .seconds(t)) == .none) }
    let nil_ = input(state(.entering(.remote), target: nil), displays: [active(1), disabled(3)])
    #expect(p.evaluate(nil_, now: .seconds(11)) == .none)
}

@Test func targetMissingNeedsGrace() {
    var p = WatchdogPolicy()
    let i = input(state(.confirming(.remote), target: DisplayID(raw: 50)), displays: [active(1), disabled(3)])
    #expect(p.evaluate(i, now: .seconds(10)) == .none)
    #expect(p.evaluate(i, now: .seconds(11)) == .none)
    #expect(p.evaluate(i, now: .seconds(12)) == .none)
    #expect(p.evaluate(i, now: .milliseconds(13_500)) == .restoreMonitors(killDaemon: false))
}

@Test func targetReappearingResetsGrace() {
    var p = WatchdogPolicy()
    let st = state(.active(.remote), target: remote.id)
    let missing = input(st, displays: [active(1), disabled(3)])
    let present = input(st, displays: [remote, disabled(3)])
    #expect(p.evaluate(missing, now: .seconds(0)) == .none)
    #expect(p.evaluate(present, now: .seconds(1)) == .none)
    #expect(p.evaluate(present, now: .seconds(2)) == .none)
    #expect(p.evaluate(missing, now: .seconds(3)) == .none)
    #expect(p.evaluate(missing, now: .seconds(4)) == .none)
    #expect(p.evaluate(missing, now: .seconds(5)) == .none)
    #expect(p.evaluate(missing, now: .seconds(6)) == .restoreMonitors(killDaemon: false))
}

@Test func zeroActiveDisplaysRestoresEvenInNormal() {
    var p = WatchdogPolicy()
    #expect(p.evaluate(input(state(.normal), displays: [disabled(1), disabled(3)]), now: .seconds(0))
            == .restoreMonitors(killDaemon: false))
}

@Test func zeroActiveWithNothingDisabledDoesNothing() {
    var p = WatchdogPolicy()
    var gone = active(1); gone.isOnline = false; gone.isActive = false; gone.kind = .otherVirtual
    #expect(p.evaluate(input(state(.normal), displays: [gone]), now: .seconds(0)) == .none)
}

@Test func sleepingOnlineDisplayCountsAsActive() {
    // Real backend reports a sleeping online display as isActive = true (R32).
    var p = WatchdogPolicy()
    var sleeping = active(1); sleeping.isOnline = true; sleeping.isActive = true
    #expect(p.evaluate(input(state(.normal), displays: [sleeping, disabled(3)]), now: .seconds(0)) == .none)
}

@Test func missingStateWithDisabledMonitorRestores() {
    var p = WatchdogPolicy()
    let i = input(nil, alive: false, displays: [active(1), disabled(3)])
    #expect(p.evaluate(i, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
}

@Test func missingStateAliveFreshDoesNothing() {
    var p = WatchdogPolicy()
    #expect(p.evaluate(input(nil, displays: [active(1), disabled(3)]), now: .seconds(0)) == .none)
}

@Test func nothingDisabledNothingToDo() {
    var p = WatchdogPolicy()
    let i = input(state(.active(.remote), target: remote.id), alive: false, displays: [remote, active(1)])
    #expect(p.evaluate(i, now: .seconds(0)) == .none)
}

@Test func sidecarAndVirtualOfflineAreNotDisabledMonitors() {
    var p = WatchdogPolicy()
    var side = Fixtures.p24; side.kind = .sidecar; side.isOnline = false; side.isActive = false
    var virt = remote; virt.isOnline = false; virt.isActive = false
    let i = input(state(.active(.remote), target: remote.id), alive: false, displays: [active(1), side, virt])
    #expect(p.evaluate(i, now: .seconds(0)) == .none)
}

@Test func disabledMarkerExitsAfterRestore() {
    var p = WatchdogPolicy()
    let i = input(state(.normal), alive: false, displays: [active(1)], marker: true)
    #expect(p.evaluate(i, now: .seconds(0)) == .exitDisabled)
}

@Test func disabledMarkerKeepsRunningWhileDaemonAliveOrMonitorStillDisabled() {
    var p = WatchdogPolicy()
    #expect(p.evaluate(input(state(.normal), alive: true, displays: [active(1)], marker: true), now: .seconds(0)) == .none)
    // Normal phase with a monitor still disabled: not a restore, and not yet time to exit either.
    #expect(p.evaluate(input(state(.normal), alive: false, displays: [active(1), disabled(3)], marker: true), now: .seconds(0)) == .none)
}

// W1 cool-down

@Test func coolDownSuppressesRepeatRestore() {
    var p = WatchdogPolicy()
    let i = input(nil, alive: false, displays: [active(1), disabled(3)])
    #expect(p.evaluate(i, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
    #expect(p.evaluate(i, now: .seconds(3)) == .none)
    #expect(p.evaluate(i, now: .milliseconds(9_900)) == .none)
    #expect(p.evaluate(i, now: .seconds(10)) == .restoreMonitors(killDaemon: false))
}

@Test func newlyDisabledMonitorBypassesCoolDown() {
    var p = WatchdogPolicy()
    let one = input(nil, alive: false, displays: [active(1), disabled(3)])
    let two = input(nil, alive: false, displays: [active(1), disabled(3), disabled(4)])
    #expect(p.evaluate(one, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
    #expect(p.evaluate(two, now: .seconds(2)) == .restoreMonitors(killDaemon: false))
}

@Test func killIsNotSubjectToCoolDown() {
    var p = running()
    let st = state(.active(.remote), target: remote.id)
    let grace1 = input(st, displays: [active(1), disabled(3)])
    #expect(p.evaluate(grace1, now: .seconds(0)) == .none)
    #expect(p.evaluate(grace1, now: .seconds(1)) == .none)
    #expect(p.evaluate(grace1, now: .seconds(2)) == .none)
    #expect(p.evaluate(grace1, now: .seconds(3)) == .restoreMonitors(killDaemon: false))
    let hung = input(st, age: .seconds(8), displays: [active(1), disabled(3)])
    #expect(p.evaluate(hung, now: .seconds(4)) == .killDaemon)
    #expect(p.lastReason == "heartbeatStale")
}

@Test func killOnlyLeavesCoolDownUnchanged() {
    var p = running()
    let st = state(.active(.remote), target: remote.id)
    let dead = input(st, alive: false, displays: [remote, disabled(3)])
    let hung = input(st, age: .seconds(8), displays: [remote, disabled(3)])
    #expect(p.evaluate(dead, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
    #expect(p.evaluate(hung, now: .seconds(1)) == .killDaemon)
    #expect(p.evaluate(hung, now: .milliseconds(1_500)) == .killDaemon)
    // The kill did not restart the clock: the cool-down still ends 10 s after the restore.
    #expect(p.evaluate(dead, now: .seconds(9)) == .none)
    #expect(p.evaluate(dead, now: .seconds(10)) == .restoreMonitors(killDaemon: false))
}

@Test func reasonComesFromTheTriggeringRule() {
    var p = WatchdogPolicy()
    _ = p.evaluate(input(state(.normal), displays: [disabled(1)]), now: .seconds(0))
    #expect(p.lastReason == "noActiveDisplay")
    var q = WatchdogPolicy()
    _ = q.evaluate(input(nil, alive: false, displays: [active(1), disabled(3)]), now: .seconds(0))
    #expect(q.lastReason == "daemonDead")
    var r = WatchdogPolicy()
    let missing = input(state(.active(.remote), target: remote.id), displays: [active(1), disabled(3)])
    for t in 0...2 { _ = r.evaluate(missing, now: .seconds(t)) }
    #expect(r.evaluate(missing, now: .seconds(3)) == .restoreMonitors(killDaemon: false))
    #expect(r.lastReason == "targetLost")
    #expect(r.evaluate(input(state(.normal), displays: [active(1)]), now: .seconds(4)) == .none)
    #expect(r.lastReason == nil)
}

@Test func sleepBetweenTicksIsAResume() {
    var p = WatchdogPolicy()
    let st = state(.active(.remote), target: remote.id)
    func hung(_ age: Duration) -> WatchdogInput { input(st, age: age, displays: [remote, disabled(3)]) }
    #expect(p.evaluate(hung(.seconds(1)), now: .seconds(0), uptime: .seconds(0)) == .none)
    // An hour asleep: monotonic ran on, uptime did not; the heartbeat looks an hour old after wake.
    #expect(p.evaluate(hung(.seconds(3600)), now: .seconds(3600), uptime: .seconds(1)) == .none)
    for t in 1...4 {
        #expect(p.evaluate(hung(.seconds(3600 + t)), now: .seconds(3600 + t), uptime: .seconds(1 + t)) == .none)
    }
    #expect(p.evaluate(hung(.seconds(3605)), now: .seconds(3605), uptime: .seconds(6)) == .restoreMonitors(killDaemon: true))
}

@Test func sleepInsideATickIsAResume() {
    var p = WatchdogPolicy()
    let st = state(.active(.remote), target: remote.id)
    let hung = input(st, age: .seconds(9), displays: [remote, disabled(3)])
    #expect(p.evaluate(input(st, displays: [remote, disabled(3)]), now: .seconds(0), uptime: .seconds(0)) == .none)
    // The tick lasted 10 s of wall time, 3 s awake: 7 s were asleep.
    #expect(p.evaluate(hung, now: .seconds(10), uptime: .seconds(3)) == .none)
}

@Test func shortSleepIsNotAResume() {
    var p = running()
    let hung = input(state(.active(.remote), target: remote.id), age: .seconds(8), displays: [remote, disabled(3)])
    #expect(p.evaluate(hung, now: .seconds(0), uptime: .seconds(0)) == .restoreMonitors(killDaemon: true))
    #expect(p.evaluate(hung, now: .seconds(1), uptime: .milliseconds(600)) == .killDaemon)   // 0.4 s asleep
}

@Test func ownLongTickIsNotAResume() {
    var p = running()
    let st = state(.active(.remote), target: remote.id)
    func hung(_ age: Duration) -> WatchdogInput { input(st, age: age, displays: [remote, disabled(3)]) }
    #expect(p.evaluate(hung(.seconds(8)), now: .seconds(0), uptime: .seconds(0)) == .restoreMonitors(killDaemon: true))
    // The tick itself took 5 s (both clocks advance): not a resume, the hung daemon is still killed.
    #expect(p.evaluate(hung(.seconds(8)), now: .seconds(5), uptime: .seconds(5)) == .killDaemon)
}

@Test func tickIntervalsOf50msAnd5sAreNotResumes() {
    for gap in [Duration.milliseconds(50), .seconds(5)] {
        var p = running()
        let hung = input(state(.active(.remote), target: remote.id), age: .seconds(8), displays: [remote, disabled(3)])
        #expect(p.evaluate(hung, now: .seconds(0), uptime: .seconds(0)) == .restoreMonitors(killDaemon: true))
        #expect(p.evaluate(hung, now: gap, uptime: gap) == .killDaemon)
    }
}

@Test func skippedTickRestartsTheTargetGrace() {
    var p = WatchdogPolicy()
    let missing = input(state(.active(.remote), target: remote.id), displays: [active(1), disabled(3)])
    #expect(p.evaluate(missing, now: .seconds(0)) == .none)
    #expect(p.evaluate(missing, now: .milliseconds(500)) == .none)
    p.skipTick()   // the display list failed at 1.0 s
    #expect(p.evaluate(missing, now: .milliseconds(1_500)) == .none)   // timer restarts here
    #expect(p.evaluate(missing, now: .milliseconds(2_500)) == .none)
    #expect(p.evaluate(missing, now: .milliseconds(3_500)) == .none)   // would have fired at 3.0 s without the reset
    #expect(p.evaluate(missing, now: .milliseconds(4_500)) == .restoreMonitors(killDaemon: false))
}

@Test func pidGuard() {
    #expect(WatchdogPIDGuard.refusal(pid: 0, ownPID: 50) == "pidTooLow")
    #expect(WatchdogPIDGuard.refusal(pid: 1, ownPID: 50) == "pidTooLow")
    #expect(WatchdogPIDGuard.refusal(pid: 50, ownPID: 50) == "ownPID")
    #expect(WatchdogPIDGuard.refusal(pid: 51, ownPID: 50) == nil)
    #expect(WatchdogPIDGuard.isDaemonExecutable("/usr/local/bin/ipadmode"))
    #expect(!WatchdogPIDGuard.isDaemonExecutable("/usr/local/bin/ipadmode-spike"))
    #expect(!WatchdogPIDGuard.isDaemonExecutable("/Applications/ipadmode.app/Contents/MacOS/other"))
    #expect(!WatchdogPIDGuard.isDaemonExecutable(nil))
    #expect(!WatchdogPIDGuard.isDaemonExecutable(""))
}

// Restore plan (W2)

private func online(_ d: DisplayInfo) -> DisplayInfo { var x = d; x.isOnline = true; x.isActive = true; return x }

@Test func restorePlanWithBaselineUsesBaselineOriginsOfOnlineMonitors() {
    let baseline = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    var legion = Fixtures.legion; legion.origin = Point(x: 500, y: 500)
    let p24 = Fixtures.p24
    let plan = WatchdogRestorePlan.make(baseline: baseline, current: [remote, legion, p24])
    #expect(plan.enable.isEmpty)
    #expect(plan.origins == [legion.id: Point(x: 0, y: 0), p24.id: Point(x: -1920, y: -326)])
}

@Test func restorePlanNeverNamesOfflineMonitorsInOrigins() {
    let baseline = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    var legion = Fixtures.legion; legion.isOnline = false; legion.isActive = false
    let p24 = Fixtures.p24
    let plan = WatchdogRestorePlan.make(baseline: baseline, current: [remote, legion, p24])
    #expect(plan.enable == [legion.id])
    // Main (legion) is still offline: no origin at (0,0), so the online monitor takes it.
    #expect(plan.origins == [p24.id: Point(x: 0, y: 0)])
}

@Test func restorePlanWithoutBaselinePutsLowestOnlinePhysicalAtOrigin() {
    let a = disabled(2, "A"), b = online(disabled(7, "B")), c = online(disabled(5, "C"))
    let plan = WatchdogRestorePlan.make(baseline: nil, current: [remote, a, b, c])
    #expect(plan.enable == [a.id])
    #expect(plan.origins == [DisplayID(raw: 5): Point(x: 0, y: 0)])
}

@Test func restorePlanWithNothingOnlineHasNoOrigins() {
    let plan = WatchdogRestorePlan.make(baseline: nil, current: [remote, disabled(3), disabled(9)])
    #expect(plan.enable == [DisplayID(raw: 3), DisplayID(raw: 9)])
    #expect(plan.origins.isEmpty)
}

@Test func restorePlanIgnoresVirtualAndSidecar() {
    var side = Fixtures.p24; side.kind = .sidecar; side.isOnline = false
    let plan = WatchdogRestorePlan.make(baseline: nil, current: [remote, side])
    #expect(plan.enable.isEmpty && plan.origins.isEmpty)
}


// B-1: the first evaluation after a (re)start

@Test func firstEvaluationAfterAStartIsAResume() {
    // launchd may (re)start the watchdog right at wake, while the daemon's heartbeat is old only because the Mac slept.
    var p = WatchdogPolicy()
    let hung = input(state(.active(.remote), target: remote.id), age: .seconds(3600), displays: [remote, disabled(3)])
    #expect(p.evaluate(hung, now: .seconds(100)) == .none)   // the daemon gets staleAfter to beat
    #expect(p.evaluate(hung, now: .milliseconds(104_900)) == .none)
    #expect(p.evaluate(hung, now: .seconds(105)) == .restoreMonitors(killDaemon: true))
}

@Test func startWindowDelaysNeitherNoActiveDisplayNorADeadDaemon() {
    var a = WatchdogPolicy()
    #expect(a.evaluate(input(state(.normal), displays: [disabled(1), disabled(3)]), now: .seconds(0))
            == .restoreMonitors(killDaemon: false))
    #expect(a.lastReason == "noActiveDisplay")
    var b = WatchdogPolicy()
    let dead = input(state(.active(.remote), target: remote.id), alive: false, displays: [remote, disabled(3)])
    #expect(b.evaluate(dead, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
    #expect(b.lastReason == "daemonDead")
}

// B-7: only monitors whose enable was accepted cool down

@Test func restoreWhoseEnablesAllFailedStartsNoCoolDown() {
    var p = WatchdogPolicy()
    let i = input(nil, alive: false, displays: [active(1), disabled(3)])
    #expect(p.evaluate(i, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
    p.restoreAccepted([])   // the runner: CoreGraphics refused every enable
    #expect(p.evaluate(i, now: .seconds(1)) == .restoreMonitors(killDaemon: false))   // no 10 s wait for nothing
}

@Test func onlyMonitorsWhoseEnableWasAcceptedCoolDown() {
    var p = WatchdogPolicy()
    let both = input(nil, alive: false, displays: [active(1), disabled(3), disabled(4)])
    #expect(p.evaluate(both, now: .seconds(0)) == .restoreMonitors(killDaemon: false))
    p.restoreAccepted([DisplayID(raw: 3)])   // monitor 4's enable failed
    #expect(p.evaluate(both, now: .seconds(1)) == .restoreMonitors(killDaemon: false))   // 4 does not cool down
    p.restoreAccepted([DisplayID(raw: 3), DisplayID(raw: 4)])
    let waking = input(nil, alive: false, displays: [active(1), disabled(3)])
    #expect(p.evaluate(waking, now: .seconds(2)) == .none)   // 3 does: it is waking
}
