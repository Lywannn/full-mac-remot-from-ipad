// Ports between the pure Coordinator and the system around it. The macOS adaptors live in
// IPadModeSystem; tests use fakes.

/// Reads and changes the display configuration. Each change is one transaction in the given scope.
@MainActor public protocol DisplayBackend: AnyObject {
    func listDisplays() throws -> [DisplayInfo]
    func setEnabled(_ ids: [DisplayID], enabled: Bool, scope: ConfigScope) throws
    func setOrigins(_ origins: [DisplayID: Point], scope: ConfigScope) throws
    func setMode(_ id: DisplayID, _ mode: DisplayMode, scope: ConfigScope) throws
}

public enum VirtualRole: String, Codable, Sendable { case remote, anchor, fallback }

public struct VirtualDisplayHandle: Codable, Equatable, Sendable {
    public var role: VirtualRole
    public var pid: Int32
    public var displayID: DisplayID

    public init(role: VirtualRole, pid: Int32, displayID: DisplayID) {
        self.role = role; self.pid = pid; self.displayID = displayID
    }
}

/// Owns the `vdisplay` child processes, one per virtual display.
@MainActor public protocol VirtualDisplayHost: AnyObject {
    /// Returns once the process reported READY and its display is active (≤5 s).
    func start(role: VirtualRole, resolution: Resolution) async throws -> VirtualDisplayHandle
    /// Returns once the process has ended and its display is gone.
    func stop(_ handle: VirtualDisplayHandle) async
}

@MainActor public protocol ScreenLockProvider: AnyObject {
    var isLocked: Bool { get }
}

public enum ConfirmOutcome: Equatable, Sendable { case keep, revert, timedOut, cancelled }

/// The "keep or revert" dialog shown on the new display.
@MainActor public protocol Confirmer: AnyObject {
    /// Waits for the answer; `.timedOut` after `seconds`.
    func confirm(seconds: Int) async -> ConfirmOutcome
    /// Closes the dialog; a waiting `confirm` returns `.cancelled`.
    func cancel()
}

/// Shows a short message to the user.
@MainActor public protocol Notifier: AnyObject {
    func notice(_ text: String)
}

public struct Capabilities: Sendable {
    /// The private display APIs resolved at runtime.
    public var privateAPIs: Bool

    public init(privateAPIs: Bool) { self.privateAPIs = privateAPIs }
}

/// Why the Coordinator returns to Normal; the reason picks the notice.
public enum ExitReason: String, Codable, Sendable {
    case user, hotkey, confirmRevert, confirmTimeout, locked, targetLost, failure, startup, disable
}

public enum SystemEvent: Equatable, Sendable { case displaysChanged, screenLocked, screenUnlocked, tick }
