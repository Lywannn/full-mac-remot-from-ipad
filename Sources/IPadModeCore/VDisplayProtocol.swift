/// What the daemon and its `ipadmode vdisplay` child say to each other: the child's command line, and the one line
/// the child prints on stdout, `READY <display id>` once its display is up or `ERROR <reason>` when it is not.
public enum VDisplayProtocol {
    /// The role's name on the command line.
    public static let subcommand = "vdisplay"

    public static func readyLine(_ id: DisplayID) -> String { "READY \(id.raw)\n" }

    /// The display ID of a `READY <id>` line (its newline is optional), or nil for any other line.
    public static func parseReady(_ line: String) -> DisplayID? {
        guard let rest = payload(of: line, after: "READY"), let raw = UInt32(digits: rest), raw != 0 else { return nil }
        return DisplayID(raw: raw)
    }

    /// One line, whatever `reason` holds.
    public static func errorLine(_ reason: String) -> String {
        let flat = reason.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.isEmpty ? "ERROR\n" : "ERROR \(flat)\n"
    }

    /// The reason of an `ERROR [reason]` line (its newline is optional), or nil for any other line.
    public static func parseError(_ line: String) -> String? {
        if withoutNewline(line) == "ERROR" { return "" }
        return payload(of: line, after: "ERROR").map(String.init)
    }

    public static func arguments(role: VirtualRole, resolution: Resolution, parentPID: Int32) -> [String] {
        [subcommand, "--role", role.rawValue, "--resolution", resolution.text, "--parent", String(parentPID)]
    }

    /// The three flags of `arguments`, each exactly once and in any order, and nothing else. The parent must be a
    /// real process: not 0, 1 (launchd) or negative.
    public static func parseArguments(_ args: [String]) -> (role: VirtualRole, resolution: Resolution, parentPID: Int32)? {
        let flags = ["--role", "--resolution", "--parent"]
        guard args.count == 1 + 2 * flags.count, args.first == subcommand else { return nil }
        var values: [String: String] = [:]
        for i in stride(from: 1, to: args.count, by: 2) {
            guard flags.contains(args[i]), values[args[i]] == nil else { return nil }
            values[args[i]] = args[i + 1]
        }
        guard let role = values["--role"].flatMap(VirtualRole.init(rawValue:)),
              let resolution = values["--resolution"].flatMap(Resolution.init(parsing:)),
              let parent = values["--parent"].flatMap({ Int32(digits: Substring($0)) }), parent > 1
        else { return nil }
        return (role, resolution, parent)
    }

    /// The text after `keyword` and one space, without the line's newline; nil if `line` is no such line.
    private static func payload(of line: String, after keyword: String) -> Substring? {
        let text = withoutNewline(line), prefix = keyword + " "
        guard text.hasPrefix(prefix) else { return nil }
        return text.dropFirst(prefix.count)
    }

    private static func withoutNewline(_ line: String) -> Substring {
        line.hasSuffix("\n") ? line.dropLast() : Substring(line)
    }
}

private extension FixedWidthInteger {
    /// Plain decimal digits only: no sign, no spaces, no prefix.
    init?(digits: Substring) {
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self.init(digits)
    }
}
