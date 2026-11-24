import Foundation
import Darwin
import IPadModeCore

public struct DoctorLine: Equatable {
    public enum Level { case ok, warning, failure }
    public var level: Level
    public var text: String
    public init(level: Level, text: String) { self.level = level; self.text = text }

    public var rendered: String {
        let prefix: String
        switch level {
        case .ok: prefix = Messages.doctorOK
        case .warning: prefix = Messages.doctorWarning
        case .failure: prefix = Messages.doctorFailure
        }
        return "\(prefix) \(text)"
    }
}

public struct DoctorReport {
    public var lines: [DoctorLine]
    public var hasCriticalFailure: Bool { lines.contains { $0.level == .failure } }
    public init(lines: [DoctorLine]) { self.lines = lines }
}

public enum Agents {
    public static let daemonLabel = "local.ipadmode.daemon"
    public static let watchdogLabel = "local.ipadmode.watchdog"
    public static let rustDeskServerLabel = "com.carriez.RustDesk_server"
    public static func domain(_ label: String) -> String { "gui/\(getuid())/\(label)" }
}

/// Reads the live system and changes nothing. Every external command has a 5 s limit.
public func runDoctor(paths: Paths) -> DoctorReport {
    var lines: [DoctorLine] = []
    func add(_ level: DoctorLine.Level, _ text: String) { lines.append(DoctorLine(level: level, text: text)) }
    func check(_ good: Bool, ok: String, bad: String) { add(good ? .ok : .warning, good ? ok : bad) }
    let uid = getuid()
    let launchctl = "/bin/launchctl"

    // Critical: the private APIs.
    let api = PrivateAPI.status
    for (name, available) in [("virtualDisplay", api.virtualDisplay), ("configureEnabled", api.configureEnabled),
                              ("displayList", api.displayList), ("displayInfo", api.displayInfo)] {
        add(available ? .ok : .failure, Messages.doctorAPI(name, available: available))
    }

    // Agents loaded.
    for label in [Agents.daemonLabel, Agents.watchdogLabel] {
        let loaded = ExternalCommand.run(launchctl, ["print", Agents.domain(label)])?.ok == true
        check(loaded, ok: Messages.doctorAgentLoaded(label), bad: Messages.doctorAgentMissing(label))
    }

    // Heartbeats: read both files FIRST, then sample the clock (R37).
    let daemonBeat = Heartbeat.read(paths.heartbeat)
    let watchdogBeat = Heartbeat.read(paths.watchdogHeartbeat)
    let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    var daemonFresh = false
    for (who, beat) in [("daemon", daemonBeat), ("watchdog", watchdogBeat)] {
        let fresh = DoctorParsers.isFresh(age: beat?.age(nowNanos: now))
        if who == "daemon" { daemonFresh = fresh }
        if fresh, let beat { add(.ok, Messages.doctorHeartbeatFresh(who, pid: beat.pid)) }
        else if let beat { add(.warning, Messages.doctorHeartbeatStalePID(who, pid: beat.pid)) }
        else { add(.warning, Messages.doctorHeartbeatStale(who)) }
    }

    // R80: a live daemon that does not answer on its socket.
    if daemonFresh {
        do {
            _ = try SocketClient.send(.status, path: paths.socket, timeout: .seconds(3))
            add(.ok, Messages.doctorSocketOK)
        } catch SocketClientError.notRunning { add(.warning, Messages.doctorSocketDead) }
        catch SocketClientError.timeout { add(.warning, Messages.doctorSocketDead) }
        catch SocketClientError.badResponse { add(.warning, Messages.doctorSocketBad) }
        catch { add(.warning, Messages.doctorSocketDead) }
    }

    // RustDesk: architecture and the --server process.
    let rustDesk = "/Applications/RustDesk.app/Contents/MacOS/RustDesk"
    if let lipo = ExternalCommand.run("/usr/bin/lipo", ["-archs", rustDesk]), lipo.ok {
        if DoctorParsers.isARM(lipoArchs: lipo.output) { add(.ok, Messages.doctorRustDeskArm) }
        else { add(.warning, Messages.doctorRustDeskNotArm(lipo.output.trimmingCharacters(in: .whitespacesAndNewlines))) }
    } else { add(.warning, Messages.doctorRustDeskUnreadable) }
    let pgrep = ExternalCommand.run("/usr/bin/pgrep", ["-f", "RustDesk.app/Contents/MacOS/RustDesk --server"])
    var serverRunning = pgrep.map { $0.ok && DoctorParsers.rustDeskServerRunning(pgrepOutput: $0.output) } ?? false
    if !serverRunning, let printed = ExternalCommand.run(launchctl, ["print", Agents.domain(Agents.rustDeskServerLabel)]) {
        serverRunning = DoctorParsers.rustDeskServerRunning(launchctlPrint: printed.output)
    }
    check(serverRunning, ok: Messages.doctorRustDeskServerOK, bad: Messages.doctorRustDeskServerDown(uid: uid))

    // Ports.
    for port in [22, 5900] {
        check(tcpConnects(port: UInt16(port)), ok: Messages.doctorPortOpen(port), bad: Messages.doctorPortClosed(port))
    }

    // Power, FileVault, updates.
    if let pm = ExternalCommand.run("/usr/bin/pmset", ["-g"]), pm.ok, let on = DoctorParsers.autorestart(pmset: pm.output) {
        check(on, ok: Messages.doctorAutorestartOn, bad: Messages.doctorAutorestartOff)
    } else { add(.warning, Messages.doctorAutorestartUnknown) }
    if let fv = ExternalCommand.run("/usr/bin/fdesetup", ["status"]), let on = DoctorParsers.fileVaultOn(fdesetup: fv.output) {
        add(.ok, on ? Messages.doctorFileVaultOn : Messages.doctorFileVaultOff)
    } else { add(.warning, Messages.doctorFileVaultUnknown) }
    if let d = ExternalCommand.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticallyInstallMacOSUpdates"]),
       d.ok, let on = DoctorParsers.autoMacOSUpdates(defaultsValue: d.output) {
        check(!on, ok: Messages.doctorUpdatesOff, bad: Messages.doctorUpdatesOn)
    } else { add(.warning, Messages.doctorUpdatesUnknown) }

    // Config, marker, safe mode.
    let warnings = ConfigLoader.load(from: paths.config).warnings
    if warnings.isEmpty { add(.ok, Messages.doctorConfigOK) }
    for w in warnings { add(.warning, Messages.doctorConfigWarning(w)) }
    let disabled = FileManager.default.fileExists(atPath: paths.disabledMarker.path)
    check(!disabled, ok: Messages.doctorNotDisabled, bad: Messages.doctorDisabled)
    if let state = FileStateStore(url: paths.state).load() {
        let safe = DoctorParsers.isSafeMode(uncleanStarts: state.uncleanStarts, now: Date(), daemonHeartbeatFresh: daemonFresh)
        check(!safe, ok: Messages.doctorSafeModeOff, bad: Messages.doctorSafeModeOn)
    } else { add(.ok, Messages.doctorSafeModeOff) }
    return DoctorReport(lines: lines)
}

/// A plain TCP connect to 127.0.0.1 with a 1 s limit.
func tcpConnects(port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if rc == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, 1000) > 0 else { return false }
    var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0
}
