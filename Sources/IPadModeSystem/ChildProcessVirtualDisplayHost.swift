import Foundation
import Darwin
import IPadModeCore

public enum VirtualDisplayHostError: Error, Equatable {
    /// The `vdisplay` process could not be launched.
    case launchFailed(String)
    /// It reported `ERROR <reason>`.
    case childFailed(String)
    /// Its output ended before it reported READY, or it ended before its display was online.
    case exited
    /// It reported nothing within `readyTimeout`.
    case readyTimeout
    /// It reported READY, but its display was not online and active within `onlineTimeout`.
    case notOnline(DisplayID)
    /// The PID file could not be written.
    case pidFile(String)
}

/// Runs each virtual display in its own `ipadmode vdisplay` child process (spec §7.1): the display lives exactly as
/// long as that process. Nothing here blocks the main actor: the child's stdout is read off it, and every wait is a
/// poll on `clock`. A child is never left behind: a `start` that fails ends the child it spawned before it throws.
/// Each running child's PID is in `vdisplay-<role>.pid` in `pidDirectory`, so that a later daemon can end what a
/// crashed one left (`stopStale`). The host itself never changes the display configuration.
@MainActor public final class ChildProcessVirtualDisplayHost: VirtualDisplayHost {
    /// How long the child may take to report READY or ERROR.
    nonisolated public static let readyTimeout: Duration = .seconds(5)
    /// How long its display may then take to be online and active.
    nonisolated public static let onlineTimeout: Duration = .seconds(5)
    /// How long a child may take to end after SIGTERM before it gets SIGKILL.
    nonisolated public static let exitGrace: Duration = .seconds(2)
    /// A-4: the same for a stale child, one that no live child of this host is: R25's deadline and 2 s more. An orphan
    /// whose daemon died ignores SIGTERM while R25 turns the monitors back on; this lets it finish.
    nonisolated public static let staleExitGrace: Duration = R25Decision.deadline + .seconds(2)
    /// How long the display may take to disappear once its process has ended.
    nonisolated public static let goneTimeout: Duration = .seconds(3)
    /// How long a process may take to be gone after SIGKILL.
    nonisolated static let killWait: Duration = .seconds(1)

    /// The limits above; tests shorten them.
    struct Timing: Sendable {
        var ready: Duration, online: Duration, exitGrace: Duration, staleGrace: Duration, gone: Duration
        var killWait: Duration

        static let standard = Timing(
            ready: ChildProcessVirtualDisplayHost.readyTimeout, online: ChildProcessVirtualDisplayHost.onlineTimeout,
            exitGrace: ChildProcessVirtualDisplayHost.exitGrace,
            staleGrace: ChildProcessVirtualDisplayHost.staleExitGrace,
            gone: ChildProcessVirtualDisplayHost.goneTimeout, killWait: ChildProcessVirtualDisplayHost.killWait)
    }

    private static let outputInterval: Duration = .milliseconds(20)
    private static let exitInterval: Duration = .milliseconds(20)
    private static let listInterval: Duration = .milliseconds(100)

    private let executable: URL
    private let backend: DisplayBackend
    private let pidDirectory: URL
    private let clock: any Clock<Duration>
    private let timing: Timing
    private let isVirtualDisplayProcess: (Int32) -> Bool
    /// The children this host started, by PID, until they are stopped. `stopStale` never touches the live ones (R46).
    private var children: [Int32: Child] = [:]

    private struct Child {
        let process: Process
        let output: ChildOutput
    }

    /// `executable` is this binary; `pidDirectory` holds the PID files.
    public convenience init(executable: URL, backend: DisplayBackend, pidDirectory: URL, clock: any Clock<Duration>) {
        self.init(executable: executable, backend: backend, pidDirectory: pidDirectory, clock: clock, timing: .standard,
                  isVirtualDisplayProcess: VirtualDisplayProcessCheck.isVirtualDisplayProcess)
    }

    /// `isVirtualDisplayProcess` decides whether a PID read from a PID file may be signalled.
    init(executable: URL, backend: DisplayBackend, pidDirectory: URL, clock: any Clock<Duration>, timing: Timing,
         isVirtualDisplayProcess: @escaping (Int32) -> Bool) {
        self.executable = executable; self.backend = backend; self.pidDirectory = pidDirectory; self.clock = clock
        self.timing = timing; self.isVirtualDisplayProcess = isVirtualDisplayProcess
    }

