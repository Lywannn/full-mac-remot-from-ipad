import Foundation
import CoreGraphics
import IPadModeCore
import IPadModeSystem

/// The short-lived commands. All synchronous; success text goes to stdout, failures to stderr.
enum CLI {
    static func run(_ command: Command, paths: Paths) -> ExitCode {
        switch command {
        case .remote(let seconds): return viaSocket(.remote(confirmSeconds: seconds), paths)
        case .sidecar: return viaSocket(.sidecar, paths)
        case .normal: return viaSocket(.normal, paths)
        case .resolution(let value):
            guard Resolution(parsing: value) != nil else { return fail(Messages.resolutionInvalid, .usage) }
            return viaSocket(.resolution(value), paths)
        case .status(let json, let offline): return status(json: json, offline: offline, paths)
        case .doctor: return doctor(paths)
        case .logs: return logs(paths)
        case .disable: return disable(paths)
        case .enable: return enable(paths)
        case .daemon, .watchdog, .vdisplay: return .usage   // handled in main.swift
        }
    }

    // MARK: output

    @discardableResult static func fail(_ text: String, _ code: ExitCode) -> ExitCode {
        fputs(text + "\n", stderr)
        return code
    }

    static func report(_ result: CommandResult) -> ExitCode {
        switch result {
        case .ok(let text): print(text); return .ok
        case .refused(let reason, let text): return fail(text, reason == .unsupported ? .unsupported : .refused)
        case .failed(let text): return fail(text, .failed)
        }
    }

    // MARK: socket

    enum Sent { case response(IPCResponse), down, busy, invalid }

    static func attempt(_ request: IPCRequest, _ paths: Paths, timeout: Duration) -> Sent {
        do { return .response(try SocketClient.send(request, path: paths.socket, timeout: timeout)) }
        catch SocketClientError.notRunning { return .down }
        catch SocketClientError.timeout { return .busy }   // alive but busy: never kickstart
        catch { return .invalid }
    }

    /// Asks the daemon, waiting for its answer as long as `CLIParsing.socketTimeout(for:)` says (B-9); when nothing
    /// listens, kicks it once, waits 3 s and asks again (R60).
    static func send(_ request: IPCRequest, _ paths: Paths) -> Sent {
        let timeout = CLIParsing.socketTimeout(for: request)
        var sent = attempt(request, paths, timeout: timeout)
        if case .down = sent {
            _ = ExternalCommand.run("/bin/launchctl", ["kickstart", Agents.domain(Agents.daemonLabel)])
            Thread.sleep(forTimeInterval: 3)
            sent = attempt(request, paths, timeout: timeout)
        }
        return sent
    }

    /// While the disabled marker exists, socket commands stop here: no kickstart, no daemon.
    static func disabledGate(_ paths: Paths) -> ExitCode? {
        FileManager.default.fileExists(atPath: paths.disabledMarker.path) ? fail(Messages.disabled, .daemonDown) : nil
    }

    static func viaSocket(_ request: IPCRequest, _ paths: Paths) -> ExitCode {
        if let stop = disabledGate(paths) { return stop }
        switch send(request, paths) {
        case .response(let r): return report(r.result)
        case .down: return fail(Messages.daemonDown, .daemonDown)
        case .busy: return fail(Messages.busy, .busy)
        case .invalid: return fail(Messages.daemonReplyFailed, .badReply)
        }
    }

    // MARK: status

    static func liveness(_ beat: Heartbeat?, now: UInt64) -> ProcessLiveness? {
        beat.map { ProcessLiveness(pid: $0.pid, age: $0.age(nowNanos: now)) }
    }

