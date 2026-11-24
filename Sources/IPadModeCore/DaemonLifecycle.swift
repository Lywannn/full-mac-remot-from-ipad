import Foundation

/// The daemon around its Coordinator (R48–R54): what runs once the Coordinator is built, the 1 s tick, the hotkey, the
/// socket's requests, a start with the disabled marker set, and the shutdown on a signal. The daemon's wiring in
/// IPadModeSystem installs the event sources and exits with the status each path ends in; tests use fakes.
@MainActor
public final class DaemonLifecycle {
    /// R48b: with the disabled marker set, the way back is tried again this often...
    static let disabledRetryInterval: Duration = .seconds(2)
    /// ...for up to this long; then the daemon ends anyway.
    static let disabledRetryWindow: Duration = .seconds(30)

    private let coordinator: Coordinator
    private let backend: DisplayBackend
    private let notifier: Notifier
    private let events: EventSink
    private let paths: Paths
    private let clock: any Clock<Duration>
    private let stopStale: @MainActor () async -> Void
    private let exitAfterDisable: @MainActor () -> Void

    /// From a signal or a `shutdownForDisable` on, no command but `status` is taken.
    public private(set) var isShuttingDown = false
    /// R48 step 10: the cleanup of stale vdisplay processes waits for a tick that finds Normal.
    public private(set) var staleCleanupPending = false
    private var tickRunning = false
    private var tickSkipLogged = false

    /// `stopStale` ends the vdisplay processes an earlier run left (the host's `stopStale`). `exitAfterDisable` ends
    /// the daemon with status 0 once the answer to `shutdownForDisable` is written.
    public init(coordinator: Coordinator, backend: DisplayBackend, notifier: Notifier, events: EventSink, paths: Paths,
                clock: any Clock<Duration>, stopStale: @escaping @MainActor () async -> Void,
                exitAfterDisable: @escaping @MainActor () -> Void) {
        self.coordinator = coordinator; self.backend = backend; self.notifier = notifier; self.events = events
        self.paths = paths; self.clock = clock; self.stopStale = stopStale; self.exitAfterDisable = exitAfterDisable
    }

    // MARK: Startup (R48 steps 9–11)

    /// Run once, before any event source is installed: the startup reconcile, the cleanup of stale vdisplay
    /// processes, and the watchdog's incident. The cleanup needs Normal with no vdisplay process recorded and a lit
    /// physical monitor, since a stale display may be the only active one while the monitors are not back (R33
    /// amended, A-4); otherwise the first tick that finds it so does it.
    public func start() async {
        await coordinator.reconcileAtStartup()
        if staleCleanupAllowed {
            await cleanUpStale()
        } else {
            staleCleanupPending = true
            events.record("stale.cleanup.pending", [:])
        }
        handleIncident()
    }

    // MARK: Event sources (R49, R52, R54)

    /// The 1 s tick, skipped while the last one still runs; then the pending stale cleanup, once Normal allows it.
    public func tick() async {
        guard !tickRunning else {
            if !tickSkipLogged {   // once per stuck stretch, not every second
                tickSkipLogged = true
                events.record("tick.skipped", [:])
            }
            return
        }
        tickRunning = true
        tickSkipLogged = false
        await coordinator.handle(.tick)
        tickRunning = false
        if staleCleanupPending, staleCleanupAllowed {
            staleCleanupPending = false
            await cleanUpStale()
        }
    }

    /// The emergency hotkey. Only a refusal is told here: the Coordinator tells every other outcome.
    public func hotkeyPressed() async {
        if case .refused(_, let text) = await coordinator.exitToNormal(.hotkey) { notifier.notice(text) }
    }