    /// Spawns `executable vdisplay …`, waits for its READY (≤5 s) and for its display to be online and active
    /// (≤5 s), then writes the PID file. Any failure ends the child (SIGTERM, then SIGKILL after 2 s) and removes
    /// its PID file before it throws.
    public func start(role: VirtualRole, resolution: Resolution) async throws -> VirtualDisplayHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = VDisplayProtocol.arguments(role: role, resolution: resolution, parentPID: getpid())
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout   // stderr stays ours: the child's diagnostics land in the daemon's log
        do { try process.run() } catch { throw VirtualDisplayHostError.launchFailed("\(error)") }
        let pid = process.processIdentifier
        let child = Child(process: process, output: ChildOutput(stdout.fileHandleForReading))
        children[pid] = child
        do {
            let id = try await awaitReady(child)
            try await awaitOnline(id, child)
            try writePIDFile(role, pid)
            return VirtualDisplayHandle(role: role, pid: pid, displayID: id)
        } catch {
            _ = await terminate(child)
            children[pid] = nil
            removePIDFile(pidFile(role), ifItNames: pid)
            throw error
        }
    }

    /// SIGTERM, up to 2 s for the child to end, SIGKILL if it has not, then up to 3 s for its display to disappear.
    /// A handle this host did not start is a stale process to it, and gets the stale grace (A-4). The PID file goes
    /// once the process is gone. Harmless for a child that has ended already, and when repeated.
    public func stop(_ handle: VirtualDisplayHandle) async {
        let ended: Bool
        if let child = children[handle.pid] {
            ended = await terminate(child)
            if ended { children[handle.pid] = nil }
        } else {
            ended = await terminate(pids: [handle.pid])   // not started by this host: signalled only if it is ours
        }
        let id = handle.displayID
        _ = await clock.poll(timeout: timing.gone, every: Self.listInterval) {
            (try? backend.listDisplays()).map { list in !list.contains { Self.isOurs($0, id) && $0.isOnline } } ?? false
        }
        if ended { removePIDFile(pidFile(handle.role), ifItNames: handle.pid) }
    }

    /// Ends what an earlier run left. For each `vdisplay-*.pid`: a live `ipadmode vdisplay` process that this host
    /// did not start gets SIGTERM, then SIGKILL after 8 s (`staleExitGrace`, A-4), time for an orphan to finish R25.
    /// The host's own live children are never touched (R46). A PID file is removed only once its process is gone, or
    /// when it names no process at all; one that names a live process that is not ours stays, and that process is
    /// never signalled.
    public func stopStale() async {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: pidDirectory.path)) ?? []
        let ownLive = Set(children.filter { $0.value.process.isRunning }.keys)
        var stale: [(file: URL, pid: Int32)] = []
        for name in names.sorted() where name.hasPrefix("vdisplay-") && name.hasSuffix(".pid") {
            let file = pidDirectory.appendingPathComponent(name)
            guard let pid = Self.readPID(file) else {
                try? fm.removeItem(at: file)
                continue
            }
            if ownLive.contains(pid) || pid == getpid() { continue }
            if !Self.isAlive(pid) {
                removePIDFile(file, ifItNames: pid)
            } else if isVirtualDisplayProcess(pid) {
                stale.append((file, pid))
            }
        }
        guard !stale.isEmpty else { return }
        _ = await terminate(pids: stale.map(\.pid))
        for (file, pid) in stale where !Self.isAlive(pid) { removePIDFile(file, ifItNames: pid) }
    }

    // MARK: Starting

    private func awaitReady(_ child: Child) async throws -> DisplayID {
        _ = await clock.poll(timeout: timing.ready, every: Self.outputInterval) { child.output.outcome != nil }
        switch child.output.outcome {
        case .ready(let id)?: return id
        case .failed(let reason)?: throw VirtualDisplayHostError.childFailed(reason)
        case .ended?: throw VirtualDisplayHostError.exited
        case nil: throw VirtualDisplayHostError.readyTimeout
        }
    }

    /// Stops early when the child ends: its display cannot come anymore.
    private func awaitOnline(_ id: DisplayID, _ child: Child) async throws {
        var online = false
        _ = await clock.poll(timeout: timing.online, every: Self.listInterval) {
            online = (try? backend.listDisplays())?.contains { Self.isOurs($0, id) && $0.isOnline && $0.isActive } == true
            return online || !child.process.isRunning
        }
        if online { return }
        throw child.process.isRunning ? VirtualDisplayHostError.notOnline(id) : .exited
    }

    /// Our virtual display with this ID: a real display that happens to have it is never taken for ours (O1).
    private static func isOurs(_ display: DisplayInfo, _ id: DisplayID) -> Bool {
        display.id == id && display.kind == .ownVirtual
    }

    // MARK: Ending

    /// Ends a child this host started, with the 2 s grace. True once it has ended and been reaped.
    private func terminate(_ child: Child) async -> Bool {
        let process = child.process
        return await terminate([process.processIdentifier], grace: timing.exitGrace,
                               isGone: { _ in !process.isRunning }, mayKill: { _ in process.isRunning })
    }

    /// Ends stale processes named by PID files, with the stale grace (A-4), each only while `mayStop` allows it,
    /// checked again before SIGKILL: the PID may belong to someone else by now, even to a child this host has started
    /// meanwhile. True once none of them is left.
    private func terminate(pids: [Int32]) async -> Bool {
        await terminate(pids, grace: timing.staleGrace, isGone: { !Self.isAlive($0) }, mayKill: { self.mayStop($0) })
    }

    /// Whether a PID from a PID file may be signalled: alive, an `ipadmode vdisplay` process, and not one of this
    /// host's children, which only `stop` ends (R46).
    func mayStop(_ pid: Int32) -> Bool {
        Self.isAlive(pid) && isVirtualDisplayProcess(pid) && children[pid] == nil
    }

    /// SIGTERM to each of `pids` that `mayKill` allows, up to `grace` for those to be gone, then SIGKILL to the ones
    /// still there that it still allows, and up to `killWait` more. True once all of `pids` are gone.
    private func terminate(_ pids: [Int32], grace: Duration, isGone: (Int32) -> Bool,
                           mayKill: (Int32) -> Bool) async -> Bool {
        let targets = pids.filter { !isGone($0) && mayKill($0) }
        if !targets.isEmpty {
            for pid in targets { kill(pid, SIGTERM) }
            let ended = await clock.poll(timeout: grace, every: Self.exitInterval) {
                targets.allSatisfy(isGone)
            }
            if !ended {
                for pid in targets where !isGone(pid) && mayKill(pid) { kill(pid, SIGKILL) }
                _ = await clock.poll(timeout: timing.killWait, every: Self.exitInterval) { targets.allSatisfy(isGone) }
            }
        }
        return pids.allSatisfy(isGone)
    }

    // MARK: PID files

    private func pidFile(_ role: VirtualRole) -> URL {
        pidDirectory.appendingPathComponent("vdisplay-\(role.rawValue).pid")
    }

    private func writePIDFile(_ role: VirtualRole, _ pid: Int32) throws {
        do {
            try FileManager.default.createDirectory(at: pidDirectory, withIntermediateDirectories: true)
            try Data("\(pid)\n".utf8).write(to: pidFile(role), options: .atomic)
        } catch {
            throw VirtualDisplayHostError.pidFile("\(error)")
        }
    }

    /// Only while it still names `pid`: a later `start` may have replaced it.
    private func removePIDFile(_ file: URL, ifItNames pid: Int32) {
        if Self.readPID(file) == pid { try? FileManager.default.removeItem(at: file) }
    }

    /// The PID a PID file names, or nil when it names none.
    private static func readPID(_ file: URL) -> Int32? {
        guard let data = try? Data(contentsOf: file), data.count <= 16 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = Int32(text), pid > 1 else {
            return nil
        }
        return pid
    }

    /// Alive, or ended but not yet reaped. EPERM: it exists, but is not ours to signal.
    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

