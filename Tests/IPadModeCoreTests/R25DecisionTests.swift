import Testing
@testable import IPadModeCore

/// R25 amended: what the `vdisplay` child does on each poll once its parent died.
@Suite struct R25DecisionTests {
    private let virtual = Fixtures.virtualRemote
    private let legion = Fixtures.legion, p24 = Fixtures.p24
    private let both = [Fixtures.legion.id, Fixtures.p24.id]
    private var allOff: [DisplayInfo] { [Fixtures.off(legion), Fixtures.off(p24), virtual] }
    private var oneOff: [DisplayInfo] { [legion, Fixtures.off(p24), virtual] }
    /// The P24 dropped out of the listing, as a monitor waking from standby can (its vendor reads 0 meanwhile).
    private var p24Missing: [DisplayInfo] { [legion, virtual] }

    /// One poll at `ms` milliseconds after the parent died; `state` carries over.
    private func poll(_ state: inout R25Decision.State, _ displays: [DisplayInfo]?, at ms: Int) -> R25Decision.Action {
        let (action, next) = R25Decision.next(displays: displays, elapsed: .milliseconds(ms), state: state)
        state = next
        return action
    }

    @Test func limitsAreTheRuled() {
        #expect(R25Decision.deadline == .seconds(6))
        #expect(R25Decision.retryInterval == .seconds(1))
        #expect(R25Decision.headlessListings == 3)
    }

    @Test func litMonitorAndNoneOfflineReleasesAtOnce() {
        var s = R25Decision.State()
        #expect(poll(&s, [legion, p24, virtual], at: 0) == .release)
    }

    @Test func trueHeadlessReleasesAfterThreeListings() {
        var s = R25Decision.State()
        #expect(poll(&s, [virtual], at: 0) == .wait)
        #expect(poll(&s, [virtual], at: 100) == .wait)
        #expect(poll(&s, [virtual], at: 200) == .release)
    }

    @Test func oneListingWithoutMonitorsThenDisabledOnesEnablesInsteadOfReleasing() {
        var s = R25Decision.State()
        #expect(poll(&s, [virtual], at: 0) == .wait)   // a bad listing: the disabled monitors dropped out
        #expect(poll(&s, allOff, at: 100) == .enable(both))
        #expect(poll(&s, [virtual], at: 200) == .wait)   // known monitors now: an empty listing is no headless proof
        #expect(poll(&s, [virtual], at: 300) == .wait)
        #expect(poll(&s, [virtual], at: 400) == .wait)
    }

    @Test func failedListingWaitsAndStartsTheHeadlessCountOver() {
        var s = R25Decision.State()
        #expect(poll(&s, nil, at: 0) == .wait)
        #expect(poll(&s, [virtual], at: 100) == .wait)
        #expect(poll(&s, [virtual], at: 200) == .wait)
        #expect(poll(&s, nil, at: 300) == .wait)
        #expect(poll(&s, [virtual], at: 400) == .wait)
        #expect(poll(&s, [virtual], at: 500) == .wait)
        #expect(poll(&s, [virtual], at: 600) == .release)
    }

    @Test func oneLitAndOneDisabledEnablesAndDoesNotRelease() {
        var s = R25Decision.State()
        #expect(poll(&s, oneOff, at: 0) == .enable([p24.id]))
    }

    @Test func monitorStillOfflineAfterARequestWaitsThenIsAskedForAgainAfterASecond() {
        var s = R25Decision.State()
        #expect(poll(&s, oneOff, at: 0) == .enable([p24.id]))
        #expect(poll(&s, oneOff, at: 100) == .wait)   // the request may have been accepted: still offline, so stay
        #expect(poll(&s, oneOff, at: 999) == .wait)
        #expect(poll(&s, oneOff, at: 1000) == .enable([p24.id]))
        #expect(poll(&s, oneOff, at: 1500) == .wait)
        #expect(poll(&s, oneOff, at: 2000) == .enable([p24.id]))
    }

    @Test func disabledMonitorBackOnlineReleases() {
        var s = R25Decision.State()
        #expect(poll(&s, oneOff, at: 0) == .enable([p24.id]))
        #expect(poll(&s, oneOff, at: 100) == .wait)
        #expect(poll(&s, [legion, p24, virtual], at: 300) == .release)
    }

    @Test func allDisabledAreAskedForUntilEachIsBack() {
        var s = R25Decision.State()
        #expect(poll(&s, allOff, at: 0) == .enable(both))
        #expect(poll(&s, allOff, at: 100) == .wait)                          // waking up
        #expect(poll(&s, [legion, Fixtures.off(p24), virtual], at: 900) == .wait)   // one back and lit: not yet
        #expect(poll(&s, [legion, Fixtures.off(p24), virtual], at: 1000) == .enable([p24.id]))
        #expect(poll(&s, [legion, p24, virtual], at: 1100) == .release)
    }

    @Test func monitorThatNeverComesBackReleasesOnlyAtTheDeadline() {
        var s = R25Decision.State()
        for ms in stride(from: 0, to: 6000, by: 100) {
            let expected: R25Decision.Action = ms % 1000 == 0 ? .enable([p24.id]) : .wait
            #expect(poll(&s, oneOff, at: ms) == expected, "at \(ms) ms")
        }
        #expect(poll(&s, oneOff, at: 6000) == .release)
    }

