import Foundation
import Darwin
import Testing
import IPadModeCore
@testable import IPadModeSystem

private typealias Support = VDisplayTestSupport

/// The host, with fake `/bin/sh` children and a fake backend: no display is involved.
@Suite struct VirtualDisplayHostTests {
    @Test func productionLimitsAreTheSpecified() {
        #expect(ChildProcessVirtualDisplayHost.readyTimeout == .seconds(5))
        #expect(ChildProcessVirtualDisplayHost.onlineTimeout == .seconds(5))
        #expect(ChildProcessVirtualDisplayHost.exitGrace == .seconds(2))
        #expect(ChildProcessVirtualDisplayHost.goneTimeout == .seconds(3))
        let standard = ChildProcessVirtualDisplayHost.Timing.standard
        #expect(standard.ready == .seconds(5)); #expect(standard.online == .seconds(5))
        #expect(standard.exitGrace == .seconds(2)); #expect(standard.gone == .seconds(3))
    }

    @Test func staleChildrenGetR25sDeadlineAndTwoSecondsOwnChildrenTwo() {
        // A-4: an orphan ignores SIGTERM while R25 runs, for up to R25's 6 s deadline.
        #expect(ChildProcessVirtualDisplayHost.staleExitGrace == R25Decision.deadline + .seconds(2))
        #expect(ChildProcessVirtualDisplayHost.staleExitGrace == .seconds(8))
        let standard = ChildProcessVirtualDisplayHost.Timing.standard
        #expect(standard.staleGrace == .seconds(8))
        #expect(standard.exitGrace == .seconds(2))   // the host's own children keep their 2 s
    }

