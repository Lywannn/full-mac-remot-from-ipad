import Foundation
import Testing
@testable import IPadModeSystem

struct ExternalCommandTests {
    @Test func timeoutKillsAndReturnsNil() {
        let start = Date()
        let r = ExternalCommand.run("/bin/sleep", ["10"], timeout: 0.5)
        #expect(r == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
    @Test func collectsOutputAndStatus() {
        let r = ExternalCommand.run("/bin/sh", ["-c", "echo hi; exit 3"])
        #expect(r?.status == 3)
        #expect(r?.output == "hi\n")
    }
    @Test func missingToolIsNil() {
        #expect(ExternalCommand.run("/nonexistent/tool", []) == nil)
    }
}
