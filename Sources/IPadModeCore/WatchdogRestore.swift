import Foundation

/// What the watchdog does to the layout: enable disabled physical monitors, then set origins.
public struct WatchdogRestorePlan: Equatable, Sendable {
    public var enable: [DisplayID]
    public var origins: [DisplayID: Point]

    /// `current` is the display list now. `enable` lists the offline physical monitors; `origins` only
    /// ever names ONLINE physical monitors (a transaction naming an offline one would fail as a whole).
    /// Without a usable baseline the lowest online physical ID goes to (0,0).
    public static func make(baseline: Snapshot?, current: [DisplayInfo]) -> WatchdogRestorePlan {
        let physical = current.filter { $0.kind == .physical }
        let online = Set(physical.filter(\.isOnline).map(\.id))
        let enable = physical.filter { !$0.isOnline }.map(\.id).sorted { $0.raw < $1.raw }

        if let baseline {
            let plan = RestorePlanner.plan(baseline: baseline, current: current)
            let origins = plan.origins.filter { online.contains($0.key) }
            if origins.values.contains(Point(x: 0, y: 0)) {
                return WatchdogRestorePlan(enable: enable, origins: origins)
            }
        }
        guard let first = online.min(by: { $0.raw < $1.raw }) else {
            return WatchdogRestorePlan(enable: enable, origins: [:])
        }
        return WatchdogRestorePlan(enable: enable, origins: [first: Point(x: 0, y: 0)])
    }
}

/// Which process the watchdog may signal.
public enum WatchdogPIDGuard {
    /// Why `pid` must never be signalled, or nil when it may be checked further.
    public static func refusal(pid: Int32, ownPID: Int32) -> String? {
        if pid <= 1 { return "pidTooLow" }
        if pid == ownPID { return "ownPID" }
        return nil
    }

    /// Only our own binary: the last path component is `ipadmode`.
    public static func isDaemonExecutable(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return (path as NSString).lastPathComponent == "ipadmode"
    }
}

/// Atomic JSON files the watchdog leaves behind (public wrapper over the internal atomic writer).
public enum WatchdogFiles {
    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
    public static func decoder() -> JSONDecoder {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return dec
    }

    public struct DisplaysFile: Codable, Equatable, Sendable {
        public var time: Date
        public var displays: [DisplayInfo]
    }
    public struct Incident: Codable, Equatable, Sendable {
        public var time: Date
        public var reason: String
        public var disabled: [String]
        public var enabledOK: Bool
        public var layoutOK: Bool
    }

    public static func writeDisplays(_ displays: [DisplayInfo], at time: Date, to url: URL) throws {
        try AtomicFile.write(try encoder().encode(DisplaysFile(time: time, displays: displays)), to: url)
    }
    public static func writeIncident(_ incident: Incident, to url: URL) throws {
        try AtomicFile.write(try encoder().encode(incident), to: url)
    }
}

extension WatchdogFiles {
    /// The displays.json the watchdog keeps; nil when it is missing or unreadable.
    public static func readDisplays(at url: URL) -> DisplaysFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(DisplaysFile.self, from: data)
    }
}
