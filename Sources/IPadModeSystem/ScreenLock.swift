import Foundation
import CoreGraphics
import IPadModeCore

/// True when the session is locked: `CGSSessionScreenIsLocked` is truthy, or the session is not on the console
/// (`kCGSSessionOnConsoleKey` present and false: switched away, treated as locked, the safe direction).
public func isScreenLocked(sessionInfo: [String: Any]) -> Bool {
    func truthy(_ v: Any) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        return false
    }
    if let locked = sessionInfo["CGSSessionScreenIsLocked"], truthy(locked) { return true }
    if let onConsole = sessionInfo["kCGSSessionOnConsoleKey"], !truthy(onConsole) { return true }
    return false
}

/// Reads the lock state live on every access (the Coordinator polls it each second) and reports the distributed
/// lock/unlock notifications as events. No GUI session (`CGSessionCopyCurrentDictionary` nil) counts as locked.
@MainActor public final class ScreenLockMonitor: ScreenLockProvider {
    private var observers: [NSObjectProtocol] = []

    public init(onChange: @escaping @MainActor (SystemEvent) -> Void) {
        let center = DistributedNotificationCenter.default()
        for (name, event) in [("com.apple.screenIsLocked", SystemEvent.screenLocked),
                              ("com.apple.screenIsUnlocked", SystemEvent.screenUnlocked)] {
            // Hop with a Task: `MainActor.assumeIsolated` traps off the real main thread (R76).
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                Task { @MainActor in onChange(event) }
            })
        }
    }

    public var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return isScreenLocked(sessionInfo: info)
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for o in observers { center.removeObserver(o) }
    }
}
