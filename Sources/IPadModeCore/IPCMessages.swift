import Foundation

/// What the CLI asks the daemon (spec: one JSON line per request over the Unix socket).
public enum IPCRequest: Codable, Equatable, Sendable {
    case remote(confirmSeconds: Int?)
    case sidecar
    case normal
    case status
    case resolution(String)
    case shutdownForDisable
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var result: CommandResult
    public var state: PersistedState?
    public var displays: [DisplayInfo]?

    public init(result: CommandResult, state: PersistedState? = nil, displays: [DisplayInfo]? = nil) {
        self.result = result; self.state = state; self.displays = displays
    }
}

/// One JSON object per line. `encode` appends the `\n`; `decodeLine` accepts the line with or without it.
public enum IPCFraming {
    public static func encode<T: Encodable>(_ v: T) throws -> Data {
        let encoder = JSONEncoder()
        var data = try encoder.encode(v)
        data.append(0x0A)
        return data
    }

    public static func decodeLine<T: Decodable>(_ line: Data, as: T.Type) throws -> T {
        var body = line
        if body.last == 0x0A { body.removeLast() }
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: body)
    }
}
