import IPadModeCore

/// The values Gate R decided (docs/research/spikes.md).
public enum IPadModeDefaults {
    /// SP2: on this Mac a `.forAppOnly` change is not undone when the process dies, so every change is session-wide;
    /// after a crash the watchdog and the vdisplay child (R25) undo it.
    public static let configScope: ConfigScope = .session
    /// SP3: after a 1 s pause the RustDesk client had moved to the new display.
    public static let settleDelay: Duration = .seconds(1)
}
