import Foundation
import CoreGraphics
import Darwin
import Testing
import IPadModeCore
@testable import IPadModeSystem

/// What the `vdisplay` tests share: a fake backend, fake children, a sandbox, and process helpers.
enum VDisplayTestSupport {
    /// macOS as the host sees it: one virtual display, listed online and active while the fake child that announced
    /// it lives. The fake child writes its PID to `childPIDFile` just before it prints READY.
    @MainActor
    final class FakeBackend: DisplayBackend {
        let displayID = DisplayID(raw: 4242)
        let childPIDFile: URL
        /// `false`: the display never shows up, whatever the child says.
        var appears = true
        /// How the display is classified: not ours, with anything but `.ownVirtual`.
        var kind: DisplayKind = .ownVirtual
        /// Every display-changing call. The host must never make one.
        private(set) var changes: [String] = []

        init(childPIDFile: URL) { self.childPIDFile = childPIDFile }

        func listDisplays() throws -> [DisplayInfo] {
            guard appears, let pid = VDisplayTestSupport.readPID(childPIDFile), kill(pid, 0) == 0 else { return [] }
            return [DisplayInfo(
                id: displayID, uuid: nil, vendor: 0x1A1D, model: 1, serial: 0x1A1D_0001, location: nil,
                name: "iPad Remote", kind: kind, isOnline: true, isActive: true, isMain: false,
                origin: Point(x: 3440, y: 0),
                mode: DisplayMode(widthPoints: 1180, heightPoints: 820, widthPixels: 2360, heightPixels: 1640,
                                  refreshHz: 60),
                mirrorOf: nil)]
        }

        func setEnabled(_ ids: [DisplayID], enabled: Bool, scope: ConfigScope) throws { changes.append("setEnabled") }
        func setOrigins(_ origins: [DisplayID: Point], scope: ConfigScope) throws { changes.append("setOrigins") }
        func setMode(_ id: DisplayID, _ mode: DisplayMode, scope: ConfigScope) throws { changes.append("setMode") }
    }

    /// Fake `vdisplay` children: `/bin/sh` scripts that ignore their arguments. `$DIR` is the sandbox; `pid` and
    /// `args` there record the child's PID and command line.
    enum FakeChild {
        /// Announces display 4242 and stays until a signal ends it.
        static let ready = """
            echo $$ > "$DIR/pid"
            echo 'READY 4242'
            exec /bin/sleep 20
            """
        static let noiseThenReady = "echo 'starting up'\n" + ready
        static let slowReady = "/bin/sleep 0.5\n" + ready
        /// SIGTERM is ignored, also by the `sleep` it becomes.
        static let ignoringTERM = "trap '' TERM\n" + ready
        static let error = """
            echo $$ > "$DIR/pid"
            echo 'ERROR mode-unavailable'
            exec /bin/sleep 20
            """
        static let silent = """
            echo $$ > "$DIR/pid"
            exec /bin/sleep 20
            """
        static let exitsSilently = """
            echo $$ > "$DIR/pid"
            exit 3
            """
        static let exitsMidLine = """
            echo $$ > "$DIR/pid"
            printf 'READY 4242'
            exit 3
            """
        static let exitsAfterReady = """
            echo $$ > "$DIR/pid"
            echo 'READY 4242'
            exit 0
            """
    }

    /// A directory under /tmp with a fake `vdisplay` executable and the host's PID directory.
    struct Sandbox {
        let dir: URL
        var executable: URL { dir.appendingPathComponent("vdisplay.sh") }
        var pidDirectory: URL { dir.appendingPathComponent("run") }
        var childPIDFile: URL { dir.appendingPathComponent("pid") }

        init(child body: String) throws {
            dir = URL(fileURLWithPath: "/tmp/ipm-host-" + UUID().uuidString.prefix(8), isDirectory: true)
            try FileManager.default.createDirectory(at: pidDirectory, withIntermediateDirectories: true)
            let script = "#!/bin/sh\nDIR='\(dir.path)'\nprintf '%s\\n' \"$*\" > \"$DIR/args\"\n\(body)\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }

        func pidFile(_ role: VirtualRole) -> URL { pidDirectory.appendingPathComponent("vdisplay-\(role.rawValue).pid") }
        var childPID: Int32? { VDisplayTestSupport.readPID(childPIDFile) }
        var childArguments: String? {
            (try? String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8))?
                .trimmingCharacters(in: .newlines)
        }

