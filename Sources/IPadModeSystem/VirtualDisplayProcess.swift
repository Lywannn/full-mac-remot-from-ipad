import Foundation
import CoreGraphics
import Darwin
import CPrivateDisplay
import IPadModeCore

/// How each role's virtual display looks to macOS (Global Constraints, spec §7.9). Only the name and the product
/// and serial numbers differ between roles. The vendor is ours, so the classifier reports them as `.ownVirtual`.
enum VirtualDisplaySpec {
    struct Identity: Equatable {
        var name: String
        var productID: UInt32
        var serial: UInt32
    }

    static let vendorID: UInt32 = DisplayClassifier.ownVendor
    static let widthMM = 227.0, heightMM = 158.0
    static let maxPixelsWide: UInt32 = 3304, maxPixelsHigh: UInt32 = 2296
    static let hiDPI = true
    static let refreshHz = 60.0

    static func identity(_ role: VirtualRole) -> Identity {
        switch role {
        case .remote: Identity(name: "iPad Remote", productID: 0x0001, serial: 0x1A1D_0001)
        case .anchor: Identity(name: "iPad Jangkar", productID: 0x0002, serial: 0x1A1D_0002)
        case .fallback: Identity(name: "iPad Cadangan", productID: 0x0003, serial: 0x1A1D_0003)
        }
    }

    /// Every allowed size, `requested` first: macOS makes the first mode the active one (SP1).
    static func modeOrder(requested: Resolution) -> [Resolution] {
        [requested] + Resolution.allowed.filter { $0 != requested }
    }

    /// The mode R28 selects: `r` in points, twice that in pixels (HiDPI), 60 Hz; the Coordinator keeps the same one
    /// (A-3).
    static func mode(_ r: Resolution) -> DisplayMode { r.remoteMode }

    /// Whether `m` is that mode; its refresh may be off by up to 0.5 Hz.
    static func isMode(_ m: DisplayMode, of r: Resolution) -> Bool { m.isSameMode(as: mode(r)) }
}

/// The `ipadmode vdisplay` process (spec §7.1). It owns one virtual display, which macOS removes when this process
/// ends. It prints exactly one line on stdout: `READY <id>` once the display is online in the requested mode (R28),
/// or `ERROR <reason>`, and then it exits 1. After READY it waits:
/// - SIGTERM, the daemon's normal stop: it releases the display and exits 0. The daemon has turned the monitors on.
/// - The parent ends, so the daemon died: nobody else may turn the monitors back on, so it does that first (R25),
///   then exits 0, which releases the display. From then on a SIGTERM is ignored: R25 ends by its own decision, at
///   the latest after 6 s.
/// With `IPADMODE_VDISPLAY_DRY_RUN=1` it creates no display and changes nothing: it prints `READY 4242` at once,
/// then waits and ends as above, only logging the monitors it would turn on. Tests run the real binary that way.
/// Diagnostics go to stderr. Must be called on the main thread.
public func runVirtualDisplayProcess(role: VirtualRole, resolution: Resolution, parentPID: Int32) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    // The daemon may be gone by the time we print: a write to its closed pipe must fail, not end us before R25.
    signal(SIGPIPE, SIG_IGN)
    let dryRun = ProcessInfo.processInfo.environment[VirtualDisplayChild.dryRunVariable] == "1"
    let child = MainActor.assumeIsolated {
        VirtualDisplayChild(role: role, resolution: resolution, parentPID: parentPID, dryRun: dryRun)
    }
    MainActor.assumeIsolated { child.start() }
    // The real main thread stays, in an AppKit event loop: see `parkInAppEventLoop` (C1, R75).
    withExtendedLifetime(child) { MainActor.assumeIsolated { parkInAppEventLoop() } }
}

@MainActor
final class VirtualDisplayChild {
    /// R28: how long the new display may take to be online with the requested mode listed.
    nonisolated static let onlineTimeout: Duration = .seconds(3)
    /// R28: how long the selected mode may take to become the active one.
    nonisolated static let modeTimeout: Duration = .seconds(2)
    nonisolated static let pollInterval: TimeInterval = 0.1
    /// Set to 1, the child creates no display and changes nothing (tests).
    nonisolated static let dryRunVariable = "IPADMODE_VDISPLAY_DRY_RUN"
    /// What a dry run reports as its display.
    nonisolated static let dryRunDisplayID = DisplayID(raw: 4242)

