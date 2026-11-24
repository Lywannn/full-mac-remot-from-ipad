import Testing
@testable import IPadModeCore

struct CLIParsingTests {
    private func ok(_ a: [String]) -> Command? { if case .success(let c) = CLIParsing.parse(a) { return c }; return nil }
    private func isUsageError(_ a: [String]) -> Bool { if case .failure = CLIParsing.parse(a) { return true }; return false }

    @Test func parsesCommands() {
        #expect(ok(["remote"]) == .remote(confirmSeconds: nil))
        #expect(ok(["remote", "--confirm-seconds", "120"]) == .remote(confirmSeconds: 120))
        #expect(ok(["status", "--json"]) == .status(json: true, offline: false))
        #expect(isUsageError(["bogus"]))
    }

    @Test func confirmSecondsRange() {
        #expect(isUsageError(["remote", "--confirm-seconds", "-1"]))
        #expect(ok(["remote", "--confirm-seconds", "0"]) == .remote(confirmSeconds: 0))
        #expect(ok(["remote", "--confirm-seconds", "600"]) == .remote(confirmSeconds: 600))
        #expect(isUsageError(["remote", "--confirm-seconds", "601"]))
        #expect(isUsageError(["remote", "--confirm-seconds", "abc"]))
        #expect(isUsageError(["remote", "--confirm-seconds"]))
        #expect(isUsageError(["remote", "--bogus"]))
    }

    @Test func statusFlags() {
        #expect(ok(["status"]) == .status(json: false, offline: false))
        #expect(ok(["status", "--offline"]) == .status(json: false, offline: true))
        #expect(ok(["status", "--json", "--offline"]) == .status(json: true, offline: true))
        #expect(ok(["status", "--offline", "--json"]) == .status(json: true, offline: true))
        #expect(isUsageError(["status", "--x"]))
    }

    @Test func simpleCommands() {
        #expect(ok(["sidecar"]) == .sidecar)
        #expect(ok(["normal"]) == .normal)
        #expect(ok(["doctor"]) == .doctor)
        #expect(ok(["logs"]) == .logs)
        #expect(ok(["disable"]) == .disable)
        #expect(ok(["enable"]) == .enable)
        #expect(ok(["daemon"]) == .daemon)
        #expect(ok(["watchdog"]) == .watchdog)
        #expect(isUsageError(["normal", "extra"]))
        #expect(isUsageError(["daemon", "extra"]))
    }

    @Test func resolution() {
        #expect(ok(["resolution", "1321x918"]) == .resolution("1321x918"))
        #expect(isUsageError(["resolution"]))
        #expect(isUsageError(["resolution", "a", "b"]))
    }

    @Test func vdisplayPassesArgsThrough() {
        let rest = ["--role", "remote", "--resolution", "1180x820", "--parent", "42"]
        #expect(ok(["vdisplay"] + rest) == .vdisplay(rest))
    }

    @Test func noArgsIsUsage() {
        guard case .failure(let e) = CLIParsing.parse([]) else { Issue.record("expected failure"); return }
        #expect(e.message == Messages.usage)
    }

    @Test func helpIsRecognised() {
        #expect(CLIParsing.isHelp(["--help"]))
        #expect(CLIParsing.isHelp(["-h"]))
        #expect(CLIParsing.isHelp(["help"]))
        #expect(!CLIParsing.isHelp(["status"]))
    }

    @Test func socketTimeouts() {
        // B-9: the way back can take longer than 15 s (settle, a 10 s wake window, the main check, the stop).
        #expect(CLIParsing.socketTimeout(for: .normal) == .seconds(30))
        #expect(CLIParsing.socketTimeout(for: .shutdownForDisable) == .seconds(30))
        // R18: everything else keeps 15 s.
        #expect(CLIParsing.socketTimeout(for: .remote(confirmSeconds: nil)) == .seconds(15))
        #expect(CLIParsing.socketTimeout(for: .status) == .seconds(15))
        #expect(CLIParsing.socketTimeout(for: .resolution("1180x820")) == .seconds(15))
        #expect(CLIParsing.socketTimeout(for: .sidecar) == .seconds(15))
    }

    @Test func exitCodes() {
        #expect(ExitCode.ok.rawValue == 0 && ExitCode.refused.rawValue == 1 && ExitCode.failed.rawValue == 2)
        #expect(ExitCode.daemonDown.rawValue == 3 && ExitCode.unsupported.rawValue == 4 && ExitCode.usage.rawValue == 64)
        #expect(ExitCode.busy.rawValue == 5 && ExitCode.badReply.rawValue == 6)
        // 1 and 2 stay reserved for daemon-returned results (R83).
        #expect(Set([ExitCode.busy, .badReply, .daemonDown, .unsupported, .usage].map(\.rawValue)).isDisjoint(with: [1, 2]))
    }
}
