import Foundation

public struct Paths: Sendable {
    public var support: URL
    public var logs: URL

    public init(support: URL, logs: URL) { self.support = support; self.logs = logs }

    public static let standard: Paths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Paths(
            support: home.appendingPathComponent("Library/Application Support/ipadmode", isDirectory: true),
            logs: home.appendingPathComponent("Library/Logs/ipadmode", isDirectory: true))
    }()

    public var config: URL { support.appendingPathComponent("config.json") }
    public var state: URL { support.appendingPathComponent("state.json") }
    public var heartbeat: URL { support.appendingPathComponent("heartbeat.json") }
    public var watchdogHeartbeat: URL { support.appendingPathComponent("watchdog-heartbeat.json") }
    public var displays: URL { support.appendingPathComponent("displays.json") }
    public var incident: URL { support.appendingPathComponent("incident.json") }
    public var socket: URL { support.appendingPathComponent("ipadmode.sock") }
    public var disabledMarker: URL { support.appendingPathComponent("disabled") }
}