    private let role: VirtualRole
    private let resolution: Resolution
    private let parentPID: Int32
    private let dryRun: Bool
    private let backend = CGDisplayBackend()
    private var display: UnsafeMutableRawPointer?
    /// The SIGTERM and parent watches: a source is cancelled when it is released.
    private var sources: [DispatchSourceProtocol] = []
    /// R25 under way, from when the parent is found gone: its 100 ms timer and where its decisions stand.
    private var restore: Restore?

    private struct Restore {
        let timer: DispatchSourceTimer
        let started: ContinuousClock.Instant
        var state = R25Decision.State()
    }

    init(role: VirtualRole, resolution: Resolution, parentPID: Int32, dryRun: Bool) {
        self.role = role; self.resolution = resolution; self.parentPID = parentPID; self.dryRun = dryRun
    }

    /// Returns once READY is printed, or at once when the parent was gone already (R25 then runs, and no display is
    /// made); every failure exits.
    func start() {
        watchForSIGTERM()
        watchParent()
        guard restore == nil else { return }
        guard PrivateAPI.allAvailable else { fail("private-api-unavailable") }
        if dryRun {
            log("dry run: no display")
            emit(VDisplayProtocol.readyLine(Self.dryRunDisplayID))
            return
        }
        let id = createDisplay()
        selectMode(id)
        emit(VDisplayProtocol.readyLine(DisplayID(raw: id)))
    }

    private func createDisplay() -> CGDirectDisplayID {
        let identity = VirtualDisplaySpec.identity(role)
        let modes = VirtualDisplaySpec.modeOrder(requested: resolution).map {
            IPMModeSpec(widthPoints: UInt32($0.width), heightPoints: UInt32($0.height),
                        refreshHz: VirtualDisplaySpec.refreshHz)
        }
        var id: CGDirectDisplayID = kCGNullDirectDisplay
        display = IPMVirtualDisplayCreate(identity.name, VirtualDisplaySpec.vendorID, identity.productID,
                                          identity.serial, VirtualDisplaySpec.widthMM, VirtualDisplaySpec.heightMM,
                                          VirtualDisplaySpec.maxPixelsWide, VirtualDisplaySpec.maxPixelsHigh,
                                          VirtualDisplaySpec.hiDPI, modes, Int32(modes.count), &id)
        guard display != nil, id != kCGNullDirectDisplay else { fail("create-failed") }
        return id
    }

    /// R28: macOS may bring the display up in the mode last chosen for this identity in System Settings (SP3), so
    /// the requested mode is selected explicitly, then checked. Session scope, not app-only (A-3): an app-only choice
    /// passed this check, but macOS put the remembered mode back as soon as the daemon made a session transaction of
    /// its own (acceptance A1). The display still ends with us; the Coordinator checks the mode again before it turns
    /// the monitors off.
    private func selectMode(_ id: CGDirectDisplayID) {
        var online = false
        let listed = pumpUntil(Self.onlineTimeout) {
            online = (try? backend.listDisplays())?.contains { $0.id.raw == id && $0.isOnline } == true
            return online && Self.modes(of: id).contains { VirtualDisplaySpec.isMode($0, of: resolution) }
        }
        guard listed else { fail(online ? "mode-unavailable" : "not-online") }
        do {
            try backend.setMode(DisplayID(raw: id), VirtualDisplaySpec.mode(resolution), scope: .session)
        } catch {
            fail("set-mode-failed", detail: "\(error)")
        }
        let applied = pumpUntil(Self.modeTimeout) {
            Self.activeMode(of: id).map { VirtualDisplaySpec.isMode($0, of: resolution) } ?? false
        }
        guard applied else { fail("mode-not-applied", detail: "active \(String(describing: Self.activeMode(of: id)))") }
    }

    // MARK: Watches

