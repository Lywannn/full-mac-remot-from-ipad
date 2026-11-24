import AppKit
import CoreGraphics
import Darwin
import IPadModeCore

/// The daemon (spec §7.1): the only process that changes the display configuration in normal operation. Its decisions
/// are in the Coordinator and `DaemonLifecycle` (IPadModeCore); this file wires them to the system, in the order of
/// R48.
/// - It parks in `NSApp.run()` on the main thread for its whole life: CoreGraphics in a process that makes display
///   transactions of its own sees other processes' changes only through an AppKit event loop (R75), the panels need
///   one, and every wait is an `await`, so the loop keeps running meanwhile (R74).
/// - Exit statuses (R50): 0 only for a duplicate and at the end of the disabled path, the ends that launchd
///   (KeepAlive SuccessfulExit=false) must not undo; 143 after SIGTERM or SIGINT; 1 if the event loop ever returns.
///   launchd restarts every non-zero end, crashes included.
/// Call it from synchronous top-level code on the real main thread, inside `MainActor.assumeIsolated`: never from an
/// async context, and never with `dispatchMain()` (R57, R71).
@MainActor public func runDaemon(paths: Paths) -> Never {
    precondition(Thread.isMainThread, "the daemon runs on the main thread")
    // R48 steps 1–5. Step 6, the App Nap activity, is held by main.swift for every role (R77).
    signal(SIGPIPE, SIG_IGN)
    createDirectories(paths)
    let events = EventLog(directory: paths.logs)
    let disabled = FileManager.default.fileExists(atPath: paths.disabledMarker.path)
    events.record("daemon.start", ["pid": "\(getpid())", "disabled": "\(disabled)"])
    NSApplication.shared.setActivationPolicy(.accessory)
    let (config, warnings) = ConfigLoader.load(from: paths.config)
    for warning in warnings { events.record("config.warning", ["warning": warning]) }
    // Step 7, before anything slow: a restore at startup may take longer than the watchdog's 5 s.
    let heartbeat = HeartbeatTimer(url: paths.heartbeat, events: events)
    // Step 8.
    let daemon = Daemon(paths: paths, config: config, events: events, heartbeat: heartbeat)
    daemon.claimSocket(serving: !disabled)
    daemon.watchSignals()
    // Steps 9–12 run in the event loop.
    Task { @MainActor in
        if disabled {
            await daemon.lifecycle.runDisabled()
            daemon.end(0, why: "disabled")
        }
        await daemon.lifecycle.start()
        daemon.installEventSources()
    }
    withExtendedLifetime(daemon) { NSApp.run() }
    exit(1)
}

/// What the daemon keeps for its whole life, from R48 step 8 on.
@MainActor private final class Daemon {
    /// R50: how long the way back to Normal may take after a signal; launchd's ExitTimeOut (12 s) comes next.
    private static let shutdownDeadline: DispatchTimeInterval = .seconds(8)
    /// R49: how long after its answer `shutdownForDisable` ends the daemon, so that the answer is written first.
    private static let disableExitDelay: DispatchTimeInterval = .milliseconds(300)
    /// R52: the hotkey when the configured one does not parse.
    private static let fallbackHotkey = "ctrl+opt+cmd+n"

    private let paths: Paths
    private let events: EventLog
    private let heartbeat: HeartbeatTimer
    private let backend: CGDisplayBackend
    private let host: ChildProcessVirtualDisplayHost
    private let notices: NoticePanel
    private let lock: ScreenLockMonitor
    private let lockEvents: LockEvents
    private let coordinator: Coordinator
    private(set) lazy var lifecycle = DaemonLifecycle(
        coordinator: coordinator, backend: backend, notifier: notices, events: events, paths: paths,
        clock: ContinuousClock(), stopStale: { [host] in await host.stopStale() },
        exitAfterDisable: { [weak self] in self?.endAfterDisable() })
    private var server: SocketServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var deadline: DispatchSourceTimer?
    private var displayChanges: DisplayChangeSource?
    private var ticker: DispatchSourceTimer?
    private var hotkey: HotkeyRegistrar?

