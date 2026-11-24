import Foundation
import Darwin
import Testing
import IPadModeCore
@testable import IPadModeSystem

private typealias Support = VDisplayTestSupport

/// The real `ipadmode vdisplay` as a dry run (`IPADMODE_VDISPLAY_DRY_RUN=1`): it creates no display and changes
/// nothing, so these need no IPADMODE_DISPLAY_TESTS, only the built binary in IPADMODE_BIN. The child's watches and
/// its wait after READY run exactly as in production, where they must keep the real main thread (C1).
@Suite(.serialized, .enabled(if: env("IPADMODE_BIN")?.isEmpty == false))
struct VirtualDisplayLifecycleTests {
    /// (a) SIGTERM, the daemon's normal stop: exit status 0 within 1 s.
    @Test @MainActor func sigtermEndsTheChildWithStatusZero() async throws {
        let child = try DryRunChild(parent: getpid())
        defer { child.finish() }
        try await child.awaitReady()

        kill(child.process.processIdentifier, SIGTERM)

        #expect(await Support.eventually(.seconds(1)) { !child.process.isRunning }, "ends within 1 s of SIGTERM")
        child.expectCleanExit()
        #expect(child.stderr.contains("SIGTERM: releasing the display"), "stderr: \(child.stderr)")
    }

    /// (b) R25: once its parent has ended the child exits 0, within 8 s (it waits at most 6 s for a lit monitor).
    @Test @MainActor func childExitsWithStatusZeroOnceItsParentEnded() async throws {
        let parent = try Support.spawn("/bin/sleep", ["1"])
        defer { Support.end(parent) }
        let child = try DryRunChild(parent: parent.processIdentifier)
        defer { child.finish() }
        try await child.awaitReady()

        #expect(await Support.eventually(.seconds(3)) { !parent.isRunning })
        #expect(await Support.eventually(.seconds(8)) { !child.process.isRunning }, "ends within 8 s of its parent")
        child.expectCleanExit()
        #expect(child.stderr.contains("releasing the display: "), "R25 released it; stderr: \(child.stderr)")
    }

    /// (d) A SIGTERM right after the parent ended does not cut R25 short: R25 releases the display, not the SIGTERM.
    /// In a dry run with no monitor off, R25 releases at once; a SIGTERM that comes first starts R25 all the same.
    @Test @MainActor func sigtermRightAfterTheParentEndedDoesNotCutR25Short() async throws {
        let parent = try Support.spawn("/bin/sleep", ["1"])
        defer { Support.end(parent) }
        let child = try DryRunChild(parent: parent.processIdentifier)
        defer { child.finish() }
        try await child.awaitReady()

        #expect(await Support.eventually(.seconds(3)) { !parent.isRunning })
        if child.process.isRunning { kill(child.process.processIdentifier, SIGTERM) }

        #expect(await Support.eventually(.seconds(8)) { !child.process.isRunning }, "ends within 8 s of its parent")
        child.expectCleanExit()
        let log = child.stderr
        #expect(log.contains("releasing the display: "), "R25 released it; stderr: \(log)")   // whatever the reason
        #expect(!log.contains("SIGTERM: releasing the display"), "not the SIGTERM exit; stderr: \(log)")
    }

    /// (c) Nothing happens: the child stays.
    @Test @MainActor func childKeepsRunningWhileNothingHappens() async throws {
        let child = try DryRunChild(parent: getpid())
        defer { child.finish() }
        try await child.awaitReady()

        try await Task.sleep(for: .seconds(2))

        #expect(child.process.isRunning, "still running 2 s after READY; stderr: \(child.stderr)")
    }
}

/// A dry-run child watching `parent`. Its stderr goes to a file under /tmp and is shown when an expectation fails.
@MainActor
private final class DryRunChild {
    let process = Process()
    private let dir: URL
    private var output: ChildOutput?

    init(parent: Int32) throws {
        let bin = try #require(env("IPADMODE_BIN"))
        dir = URL(fileURLWithPath: "/tmp/ipm-life-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stderrFile = dir.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)
        var environment = ProcessInfo.processInfo.environment
        environment[VirtualDisplayChild.dryRunVariable] = "1"   // never a real display from these tests
        environment["IPADMODE_SIMULATE_MISSING_API"] = nil      // another suite sets it for a moment
        process.environment = environment
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = VDisplayProtocol.arguments(role: .remote, resolution: .defaultRemote, parentPID: parent)
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: stderrFile)
        try process.run()
        output = ChildOutput(stdout.fileHandleForReading)
    }

    var stderr: String { (try? String(contentsOf: dir.appendingPathComponent("stderr"), encoding: .utf8)) ?? "" }

    /// READY 4242 within 5 s. Anything else, above all a READY for a real display, ends the child at once.
    func awaitReady() async throws {
        _ = await Support.eventually(.seconds(5)) { output?.outcome != nil }
        let outcome = output?.outcome
        let ready = outcome == .ready(VirtualDisplayChild.dryRunDisplayID)
        if !ready { Support.end(process) }
        try #require(ready, "a dry run says READY 4242, not \(String(describing: outcome)); stderr: \(stderr)")
    }

    /// It ended by itself, with exit status 0: a trap would show as the signal SIGTRAP.
    func expectCleanExit(sourceLocation: SourceLocation = #_sourceLocation) {
        guard !process.isRunning else { return }   // the caller's expectation on the time has failed already
        let how = process.terminationReason == .exit ? "exit status" : "signal"
        #expect(process.terminationReason == .exit && process.terminationStatus == 0,
                "ended by \(how) \(process.terminationStatus); stderr: \(stderr)", sourceLocation: sourceLocation)
    }

    func finish() {
        Support.end(process)
        try? FileManager.default.removeItem(at: dir)
    }
}