    static func status(json: Bool, offline: Bool, _ paths: Paths) -> ExitCode {
        var response: IPCResponse
        if offline {
            response = IPCResponse(result: .ok(""), state: FileStateStore(url: paths.state).load(), displays: WatchdogFiles.readDisplays(at: paths.displays)?.displays ?? [])
        } else {
            if let stop = disabledGate(paths) { return stop }
            switch send(.status, paths) {
            case .response(let r):
                guard case .ok = r.result else { return report(r.result) }
                guard r.state != nil else { return fail(Messages.invalidStatusResponse, .badReply) }
                response = r
            case .down: return fail(Messages.daemonDown, .daemonDown)
            case .busy: return fail(Messages.busy, .busy)
            case .invalid: return fail(Messages.daemonReplyFailed, .badReply)
            }
        }
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(response) else { return fail(Messages.invalidStatusResponse, .badReply) }
            print(String(decoding: data, as: UTF8.self))
            return .ok
        }
        // Files first, then the clock (R37).
        let daemonBeat = Heartbeat.read(paths.heartbeat), watchdogBeat = Heartbeat.read(paths.watchdogHeartbeat)
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        // nil outside the GUI session (SSH): the lock state is unknown.
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any]).map(isScreenLocked(sessionInfo:))
        print(StatusFormatter.text(response.state ?? .initial, displays: response.displays ?? [], locked: locked,
                                   daemon: liveness(daemonBeat, now: now), watchdog: liveness(watchdogBeat, now: now),
                                   stateKnown: response.state != nil))
        return .ok
    }

    // MARK: doctor, logs

    static func doctor(_ paths: Paths) -> ExitCode {
        let report = runDoctor(paths: paths)
        for line in report.lines { print(line.rendered) }
        return report.hasCriticalFailure ? .failed : .ok
    }

    static func logs(_ paths: Paths) -> ExitCode {
        for name in ["ipadmode", "watchdog"] {
            let file = paths.logs.appendingPathComponent(name + ".jsonl")
            print(Messages.logsHeader(name + ".jsonl"))
            if let lines = LogTail.lastLines(of: file, count: 50), !lines.isEmpty { lines.forEach { print($0) } }
            else { print(Messages.logsMissing) }
        }
        return .ok
    }

    // MARK: disable / enable (R62)

    static func disable(_ paths: Paths) -> ExitCode {
        let started = Date()
        // 1. Back to Normal, at most 30 s (B-9). A daemon that is down is skipped: the marker alone makes the watchdog
        // finish.
        var daemonUp = true
        switch attempt(.normal, paths, timeout: CLIParsing.socketTimeout(for: .normal)) {
        case .down: daemonUp = false
        case .response(let r):
            if case .ok = r.result {} else { fputs(Messages.disableNormalWarning + "\n", stderr) }
        case .busy, .invalid: fputs(Messages.disableNormalWarning + "\n", stderr)
        }
        // 2. The marker.
        do {
            try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try Data().write(to: paths.disabledMarker)
        } catch { return fail(Messages.markerWriteFailed(error.localizedDescription), .failed) }
        // 3. The daemon ends itself, after a way back of its own if it is not in Normal yet.
        if daemonUp, case .response(let r) = attempt(.shutdownForDisable, paths,
                                                     timeout: CLIParsing.socketTimeout(for: .shutdownForDisable)),
           case .failed(let text) = r.result {
            return fail(text, .failed)   // the marker stays: the next start reconciles and exits
        }
        // 4. Wait for a displays.json written after this command began that shows no offline physical monitor.
        let deadline = Date().addingTimeInterval(10)
        var verified = false
        while Date() < deadline {
            if DisableWait.isSettled(snapshot: WatchdogFiles.readDisplays(at: paths.displays), startedAt: started) { verified = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !verified { fputs(Messages.disableUnverified + "\n", stderr) }
        // 5.
        print(Messages.disabled)
        return .ok
    }

    static func enable(_ paths: Paths) -> ExitCode {
        if FileManager.default.fileExists(atPath: paths.disabledMarker.path) {
            do { try FileManager.default.removeItem(at: paths.disabledMarker) }
            catch { return fail(Messages.enableMarkerFailed, .failed) }
        }
        var allStarted = true, notLoaded = false
        for label in [Agents.watchdogLabel, Agents.daemonLabel] {
            let r = ExternalCommand.run("/bin/launchctl", ["kickstart", Agents.domain(label)])
            if r?.status == 113 { notLoaded = true }   // service not loaded
            // 37 = already running.
            if r == nil || (r!.status != 0 && r!.status != 37) { allStarted = false }
        }
        guard allStarted else { return fail(notLoaded ? Messages.enableNotInstalled : Messages.enableHint, .failed) }
        print(Messages.enabled)
        return .ok
    }
}
