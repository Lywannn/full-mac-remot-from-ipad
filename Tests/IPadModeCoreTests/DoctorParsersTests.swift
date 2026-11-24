import Foundation
import Testing
@testable import IPadModeCore

struct DoctorParsersTests {
    @Test func doctorParsers() {
        #expect(DoctorParsers.autorestart(pmset: " autorestart          1") == true)
        #expect(DoctorParsers.autorestart(pmset: " sleep 0\n autorestart          0\n womp 1") == false)
        #expect(DoctorParsers.autorestart(pmset: "nothing here") == nil)
        #expect(DoctorParsers.fileVaultOn(fdesetup: "FileVault is On.") == true)
        #expect(DoctorParsers.fileVaultOn(fdesetup: "FileVault is Off.") == false)
        #expect(DoctorParsers.fileVaultOn(fdesetup: "???") == nil)
        #expect(DoctorParsers.autoMacOSUpdates(defaultsValue: "0") == false)
        #expect(DoctorParsers.autoMacOSUpdates(defaultsValue: "1\n") == true)
        #expect(DoctorParsers.autoMacOSUpdates(defaultsValue: "false") == false)
        #expect(DoctorParsers.autoMacOSUpdates(defaultsValue: "true") == true)
        #expect(DoctorParsers.autoMacOSUpdates(defaultsValue: "weird") == nil)
        #expect(DoctorParsers.isARM(lipoArchs: "arm64") == true)
        #expect(DoctorParsers.isARM(lipoArchs: "x86_64 arm64\n") == true)
        #expect(DoctorParsers.isARM(lipoArchs: "x86_64") == false)
    }

    @Test func rustDeskServerFromPgrep() {
        #expect(DoctorParsers.rustDeskServerRunning(pgrepOutput: "412\n") == true)
        #expect(DoctorParsers.rustDeskServerRunning(pgrepOutput: "") == false)
        #expect(DoctorParsers.rustDeskServerRunning(pgrepOutput: "\n") == false)
    }

    @Test func rustDeskServerFromLaunchctlPrint() {
        let running = """
        gui/501/com.carriez.RustDesk_server = {
        \tactive count = 1
        \tstate = running
        \tprogram = /Applications/RustDesk.app/Contents/MacOS/RustDesk
        }
        """
        let exited = running.replacingOccurrences(of: "state = running", with: "state = not running")
        #expect(DoctorParsers.rustDeskServerRunning(launchctlPrint: running) == true)
        #expect(DoctorParsers.rustDeskServerRunning(launchctlPrint: exited) == false)
        #expect(DoctorParsers.rustDeskServerRunning(launchctlPrint: "") == false)
    }

    @Test func safeModeCountsRecentUncleanStarts() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = [now.addingTimeInterval(-60), now.addingTimeInterval(-120), now.addingTimeInterval(-300)]
        #expect(DoctorParsers.isSafeMode(uncleanStarts: recent, now: now, daemonHeartbeatFresh: false) == true)
        #expect(DoctorParsers.isSafeMode(uncleanStarts: Array(recent.prefix(2)), now: now, daemonHeartbeatFresh: false) == false)
        #expect(DoctorParsers.isSafeMode(uncleanStarts: [now.addingTimeInterval(-700)] + recent.prefix(2), now: now, daemonHeartbeatFresh: false) == false)
    }

    @Test func safeModeFollowsPersistedCountWhileDaemonLives() {
        let now = Date(timeIntervalSince1970: 10_000)
        let old = [now.addingTimeInterval(-900), now.addingTimeInterval(-800), now.addingTimeInterval(-700)]
        #expect(DoctorParsers.isSafeMode(uncleanStarts: old, now: now, daemonHeartbeatFresh: true) == true)
        #expect(DoctorParsers.isSafeMode(uncleanStarts: old, now: now, daemonHeartbeatFresh: false) == false)
    }

    @Test func heartbeatFreshness() {
        #expect(DoctorParsers.isFresh(age: .seconds(5)) == true)
        #expect(DoctorParsers.isFresh(age: .milliseconds(5001)) == false)
        #expect(DoctorParsers.isFresh(age: nil) == false)
    }
}