        @MainActor
        func host(timing: ChildProcessVirtualDisplayHost.Timing = .fast,
                  isVirtualDisplayProcess: @escaping (Int32) -> Bool = VirtualDisplayProcessCheck.isVirtualDisplayProcess)
            -> (ChildProcessVirtualDisplayHost, FakeBackend) {
            let backend = FakeBackend(childPIDFile: childPIDFile)
            let host = ChildProcessVirtualDisplayHost(
                executable: executable, backend: backend, pidDirectory: pidDirectory, clock: ContinuousClock(),
                timing: timing, isVirtualDisplayProcess: isVirtualDisplayProcess)
            return (host, backend)
        }
    }

    @MainActor final class Flag { var isSet = false }

    static func readPID(_ url: URL) -> Int32? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// No such process any more: ended and reaped.
    static func isGone(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

    static func elapsed(since start: ContinuousClock.Instant) -> Duration { start.duration(to: .now) }

    /// SIGKILL, but only while `process` has not been reaped: after that its PID may belong to someone else.
    static func end(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    static func spawn(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Waits up to `timeout` for `condition`, checking every 20 ms.
    @MainActor static func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        await ContinuousClock().poll(timeout: timeout, every: .milliseconds(20), condition)
    }

    /// The PID of a process that has ended and been reaped.
    @MainActor static func deadPID() async throws -> Int32 {
        let process = try spawn("/usr/bin/true", [])
        #expect(await eventually { !process.isRunning })
        return process.processIdentifier
    }

    // MARK: Watching changes another process makes

    /// The display list, for a test that watches changes made by another process. Once this process has made a
    /// display-configuration transaction of its own (the R25 test disables its target), CoreGraphics in it stops
    /// seeing other processes' changes, and only an AppKit event loop or another transaction refreshes it (R75, the
    /// `staleview` experiment). So an empty transaction comes first: begin, then complete with no change.
    /// Every listing a hardware test observes goes through here (B-5), the one it takes at its start included: that
    /// one records where a monitor is to be put back.
    @MainActor static func freshDisplays(_ backend: DisplayBackend) -> [DisplayInfo]? {
        try? freshList(backend)
    }

    /// `freshDisplays`, throwing what the listing throws.
    @MainActor static func freshList(_ backend: DisplayBackend) throws -> [DisplayInfo] {
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            _ = CGCompleteDisplayConfiguration(config, .forAppOnly)
        }
        return try backend.listDisplays()
    }

    /// B-5: the backend a hardware test gives the code it tests (the host): each listing is a fresh one, and every
    /// change goes to `base` as it is.
    @MainActor final class FreshBackend: DisplayBackend {
        let base: DisplayBackend

        init(_ base: DisplayBackend) { self.base = base }

        func listDisplays() throws -> [DisplayInfo] { try VDisplayTestSupport.freshList(base) }

        func setEnabled(_ ids: [DisplayID], enabled: Bool, scope: ConfigScope) throws {
            try base.setEnabled(ids, enabled: enabled, scope: scope)
        }

        func setOrigins(_ origins: [DisplayID: Point], scope: ConfigScope) throws {
            try base.setOrigins(origins, scope: scope)
        }

        func setMode(_ id: DisplayID, _ mode: DisplayMode, scope: ConfigScope) throws {
            try base.setMode(id, mode, scope: scope)
        }
    }
}

/// B-5: every test that changes the real display configuration lives in this one suite, nested, so that they run one
/// at a time and never interleave (Swift Testing runs suites in parallel otherwise). They are gated by
/// IPADMODE_HW_TESTS and IPADMODE_DISPLAY_TESTS; run them by hand, with a safety net in place.
@Suite(.serialized) enum DisplayChangingTests {}

extension ChildProcessVirtualDisplayHost.Timing {
    /// Short limits, so that the failure cases do not take seconds.
    static let fast = Self(ready: .seconds(3), online: .seconds(1), exitGrace: .milliseconds(500),
                           staleGrace: .milliseconds(1500), gone: .seconds(1), killWait: .seconds(1))
}