    @Test func nothingLitByTheDeadlineReleases() {
        var s = R25Decision.State()
        #expect(poll(&s, allOff, at: 0) == .enable(both))
        #expect(poll(&s, allOff, at: 5999) == .enable(both))
        #expect(poll(&s, allOff, at: 6000) == .release)
        var failing = R25Decision.State()
        #expect(poll(&failing, nil, at: 6000) == .release)   // also when the listing keeps failing
    }

    @Test func knownMonitorMissingFromTheListingIsNotBack() {
        var s = R25Decision.State()
        #expect(poll(&s, oneOff, at: 0) == .enable([p24.id]))
        #expect(poll(&s, p24Missing, at: 100) == .wait)               // the Legion is lit, but the P24 is not back
        #expect(poll(&s, p24Missing, at: 1000) == .enable([p24.id]))  // enabling by ID works while it is unlisted
        #expect(poll(&s, [legion, p24, virtual], at: 1100) == .release)
    }

    @Test func knownMonitorThatStaysMissingReleasesOnlyAtTheDeadline() {
        var s = R25Decision.State()
        #expect(poll(&s, oneOff, at: 0) == .enable([p24.id]))
        for ms in stride(from: 100, to: 6000, by: 100) {
            let expected: R25Decision.Action = ms % 1000 == 0 ? .enable([p24.id]) : .wait
            #expect(poll(&s, p24Missing, at: ms) == expected, "at \(ms) ms")
        }
        #expect(poll(&s, p24Missing, at: 6000) == .release)
    }

    @Test func emptyListingsAfterKnownMonitorsAreNeverHeadless() {
        var s = R25Decision.State()
        #expect(poll(&s, allOff, at: 0) == .enable(both))
        for ms in stride(from: 100, to: 6000, by: 100) {
            let expected: R25Decision.Action = ms % 1000 == 0 ? .enable(both) : .wait
            #expect(poll(&s, [virtual], at: ms) == expected, "at \(ms) ms")
        }
        #expect(poll(&s, [virtual], at: 6000) == .release)
    }

    @Test func onlineMonitorsThatAreNotLitYetWait() {
        var s = R25Decision.State()
        var dark = legion
        dark.isActive = false
        #expect(poll(&s, [dark, virtual], at: 0) == .wait)
        #expect(poll(&s, [legion, virtual], at: 100) == .release)
    }
}

/// The rules R25 and the way back's step 2 share (A-2).
@Suite struct MonitorWakeWatchTests {
    private let legion = Fixtures.legion, p24 = Fixtures.p24, virtual = Fixtures.virtualRemote

    @Test func monitorsNamedAtTheStartAreKnownBeforeAnyListingShowsThem() {
        var watch = MonitorWakeWatch(known: [p24.id])
        #expect(watch.observe([legion, virtual], at: .zero) == .enable([p24.id]))   // not listed: not back
        #expect(watch.observe([legion, p24, virtual], at: .milliseconds(100)) == .back)
    }

    @Test func monitorsListedLaterBecomeKnownToo() {
        var watch = MonitorWakeWatch(known: [legion.id])
        #expect(watch.observe([legion, virtual], at: .zero) == .back)
        var other = MonitorWakeWatch(known: [legion.id])
        #expect(other.observe([legion, Fixtures.off(p24), virtual], at: .zero) == .enable([p24.id]))
        #expect(other.known == [legion.id, p24.id])
    }

    @Test func everyKnownMonitorOnlineButNoneLitIsWaking() {
        var watch = MonitorWakeWatch()
        var dark = legion
        dark.isActive = false
        #expect(watch.observe([dark, virtual], at: .zero) == .wait)
        #expect(watch.observe([legion, virtual], at: .milliseconds(100)) == .back)
    }

    @Test func aMonitorNotBackIsAskedForAgainOncePerSecond() {
        var watch = MonitorWakeWatch(known: [p24.id])
        let off = [legion, Fixtures.off(p24), virtual]
        #expect(watch.observe(off, at: .zero) == .enable([p24.id]))
        #expect(watch.observe(off, at: .milliseconds(999)) == .wait)
        #expect(watch.observe(off, at: .seconds(1)) == .enable([p24.id]))
        #expect(watch.lastRequest == .seconds(1))
    }

    @Test func aFailedListingOnlyWaits() {
        var watch = MonitorWakeWatch(known: [p24.id])
        #expect(watch.observe(nil, at: .zero) == .wait)
        #expect(watch.lastRequest == nil)
    }

    @Test func withNothingKnownAndNoMonitorListedNothingIsBack() {
        var watch = MonitorWakeWatch()
        #expect(watch.observe([virtual], at: .zero) == .wait)
        #expect(watch.known.isEmpty)
    }

    @Test func onlyAPhysicalMonitorOnlineAndActiveIsLit() {
        var dark = legion
        dark.isActive = false
        #expect(MonitorWakeWatch.isLit([legion, virtual]))
        #expect(!MonitorWakeWatch.isLit([virtual]))
        #expect(!MonitorWakeWatch.isLit([dark, virtual]))
        #expect(!MonitorWakeWatch.isLit([Fixtures.off(p24)]))
    }

    @Test func retryIntervalIsR25s() {
        #expect(MonitorWakeWatch.retryInterval == .seconds(1))
        #expect(R25Decision.retryInterval == MonitorWakeWatch.retryInterval)
    }
}
