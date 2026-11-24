import Foundation
import Darwin
import IPadModeCore

@MainActor final class SystemWatchdogSignaller: WatchdogSignaller {
    var ownPID: Int32 { getpid() }
    func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
    func send(_ signal: Int32, to pid: Int32) { kill(pid, signal) }
    func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
    func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    func sleep(_ d: Duration) async { try? await Task.sleep(for: d) }
}

/// The watchdog process (spec §7.8 L4). It may only enable monitors, set origins, write its
/// breadcrumb files and signal the daemon. It never disables anything and never touches virtual
/// or Sidecar displays. The decisions live in `WatchdogPolicy` and `WatchdogRunner` (IPadModeCore).
@MainActor public func runWatchdog(paths: Paths, backend: DisplayBackend, config: Config) -> Never {
    let log = EventLog(directory: paths.logs, baseName: "watchdog", subsystem: "local.ipadmode.watchdog")
    let runner = WatchdogRunner(paths: paths, backend: backend, signaller: SystemWatchdogSignaller(),
                                log: log, config: config)
    let interval = Duration.milliseconds(config.watchdog.intervalMs)
    Task { @MainActor in
        while true {
            if await runner.tick() == .exit { exit(0) }
            try? await Task.sleep(for: interval)
        }
    }
    parkInAppEventLoop()
}
