import Foundation

public enum DisableWait {
    /// True when displays.json was written since the command began and shows no offline physical monitor.
    /// The file's time is stored in whole seconds, so `startedAt` is compared at that precision: a same-second
    /// snapshot counts, because it only passes when it already shows Normal.
    public static func isSettled(snapshot: WatchdogFiles.DisplaysFile?, startedAt: Date) -> Bool {
        guard let snapshot else { return false }
        let floored = Date(timeIntervalSince1970: floor(startedAt.timeIntervalSince1970))
        return snapshot.time >= floored && !snapshot.displays.contains { $0.kind == .physical && !$0.isOnline }
    }
}