    init(paths: Paths, config: Config, events: EventLog, heartbeat: HeartbeatTimer) {
        let backend = CGDisplayBackend()
        let clock = ContinuousClock()
        let host = ChildProcessVirtualDisplayHost(executable: Self.executable, backend: backend,
                                                  pidDirectory: paths.support, clock: clock)
        let notices = NoticePanel()
        let lockEvents = LockEvents()
        let lock = ScreenLockMonitor(onChange: { lockEvents.send($0) })
        let coordinator = Coordinator(
            backend: backend, virtualHost: host, lock: lock, confirmer: ConfirmPanel(), notifier: notices,
            events: events, store: FileStateStore(url: paths.state), clock: clock, config: config,
            capabilities: Capabilities(privateAPIs: PrivateAPI.allAvailable), scope: IPadModeDefaults.configScope,
            settleDelay: IPadModeDefaults.settleDelay)
        self.paths = paths; self.events = events; self.heartbeat = heartbeat; self.backend = backend
        self.host = host; self.notices = notices; self.lock = lock; self.lockEvents = lockEvents
        self.coordinator = coordinator
    }

    /// This binary: each virtual display runs in an `ipadmode vdisplay` child of it.
    private static var executable: URL {
        Bundle.main.executableURL
            ?? URL(fileURLWithPath: VirtualDisplayProcessCheck.executablePath(getpid()) ?? CommandLine.arguments[0])
    }

    /// R48 step 8: once the Coordinator exists, before the reconcile. A live daemon that answers on the socket owns the
    /// Mac: this one records that and exits 0 without touching a display. With the disabled marker set, the socket is
    /// only checked that way, then removed, and never served (R48b). Any other failure leaves the daemon without
    /// commands, but it still reconciles, guards the mode and takes the hotkey.
    func claimSocket(serving: Bool) {
        let server: SocketServer
        do {
            server = try SocketServer(path: paths.socket) { [weak self] request in
                guard let self else { return IPCResponse(result: .refused(.busy, Messages.busy)) }
                return await self.lifecycle.respond(request)
            }
        } catch SocketServerError.alreadyRunning {
            events.record("daemon.duplicate", [:])
            exit(0)
        } catch {
            events.record("socket.failed", ["error": "\(error)"])
            return
        }
        if serving { self.server = server } else { server.stop() }
    }

    /// R50: SIGTERM and SIGINT end the daemon by way of Normal. Each source is armed before the signal's default
    /// action is switched off; until then a signal still ends the daemon as it always did.
    func watchSignals() {
        for (number, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.signalled(name) } }
            source.activate()
            signalSources.append(source)
            signal(number, SIG_IGN)
        }
    }

    /// R48 step 12, R54: once the startup has run.
    func installEventSources() {
        lockEvents.receiver = { [weak self] event in
            guard let self else { return }
            Task { await self.coordinator.handle(event) }
        }
        displayChanges = DisplayChangeSource(events: events) { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.handle(.displaysChanged) }
        }
        ticker = mainQueueTimer(every: .seconds(1)) { [weak self] in
            guard let self else { return }
            Task { await self.lifecycle.tick() }
        }
        hotkey = makeHotkey()
        server?.start()
        events.record("daemon.ready", [:])
    }

    /// Ends the daemon with `status`. The socket file goes first, so that a CLI meanwhile is told the daemon is down.
    func end(_ status: Int32, why: String) -> Never {
        server?.stop()
        events.record("daemon.exit", ["status": "\(status)", "why": why])
        exit(status)
    }

    /// The first signal: back to Normal, then exit 143; or exit 143 after 8 s, whatever the way back is doing then.
    /// Later signals are ignored.
    private func signalled(_ name: String) {
        guard lifecycle.beginShutdown(signal: name) else { return }
        armDeadline()
        Task { @MainActor in
            await self.lifecycle.finishShutdown()
            self.end(143, why: name)
        }
    }

    /// Off the main queue, so that it fires even while the main thread is stuck. It ends the process with `_exit`, not
    /// `exit` (B-2): `exit` would run the atexit handlers and tear stdio down on this queue, concurrently with whatever
    /// the main thread is doing, `end(143)` included.
    private func armDeadline() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + Self.shutdownDeadline)
        let events = self.events
        timer.setEventHandler {
            events.record("daemon.exit", ["status": "143", "why": "deadline"])
            _exit(143)
        }
        timer.activate()
        deadline = timer
    }

    /// R49: `shutdownForDisable` was answered; the daemon ends with 0 once the answer is written.
    private func endAfterDisable() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.disableExitDelay) {
            MainActor.assumeIsolated { self.end(0, why: "disable") }
        }
    }

    /// R52: the configured hotkey, or ⌃⌥⌘N when it does not parse. Without one the daemon still runs, and says so
    /// (B-11): the user should not find out only when they need it.
    private func makeHotkey() -> HotkeyRegistrar? {
        let configured = coordinator.config.hotkey
        let parsed = HotkeySpec(parsing: configured)
        if parsed == nil {
            events.record("config.warning",
                          ["warning": "hotkey \"\(configured)\" is not valid; using \(Self.fallbackHotkey)"])
        }
        let registrar = HotkeyRegistrar(spec: parsed ?? HotkeySpec(parsing: Self.fallbackHotkey)!) { [weak self] in
            guard let self else { return }
            Task { await self.lifecycle.hotkeyPressed() }
        }
        if registrar == nil {
            events.record("hotkey.unavailable", ["hotkey": parsed == nil ? Self.fallbackHotkey : configured])
            notices.notice(Messages.hotkeyUnavailable)
        }
        return registrar
    }
}