/// A child's stdout, read off the main actor. The first READY or ERROR line settles `outcome`; other lines are
/// skipped; the end of the output before either settles it as `.ended`. The rest is drained unread, so that the
/// child never blocks on a full pipe.
final class ChildOutput: @unchecked Sendable {
    enum Outcome: Equatable { case ready(DisplayID), failed(String), ended }

    /// Longer than any line of ours: dropped unparsed.
    private static let maxLine = 4096
    private let lock = NSLock()
    private var pending = Data()
    private var settled: Outcome?

    init(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil   // the end; left set, the handler would keep firing
                settle(.ended)
            } else {
                consume(data)
            }
        }
    }

    var outcome: Outcome? {
        lock.lock(); defer { lock.unlock() }
        return settled
    }

    private func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard settled == nil else { return }
        pending.append(data)
        while settled == nil, let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            if let id = VDisplayProtocol.parseReady(line) {
                settled = .ready(id)
            } else if let reason = VDisplayProtocol.parseError(line) {
                settled = .failed(reason)
            }
        }
        if settled != nil || pending.count > Self.maxLine { pending.removeAll() }
    }

    private func settle(_ outcome: Outcome) {
        lock.lock(); defer { lock.unlock() }
        if settled == nil { settled = outcome }
    }
}

/// Which process a PID file may lead us to signal: only an `ipadmode vdisplay …`. The PID may have been reused since
/// the file was written, even by another `ipadmode` such as the watchdog, so both the executable and the role count.
enum VirtualDisplayProcessCheck {
    static func isVirtualDisplayProcess(_ pid: Int32) -> Bool {
        matches(path: executablePath(pid), arguments: arguments(pid))
    }

    static func matches(path: String?, arguments: [String]?) -> Bool {
        guard WatchdogPIDGuard.isDaemonExecutable(path), let arguments, arguments.count > 1 else { return false }
        return arguments[1] == VDisplayProtocol.subcommand
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's argv, from KERN_PROCARGS2 (argc, the executable path, padding, then argv); nil if unreadable.
    static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let header = MemoryLayout<Int32>.size
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > header else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > header else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = header
        while i < size, buffer[i] != 0 { i += 1 }   // the executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            arguments.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}