    private func watchForSIGTERM() {
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { self.terminated() } }
        source.activate()
        sources.append(source)
        // Ignored only once the source is armed: until here a SIGTERM still ends us by its default action.
        signal(SIGTERM, SIG_IGN)
    }

    /// The `--parent` PID, which need not be our real parent.
    private func watchParent() {
        let source = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { self.parentEnded() } }
        source.activate()
        sources.append(source)
        if parentIsGone() { parentEnded() }   // it ended before the watch was armed
    }

    /// Gone, or launchd has adopted us: the daemon was our real parent.
    private func parentIsGone() -> Bool {
        (kill(parentPID, 0) != 0 && errno == ESRCH) || getppid() == 1
    }

    /// SIGTERM, the daemon's normal stop: it has turned the monitors on already (I3), so release and exit 0. Once the
    /// parent is gone, though, R25 is due and must not be cut short: the SIGTERM is ignored, also when it got here
    /// before the parent's end did.
    private func terminated() {
        if restore == nil, parentIsGone() { parentEnded() }
        guard restore == nil else {
            log("SIGTERM while turning the monitors back on: ignored")
            return
        }
        log("SIGTERM: releasing the display")
        releaseAndExit(0)
    }

    /// R25 (amended), the daemon is gone and nobody else may turn the monitors back on. It starts a 100 ms timer on
    /// the main queue and returns: between the ticks the event loop keeps serving that queue, and with it the
    /// virtual display, whose callbacks a reconfiguration involving it waits for (N2). Starting it again does nothing.
    private func parentEnded() {
        guard restore == nil else { return }
        log("parent \(parentPID) ended; turning the monitors back on")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval)
        timer.setEventHandler { MainActor.assumeIsolated { self.restoreTick() } }
        restore = Restore(timer: timer, started: .now)
        timer.activate()
    }

    /// One R25 poll: list the displays and do what `R25Decision` says. Enabling is session scope: an app-only change
    /// would not outlive us.
    private func restoreTick() {
        guard var restore else { return }
        let elapsed = restore.started.duration(to: .now)
        let step = R25Decision.next(displays: try? backend.listDisplays(), elapsed: elapsed, state: restore.state)
        restore.state = step.state
        self.restore = restore
        switch step.action {
        case .release:
            let why = elapsed >= R25Decision.deadline ? "not every monitor is back after \(R25Decision.deadline)"
                : step.state.headlessStreak >= R25Decision.headlessListings ? "no physical monitor"
                : "every monitor is back"
            log("releasing the display: \(why)")
            releaseAndExit(0)
        case .enable(let ids):
            enable(ids)
        case .wait:
            break
        }
    }

    /// The batch, then after it failed each monitor alone (R69); each failure is logged. A dry run changes nothing
    /// and only says what it would do.
    private func enable(_ ids: [DisplayID]) {
        if dryRun {
            log("dry run: would enable \(Self.text(ids))")
            return
        }
        _ = backend.enableMonitors(ids, scope: .session) { failed, error in
            log("enabling \(Self.text(failed)) failed: \(error)")
        }
    }

    // MARK: Helpers

    /// Checks `condition` now and then every 100 ms until it holds or `timeout` has passed, running the main run
    /// loop in between, so that the main queue, where the display and the watches deliver their events, is served
    /// meanwhile too.
    private func pumpUntil(_ timeout: Duration, _ condition: () -> Bool) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: Self.pollInterval))
        }
        return true
    }

    private static func modes(of id: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return ((CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []).map(CGDisplayBackend.describe)
    }

    private static func text(_ ids: [DisplayID]) -> String { ids.map { "\($0.raw)" }.joined(separator: ",") }

    private static func activeMode(of id: CGDirectDisplayID) -> DisplayMode? {
        CGDisplayCopyDisplayMode(id).map(CGDisplayBackend.describe)
    }

    private func fail(_ reason: String, detail: String? = nil) -> Never {
        log("ERROR \(reason)" + (detail.map { ": \($0)" } ?? ""))
        emit(VDisplayProtocol.errorLine(reason))
        // R25 began meanwhile: it ends this process by its own decision and must not be cut short.
        if restore != nil { parkInAppEventLoop() }
        releaseAndExit(1)
    }

    /// The one line on stdout, flushed at once.
    private func emit(_ line: String) {
        fputs(line, stdout)
        fflush(stdout)
    }

    private func log(_ message: String) {
        fputs("ipadmode vdisplay[\(getpid())] \(role.rawValue): \(message)\n", stderr)
    }

    private func releaseAndExit(_ status: Int32) -> Never {
        if let display { IPMVirtualDisplayRelease(display) }
        display = nil
        exit(status)
    }
}