/// Lock events go to the Coordinator only once the event sources are installed (R54); until then, and in the
/// disabled path, they are dropped: the startup reconcile ends any mode anyway.
@MainActor private final class LockEvents {
    var receiver: (@MainActor (SystemEvent) -> Void)?

    func send(_ event: SystemEvent) {
        receiver?(event)
    }
}

/// R48 step 7: the heartbeat the watchdog reads, written each second on the main queue, so that it stops when the main
/// thread hangs, and the watchdog then ends this daemon (§7.8 L4). It beats once the event loop runs: a duplicate that
/// exits at step 8 never overwrites the live daemon's heartbeat.
@MainActor private final class HeartbeatTimer {
    private let url: URL
    private let events: EventSink
    private var timer: DispatchSourceTimer?
    private var failing = false

    init(url: URL, events: EventSink) {
        self.url = url
        self.events = events
        timer = mainQueueTimer(every: .seconds(1), first: .now()) { [weak self] in self?.beat() }
    }

    private func beat() {
        do {
            try Heartbeat.now(pid: getpid()).write(url)
            failing = false
        } catch {
            if !failing { events.record("heartbeat.failed", ["error": "\(error)"]) }   // once per failing stretch
            failing = true
        }
    }
}

/// R54: display reconfigurations, registered on the main thread. CoreGraphics calls back there, also from inside the
/// daemon's own transactions, so the callback only pushes back a 250 ms timer, and `onChange` runs once when that
/// fires. The calls that announce a change to come (`beginConfigurationFlag`) are ignored.
@MainActor private final class DisplayChangeSource {
    private static let debounce: DispatchTimeInterval = .milliseconds(250)
    private let timer: DispatchSourceTimer

    init(events: EventSink, onChange: @escaping @MainActor () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { MainActor.assumeIsolated { onChange() } }
        timer.activate()
        let error = CGDisplayRegisterReconfigurationCallback(displayReconfigured,
                                                             Unmanaged.passUnretained(self).toOpaque())
        // Without it, the 1 s tick still sees every change, only later.
        if error != .success { events.record("display.callback.failed", ["error": "\(error.rawValue)"]) }
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        timer.cancel()
    }

    fileprivate func changed() {
        timer.schedule(deadline: .now() + Self.debounce)
    }
}

/// Never acts inside the CoreGraphics call that reports the change: it hops to the main queue first.
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                                 _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
    let source = Unmanaged<DisplayChangeSource>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { MainActor.assumeIsolated { source.changed() } }
}

/// A repeating timer on the main queue, which the event loop serves also while a panel tracks the mouse (R54). It
/// first fires at `first`, by default one interval from now.
@MainActor private func mainQueueTimer(every interval: DispatchTimeInterval, first: DispatchTime? = nil,
                                       _ action: @escaping @MainActor () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: first ?? .now() + interval, repeating: interval, leeway: .milliseconds(100))
    timer.setEventHandler { MainActor.assumeIsolated { action() } }
    timer.activate()
    return timer
}

/// R48 step 2. The support directory holds the socket and the state: only its owner may enter it.
private func createDirectories(_ paths: Paths) {
    let files = FileManager.default
    try? files.createDirectory(at: paths.support, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    _ = chmod(paths.support.path, 0o700)
    try? files.createDirectory(at: paths.logs, withIntermediateDirectories: true)
}
