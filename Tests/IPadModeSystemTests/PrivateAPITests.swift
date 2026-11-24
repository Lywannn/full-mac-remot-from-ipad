import Foundation
import Testing
@testable import IPadModeSystem

@Suite(.serialized) struct PrivateAPITests {
    @Test(.enabled(if: env("IPADMODE_HW_TESTS") == "1"))
    func privateAPIsPresentOnThisMac() {
        let s = PrivateAPI.status
        #expect(s.virtualDisplay); #expect(s.configureEnabled); #expect(s.displayList); #expect(s.displayInfo)
    }

    @Test func simulatedMissingAPIReportsUnavailable() {
        setenv("IPADMODE_SIMULATE_MISSING_API", "1", 1); defer { unsetenv("IPADMODE_SIMULATE_MISSING_API") }
        #expect(PrivateAPI.allAvailable == false)
        let s = PrivateAPI.status
        #expect(!s.virtualDisplay && !s.configureEnabled && !s.displayList && !s.displayInfo)
    }
}