    /// A request from the socket. While shutting down only `status` is answered: anything else could start a
    /// transition that the exit would cut off. The refusal is shown too (B-3): a Dock click is never silent (R83).
    public func respond(_ request: IPCRequest) async -> IPCResponse {
        if isShuttingDown, request != .status {
            let name = IPCRouter.name(of: request)
            events.record("ipc.request", ["request": name])   // like every request (R49)
            events.record("ipc.refused", ["request": name, "reason": "shuttingDown"])
            notifier.notice(Messages.busy)
            return IPCResponse(result: .refused(.busy, Messages.busy))
        }
        let backend = self.backend, config = paths.config
        return await IPCRouter.respond(request, coordinator: coordinator, notifier: notifier, events: events,
                                       listDisplays: { try backend.listDisplays() },
                                       saveConfig: { try ConfigLoader.save($0, to: config) },
                                       requestShutdown: { [self] in
                                           isShuttingDown = true
                                           exitAfterDisable()
                                       })
    }

    // MARK: The disabled marker (R48b)

    /// The disabled marker is set: the daemon only brings the Mac back to Normal, then ends. After the startup
    /// reconcile, the way back is tried every 2 s for up to 30 s; once in Normal, stale vdisplay processes are
    /// stopped. Returns once the daemon may exit 0, its shutdown marked clean. A way back that never finished is left
    /// to the watchdog, which keeps restoring monitors while any is off, and to the next start.
    public func runDisabled() async {
        events.record("disabled.begin", [:])
        await coordinator.reconcileAtStartup()
        let elapsed = clock.stopwatch()
        while coordinator.state.phase != .normal, elapsed() < Self.disabledRetryWindow {
            do { try await clock.sleep(for: Self.disabledRetryInterval) } catch { break }
            events.record("disabled.retry", [:])
            _ = await coordinator.exitToNormal(.startup)
        }
        if staleCleanupAllowed {
            await cleanUpStale()
        } else {
            events.record("disabled.incomplete", ["phase": "\(coordinator.state.phase)"])
        }
        markClean()
        events.record("disabled.end", [:])
    }

    // MARK: Signals (R50)

    /// The first SIGTERM or SIGINT: recorded, and from then on no command but `status` is taken. False while a
    /// shutdown is under way already: the signal is ignored.
    public func beginShutdown(signal: String) -> Bool {
        guard !isShuttingDown else {
            events.record("daemon.signal.ignored", ["signal": signal])
            return false
        }
        isShuttingDown = true
        events.record("daemon.signal", ["signal": signal])
        return true
    }

    /// After `beginShutdown`: back to Normal unless there already, then the shutdown is marked clean. The daemon exits
    /// 143 next, whether the way back finished or not, and never 0: KeepAlive restarts only a non-zero exit, and the
    /// vdisplay child (R25) and the watchdog take over a way back that failed.
    public func finishShutdown() async {
        if coordinator.state.phase != .normal { _ = await coordinator.exitToNormal(.disable) }
        markClean()
    }

    // MARK: Helpers

    /// R33 amended, R46: stale vdisplay processes are stopped only in Normal, with none recorded in the state; and A-4,
    /// only once a physical monitor is listed online and active. Until then an orphan may still be in R25: turning
    /// the monitors back on, and showing the only display that is lit.
    private var staleCleanupAllowed: Bool {
        guard coordinator.state.phase == .normal, coordinator.state.virtualPID == nil else { return false }
        return (try? backend.listDisplays()).map(MonitorWakeWatch.isLit) ?? false
    }

    private func cleanUpStale() async {
        events.record("stale.cleanup", [:])
        await stopStale()
    }

    private func markClean() {
        do { try coordinator.markCleanShutdown() } catch {
            events.record("daemon.clean.failed", ["error": "\(error)"])
        }
    }

    /// R48 step 11: the watchdog restored the monitors while the daemon was gone. The user is told when it turned them
    /// on; the file goes either way.
    private func handleIncident() {
        let url = paths.incident
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let incident = (try? Data(contentsOf: url)).flatMap {
            try? WatchdogFiles.decoder().decode(WatchdogFiles.Incident.self, from: $0)
        }
        if incident?.enabledOK == true { notifier.notice(Messages.recovered) }
        var fields = incident.map {
            ["reason": $0.reason, "enabledOK": "\($0.enabledOK)", "layoutOK": "\($0.layoutOK)"]
        } ?? ["error": "unreadable"]
        if (try? FileManager.default.removeItem(at: url)) == nil { fields["removed"] = "false" }
        events.record("incident.seen", fields)
    }
}
