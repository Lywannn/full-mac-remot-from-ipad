import Foundation

public struct Heartbeat: Codable, Equatable, Sendable {
    public var pid: Int32
    public var monotonicNanos: UInt64

    public init(pid: Int32, monotonicNanos: UInt64) { self.pid = pid; self.monotonicNanos = monotonicNanos }

    public static func now(pid: Int32) -> Heartbeat {
        Heartbeat(pid: pid, monotonicNanos: clock_gettime_nsec_np(CLOCK_MONOTONIC))
    }

    public static func read(_ url: URL) -> Heartbeat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Heartbeat.self, from: data)
    }

    public func write(_ url: URL) throws {
        try AtomicFile.write(try JSONEncoder().encode(self), to: url)
    }

    public func age(nowNanos: UInt64) -> Duration {
        // Up to 2 s in the future is sampling skew. Further ahead it is left over from a previous boot
        // (CLOCK_MONOTONIC restarts at boot): stale.
        nowNanos >= monotonicNanos ? .nanoseconds(Int64(clamping: nowNanos - monotonicNanos))
            : (monotonicNanos - nowNanos <= 2_000_000_000 ? .zero : .seconds(Int64.max / 2))
    }
}
