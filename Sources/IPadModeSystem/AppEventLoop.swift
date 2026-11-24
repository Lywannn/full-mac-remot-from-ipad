import AppKit

/// Serves the main queue, and with it the main actor, on the real main thread, for good, inside an AppKit event loop:
/// how a long-running role (the `vdisplay` child, the watchdog) ends its setup.
/// - Not `dispatchMain()`: it ends the main thread, and main-queue work then runs on a worker thread, where
///   `MainActor.assumeIsolated` traps. SwiftPM records SDK 14.0 in this binary, so the Swift runtime uses its legacy
///   executor check, which accepts the MainActor only on the main thread (C1).
/// - Not a bare `CFRunLoopRun()`: once a process has made a display-configuration transaction of its own,
///   CoreGraphics in it stops seeing the display changes other processes make, and only an AppKit event loop, or
///   another transaction, refreshes it (R75, the `staleview` experiment). The child (R28's setMode, R25's
///   enables) and the watchdog (its restore) both make such transactions.
/// `.prohibited`: no Dock icon, no menu bar, no window. Should the loop ever return, the process exits 1.
@MainActor func parkInAppEventLoop() -> Never {
    precondition(Thread.isMainThread, "the event loop runs on the main thread")
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApp.run()
    exit(1)
}
