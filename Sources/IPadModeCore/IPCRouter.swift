/// R49: what the daemon answers on its socket, mapped onto the Coordinator. The Dock applets show nothing themselves
/// and their stderr goes nowhere, so a refusal of Remote or Normal is also shown as a notice. A failure is not shown
/// again: the Coordinator has told it already.
@MainActor
public enum IPCRouter {
    /// `saveConfig` keeps a new resolution for later starts; `requestShutdown` ends the daemon once the answer is
    /// written (the disable path).
    public static func respond(_ request: IPCRequest, coordinator: Coordinator, notifier: Notifier, events: EventSink,
                               listDisplays: () throws -> [DisplayInfo], saveConfig: (Config) throws -> Void,
                               requestShutdown: () -> Void) async -> IPCResponse {
        events.record("ipc.request", ["request": name(of: request)])
        switch request {
        case .remote(let seconds):
            guard coordinator.state.phase != .active(.remote) else {
                notifier.notice(Messages.remoteAlreadyActive)
                return IPCResponse(result: .ok(Messages.remoteAlreadyActive))
            }
            return IPCResponse(result: showingRefusal(await coordinator.enterRemote(confirmSeconds: seconds), notifier))

        case .normal:
            let wasNormal = coordinator.state.phase == .normal
            let result = showingRefusal(await coordinator.exitToNormal(.user), notifier)
            // Already Normal with every monitor on, the Coordinator tells nothing: the click still gets its answer. A
            // monitor that stayed off it has told already (A-5).
            if wasNormal, result == .ok(Messages.backToNormal) { notifier.notice(Messages.backToNormal) }
            return IPCResponse(result: result)

        case .sidecar:
            return IPCResponse(result: .refused(.unsupported, Messages.sidecarUnsupported))

        case .status:
            return IPCResponse(result: .ok(""), state: coordinator.state, displays: try? listDisplays())

        case .resolution(let text):
            guard let resolution = Resolution(parsing: text) else {
                return IPCResponse(result: .refused(.invalid, Messages.resolutionInvalid))
            }
            let result = await coordinator.setResolution(resolution)
            if case .ok = result {
                // Not saved, it still holds until the daemon restarts (R5).
                do { try saveConfig(coordinator.config) } catch {
                    events.record("config.save.failed", ["error": "\(error)"])
                }
            }
            return IPCResponse(result: result)

        case .shutdownForDisable:
            if coordinator.state.phase != .normal { _ = await coordinator.exitToNormal(.disable) }
            // Never ends the daemon away from Normal: it stays and keeps guarding, and the disabled marker the CLI has
            // written makes its next start reconcile and exit.
            guard coordinator.state.phase == .normal else { return IPCResponse(result: .failed(Messages.exitFailed)) }
            do { try coordinator.markCleanShutdown() } catch {
                events.record("daemon.clean.failed", ["error": "\(error)"])
            }
            requestShutdown()
            return IPCResponse(result: .ok(Messages.disabled))
        }
    }

    /// The request's case, without its values: what `ipc.request` records.
    static func name(of request: IPCRequest) -> String {
        switch request {
        case .remote: "remote"
        case .sidecar: "sidecar"
        case .normal: "normal"
        case .status: "status"
        case .resolution: "resolution"
        case .shutdownForDisable: "shutdownForDisable"
        }
    }

    private static func showingRefusal(_ result: CommandResult, _ notifier: Notifier) -> CommandResult {
        if case .refused(_, let text) = result { notifier.notice(text) }
        return result
    }
}
