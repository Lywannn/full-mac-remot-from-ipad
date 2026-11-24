import Foundation
import Testing
@testable import IPadModeCore

struct DisableWaitTests {
    private let started = Date(timeIntervalSince1970: 1_700_000_000.8)
    private func file(_ t: TimeInterval, _ d: [DisplayInfo]) -> WatchdogFiles.DisplaysFile {
        WatchdogFiles.DisplaysFile(time: Date(timeIntervalSince1970: t), displays: d)
    }

    @Test func sameSecondFileIsAccepted() {
        #expect(DisableWait.isSettled(snapshot: file(1_700_000_000, [Fixtures.legion]), startedAt: started))
    }
    @Test func newerFileIsAccepted() {
        #expect(DisableWait.isSettled(snapshot: file(1_700_000_003, [Fixtures.legion, Fixtures.p24]), startedAt: started))
    }
    @Test func olderFileIsRejected() {
        #expect(!DisableWait.isSettled(snapshot: file(1_699_999_999, [Fixtures.legion]), startedAt: started))
    }
    @Test func offlinePhysicalIsNotSettled() {
        #expect(!DisableWait.isSettled(snapshot: file(1_700_000_005, [Fixtures.legion, Fixtures.off(Fixtures.p24)]), startedAt: started))
    }
    @Test func missingFileIsNotSettled() {
        #expect(!DisableWait.isSettled(snapshot: nil, startedAt: started))
    }
}