    @Test @MainActor func startReturnsTheHandleAndWritesThePIDFile() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.noiseThenReady)   // a line other than READY is skipped
        defer { sandbox.remove() }
        let (host, backend) = sandbox.host()

        let handle = try await host.start(role: .remote, resolution: .defaultRemote)

        #expect(handle.role == .remote)
        #expect(handle.displayID == DisplayID(raw: 4242))
        #expect(handle.pid == sandbox.childPID)
        #expect(Support.readPID(sandbox.pidFile(.remote)) == handle.pid)
        #expect(sandbox.childArguments == "vdisplay --role remote --resolution 1180x820 --parent \(getpid())")
        await host.stop(handle)
        #expect(backend.changes.isEmpty)
    }

    @Test @MainActor func startPassesRoleAndResolution() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host()

        let handle = try await host.start(role: .fallback, resolution: try #require(Resolution(parsing: "1534x1066")))

        #expect(sandbox.childArguments == "vdisplay --role fallback --resolution 1534x1066 --parent \(getpid())")
        #expect(Support.readPID(sandbox.pidFile(.fallback)) == handle.pid)
        await host.stop(handle)
    }

    @Test @MainActor func stopEndsTheChildAndRemovesThePIDFile() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let (host, backend) = sandbox.host(timing: .standard)
        let handle = try await host.start(role: .remote, resolution: .defaultRemote)

        let start = ContinuousClock.now
        await host.stop(handle)

        #expect(Support.elapsed(since: start) < .seconds(1))   // it ended on SIGTERM: no wait for the 2 s grace
        #expect(Support.isGone(handle.pid))
        #expect(try backend.listDisplays().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func childIgnoringSIGTERMIsKilledAfterTwoSeconds() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ignoringTERM)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host(timing: .standard)
        let handle = try await host.start(role: .remote, resolution: .defaultRemote)

        let start = ContinuousClock.now
        await host.stop(handle)

        let took = Support.elapsed(since: start)
        #expect(took >= .seconds(2)); #expect(took < .milliseconds(3500))
        #expect(Support.isGone(handle.pid))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func stopTwiceAndStopAfterTheChildEndedAreHarmless() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host(timing: .standard)
        let handle = try await host.start(role: .remote, resolution: .defaultRemote)
        kill(handle.pid, SIGKILL)
        #expect(await Support.eventually { Support.isGone(handle.pid) })

        let start = ContinuousClock.now
        await host.stop(handle)
        await host.stop(handle)

        #expect(Support.elapsed(since: start) < .seconds(1))   // nothing left to signal or wait for
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func errorLineFailsTheStartAndTheChildIsReaped() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.error)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host()

        await #expect(throws: VirtualDisplayHostError.childFailed("mode-unavailable")) {
            try await host.start(role: .remote, resolution: .defaultRemote)
        }

        let pid = try #require(sandbox.childPID)
        #expect(Support.isGone(pid))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func silentChildTimesOutAndIsKilled() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.silent)
        defer { sandbox.remove() }
        var timing = ChildProcessVirtualDisplayHost.Timing.fast
        timing.ready = .seconds(2)   // well above a slow spawn, so the child is up and silent when it ends
        let (host, _) = sandbox.host(timing: timing)

        let start = ContinuousClock.now
        await #expect(throws: VirtualDisplayHostError.readyTimeout) {
            try await host.start(role: .remote, resolution: .defaultRemote)
        }

        #expect(Support.elapsed(since: start) >= .seconds(2))
        let pid = try #require(sandbox.childPID)
        #expect(Support.isGone(pid))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    /// Children whose output ends before a whole READY line.
    enum EndingChild: CaseIterable { case silently, midLine }

    @Test(arguments: EndingChild.allCases) @MainActor
    func endOfOutputBeforeReadyFailsTheStart(child: EndingChild) async throws {
        let sandbox = try Support.Sandbox(child: child == .silently ? Support.FakeChild.exitsSilently : Support.FakeChild.exitsMidLine)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host()

        let start = ContinuousClock.now
        await #expect(throws: VirtualDisplayHostError.exited) {
            try await host.start(role: .remote, resolution: .defaultRemote)
        }

        #expect(Support.elapsed(since: start) < .seconds(2))   // at the end of the output, not at the timeout
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func displayThatNeverComesOnlineFailsTheStart() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let (host, backend) = sandbox.host()
        backend.appears = false

        await #expect(throws: VirtualDisplayHostError.notOnline(DisplayID(raw: 4242))) {
            try await host.start(role: .remote, resolution: .defaultRemote)
        }

        let pid = try #require(sandbox.childPID)
        #expect(Support.isGone(pid))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func realDisplayWithTheSameIDIsNotTakenForOurs() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let (host, backend) = sandbox.host()
        backend.kind = .physical   // display 4242 is online and active, but it is not our virtual display

        await #expect(throws: VirtualDisplayHostError.notOnline(DisplayID(raw: 4242))) {
            try await host.start(role: .remote, resolution: .defaultRemote)
        }

        let pid = try #require(sandbox.childPID)
        #expect(Support.isGone(pid))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func childEndingAfterReadyFailsTheStartAtOnce() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.exitsAfterReady)
        defer { sandbox.remove() }
        var timing = ChildProcessVirtualDisplayHost.Timing.fast
        timing.online = .seconds(5)
        let (host, backend) = sandbox.host(timing: timing)
        backend.appears = false

        let start = ContinuousClock.now
        await #expect(throws: VirtualDisplayHostError.exited) {
            try await host.start(role: .remote, resolution: .defaultRemote)
        }

        #expect(Support.elapsed(since: start) < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func launchFailureThrows() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let backend = Support.FakeBackend(childPIDFile: sandbox.childPIDFile)
        let host = ChildProcessVirtualDisplayHost(
            executable: sandbox.dir.appendingPathComponent("missing"), backend: backend,
            pidDirectory: sandbox.pidDirectory, clock: ContinuousClock())

        let error = await #expect(throws: VirtualDisplayHostError.self) {
            try await host.start(role: .remote, resolution: .defaultRemote)
        }
        guard case .launchFailed? = error else {
            Issue.record("expected launchFailed, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
    }

    @Test @MainActor func startDoesNotBlockTheMainActor() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.slowReady)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host()
        let done = Support.Flag()

        let starting = Task { @MainActor in
            defer { done.isSet = true }
            return try await host.start(role: .remote, resolution: .defaultRemote)
        }
        var turns = 0
        while !done.isSet {
            turns += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        let handle = try await starting.value

        #expect(turns >= 10)   // the child took 0.5 s to say READY; the main actor kept running meanwhile
        await host.stop(handle)
    }

    // MARK: R46: stopStale

    @Test @MainActor func stopStaleRemovesDeadAndGarbagePIDFilesAndSparesOtherProcesses() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host()
        let sleeper = try Support.spawn("/bin/sleep", ["20"])
        defer { Support.end(sleeper) }
        let dead = try await Support.deadPID()
        try "\(dead)\n".write(to: sandbox.pidFile(.remote), atomically: true, encoding: .utf8)
        try "\(sleeper.processIdentifier)\n".write(to: sandbox.pidFile(.anchor), atomically: true, encoding: .utf8)
        try "garbage\n".write(to: sandbox.pidFile(.fallback), atomically: true, encoding: .utf8)
        let other = sandbox.pidDirectory.appendingPathComponent("other.pid")
        try "\(dead)\n".write(to: other, atomically: true, encoding: .utf8)

        await host.stopStale()

        #expect(sleeper.isRunning)   // alive, and not our binary: never signalled
        #expect(FileManager.default.fileExists(atPath: sandbox.pidFile(.anchor).path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.remote).path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.fallback).path))
        #expect(FileManager.default.fileExists(atPath: other.path))   // not a vdisplay PID file
    }

    @Test @MainActor func stopStaleNeverStopsItsOwnLiveChild() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        // Every live process passes the identity check: only R46 keeps the host's own child alive.
        let (host, _) = sandbox.host(isVirtualDisplayProcess: { _ in true })
        let handle = try await host.start(role: .remote, resolution: .defaultRemote)
        let stale = try Support.spawn("/bin/sleep", ["20"])
        defer { Support.end(stale) }
        try "\(stale.processIdentifier)\n".write(to: sandbox.pidFile(.fallback), atomically: true, encoding: .utf8)

        await host.stopStale()

        #expect(kill(handle.pid, 0) == 0)
        #expect(Support.readPID(sandbox.pidFile(.remote)) == handle.pid)
        #expect(await Support.eventually { !stale.isRunning })
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.fallback).path))
        await host.stop(handle)
    }

    @Test @MainActor func stopStaleKillsAStaleProcessThatIgnoresSIGTERM() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host(isVirtualDisplayProcess: { _ in true })
        let armed = sandbox.dir.appendingPathComponent("armed")
        let stale = try Support.spawn("/bin/sh", ["-c", "trap '' TERM; : > '\(armed.path)'; exec /bin/sleep 20"])
        defer { Support.end(stale) }
        #expect(await Support.eventually { FileManager.default.fileExists(atPath: armed.path) })
        try "\(stale.processIdentifier)\n".write(to: sandbox.pidFile(.anchor), atomically: true, encoding: .utf8)

        let start = ContinuousClock.now
        await host.stopStale()

        #expect(Support.elapsed(since: start) >= .milliseconds(500))   // SIGKILL only after the grace
        #expect(await Support.eventually { !stale.isRunning })
        #expect(!FileManager.default.fileExists(atPath: sandbox.pidFile(.anchor).path))
    }

    @Test @MainActor func staleProcessGetsTheStaleGraceAndOwnChildTheExitGrace() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ignoringTERM)
        defer { sandbox.remove() }
        let (host, _) = sandbox.host(isVirtualDisplayProcess: { _ in true })
        let timing = ChildProcessVirtualDisplayHost.Timing.fast
        try #require(timing.staleGrace > timing.exitGrace + .milliseconds(500))
        // A stale process that ignores SIGTERM, as an orphan in R25 does: SIGKILL only after the stale grace (A-4).
        let armed = sandbox.dir.appendingPathComponent("armed")
        let stale = try Support.spawn("/bin/sh", ["-c", "trap '' TERM; : > '\(armed.path)'; exec /bin/sleep 20"])
        defer { Support.end(stale) }
        #expect(await Support.eventually { FileManager.default.fileExists(atPath: armed.path) })
        try "\(stale.processIdentifier)\n".write(to: sandbox.pidFile(.anchor), atomically: true, encoding: .utf8)
        var start = ContinuousClock.now
        await host.stopStale()
        #expect(Support.elapsed(since: start) >= timing.staleGrace)
        #expect(await Support.eventually { !stale.isRunning })

        // The host's own child that ignores SIGTERM still gets SIGKILL after the exit grace.
        let handle = try await host.start(role: .remote, resolution: .defaultRemote)
        start = ContinuousClock.now
        await host.stop(handle)
        let took = Support.elapsed(since: start)
        #expect(took >= timing.exitGrace && took < timing.staleGrace)
        #expect(Support.isGone(handle.pid))
    }

    // MARK: Which process may be signalled

    @Test @MainActor func mayStopSparesTheHostsOwnChildren() async throws {
        let sandbox = try Support.Sandbox(child: Support.FakeChild.ready)
        defer { sandbox.remove() }
        // Every live process passes the identity check: only M2 keeps the host's own child out.
        let (host, _) = sandbox.host(isVirtualDisplayProcess: { _ in true })
        let handle = try await host.start(role: .remote, resolution: .defaultRemote)
        let stale = try Support.spawn("/bin/sleep", ["20"])
        defer { Support.end(stale) }

        #expect(!host.mayStop(handle.pid))                // ours: only `stop` ends it
        #expect(host.mayStop(stale.processIdentifier))
        #expect(!host.mayStop(try await Support.deadPID()))
        await host.stop(handle)
    }

    @Test func onlyAnIpadmodeVdisplayProcessMatches() {
        let app = "/Users/me/Applications/iPadMode/iPadMode.app/Contents/MacOS/ipadmode"
        #expect(VirtualDisplayProcessCheck.matches(path: app, arguments: [app, "vdisplay", "--role", "remote"]))
        #expect(!VirtualDisplayProcessCheck.matches(path: app, arguments: [app, "watchdog"]))
        #expect(!VirtualDisplayProcessCheck.matches(path: app, arguments: [app]))
        #expect(!VirtualDisplayProcessCheck.matches(path: app, arguments: nil))
        #expect(!VirtualDisplayProcessCheck.matches(path: nil, arguments: ["ipadmode", "vdisplay"]))
        #expect(!VirtualDisplayProcessCheck.matches(path: "/bin/sleep", arguments: ["/bin/sleep", "vdisplay"]))
        #expect(!VirtualDisplayProcessCheck.matches(path: "/x/ipadmode-spike", arguments: ["ipadmode-spike", "vdisplay"]))
    }

    @Test @MainActor func readsTheExecutableAndArgumentsOfAnotherProcess() async throws {
        let sleeper = try Support.spawn("/bin/sleep", ["20"])
        defer { Support.end(sleeper) }
        let pid = sleeper.processIdentifier

        #expect(VirtualDisplayProcessCheck.executablePath(pid) == "/bin/sleep")
        #expect(VirtualDisplayProcessCheck.arguments(pid) == ["/bin/sleep", "20"])
        #expect(!VirtualDisplayProcessCheck.isVirtualDisplayProcess(pid))
        let dead = try await Support.deadPID()
        #expect(VirtualDisplayProcessCheck.executablePath(dead) == nil)
        #expect(VirtualDisplayProcessCheck.arguments(dead) == nil)
        #expect(!VirtualDisplayProcessCheck.isVirtualDisplayProcess(dead))
    }
}
