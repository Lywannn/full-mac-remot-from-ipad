import Foundation

public enum Command: Equatable, Sendable {
    case daemon, watchdog, vdisplay([String]), remote(confirmSeconds: Int?), sidecar, normal
    case status(json: Bool, offline: Bool), doctor, resolution(String), logs, disable, enable
}

public struct CLIUsageError: Error, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

/// 1 and 2 are reserved for results the daemon returned (its notice panel already showed them, R83).
/// Outcomes the CLI produced itself use 3...6 or 64, so a caller such as an applet can show them.
public enum ExitCode: Int32 {
    case ok = 0, refused = 1, failed = 2, daemonDown = 3, unsupported = 4
    case busy = 5       // daemon alive but did not answer in time
    case badReply = 6   // reply missing, invalid or incomplete
    case usage = 64
}

public enum CLIParsing {
    public static let confirmSecondsRange = 0...600

    /// How long the CLI waits for the daemon's answer to `request` (R18): 15 s, but 30 s for a way back to Normal
    /// (B-9), whose worst case is longer: the 1 s settle (R79), the 10 s wake window (A-2), the 2 s main check (B-8),
    /// and the virtual display's stop (SIGTERM, 2 s, SIGKILL, 1 s, then up to 3 s for the display to go).
    public static func socketTimeout(for request: IPCRequest) -> Duration {
        switch request {
        case .normal, .shutdownForDisable: .seconds(30)
        case .remote, .sidecar, .status, .resolution: .seconds(15)
        }
    }

    public static func isHelp(_ args: [String]) -> Bool {
        args.count == 1 && ["--help", "-h", "help"].contains(args[0])
    }

    /// `vdisplay` carries the arguments after its name, unvalidated; `VDisplayProtocol.parseArguments` checks them.
    public static func parse(_ args: [String]) -> Result<Command, CLIUsageError> {
        let usage = Result<Command, CLIUsageError>.failure(CLIUsageError(message: Messages.usage))
        guard let name = args.first else { return usage }
        let rest = Array(args.dropFirst())
        switch name {
        case "vdisplay": return .success(.vdisplay(rest))
        case "daemon": return rest.isEmpty ? .success(.daemon) : usage
        case "watchdog": return rest.isEmpty ? .success(.watchdog) : usage
        case "sidecar": return rest.isEmpty ? .success(.sidecar) : usage
        case "normal": return rest.isEmpty ? .success(.normal) : usage
        case "doctor": return rest.isEmpty ? .success(.doctor) : usage
        case "logs": return rest.isEmpty ? .success(.logs) : usage
        case "disable": return rest.isEmpty ? .success(.disable) : usage
        case "enable": return rest.isEmpty ? .success(.enable) : usage
        case "resolution": return rest.count == 1 ? .success(.resolution(rest[0])) : usage
        case "remote":
            if rest.isEmpty { return .success(.remote(confirmSeconds: nil)) }
            guard rest.count == 2, rest[0] == "--confirm-seconds", rest[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(rest[1]), confirmSecondsRange.contains(n) else { return usage }
            return .success(.remote(confirmSeconds: n))
        case "status":
            var json = false, offline = false
            for flag in rest {
                switch flag {
                case "--json": json = true
                case "--offline": offline = true
                default: return usage
                }
            }
            return .success(.status(json: json, offline: offline))
        default: return usage
        }
    }
}
