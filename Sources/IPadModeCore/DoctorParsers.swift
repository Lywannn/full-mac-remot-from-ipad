import Foundation

public enum DoctorParsers {
    /// The value on the `autorestart` line of `pmset -g`; nil if there is none.
    public static func autorestart(pmset: String) -> Bool? {
        for line in pmset.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "autorestart" { return parts[1] == "1" ? true : (parts[1] == "0" ? false : nil) }
        }
        return nil
    }

    public static func fileVaultOn(fdesetup: String) -> Bool? {
        if fdesetup.contains("FileVault is On") { return true }
        if fdesetup.contains("FileVault is Off") { return false }
        return nil
    }

    /// `defaults read ... AutomaticallyInstallMacOSUpdates`: 1/true is on, 0/false is off.
    public static func autoMacOSUpdates(defaultsValue: String) -> Bool? {
        switch defaultsValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    public static func isARM(lipoArchs: String) -> Bool {
        lipoArchs.split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix("arm64") }
    }

    /// `pgrep -f "RustDesk.app/Contents/MacOS/RustDesk --server"` prints one PID per line when it matches.
    public static func rustDeskServerRunning(pgrepOutput: String) -> Bool {
        pgrepOutput.split(whereSeparator: \.isNewline).contains { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// `launchctl print gui/<uid>/com.carriez.RustDesk_server`.
    public static func rustDeskServerRunning(launchctlPrint: String) -> Bool {
        launchctlPrint.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces) == "state = running"
        }
    }

    /// R81. A live daemon decided once at startup from the starts it kept, so its answer is the persisted count;
    /// otherwise predict the next start: 3 unclean starts within 10 minutes.
    public static func isSafeMode(uncleanStarts: [Date], now: Date, daemonHeartbeatFresh: Bool) -> Bool {
        if daemonHeartbeatFresh { return uncleanStarts.count >= 3 }
        return uncleanStarts.filter { let age = now.timeIntervalSince($0); return age >= 0 && age < 600 }.count >= 3
    }

    public static func isFresh(age: Duration?, limit: Duration = .seconds(5)) -> Bool {
        guard let age else { return false }
        return age <= limit
    }
}
