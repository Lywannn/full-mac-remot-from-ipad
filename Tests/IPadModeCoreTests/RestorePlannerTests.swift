import Testing
@testable import IPadModeCore

private func offline(_ d: DisplayInfo, id: UInt32? = nil) -> DisplayInfo {
    var c = d
    c.isOnline = false
    if let id { c.id = DisplayID(raw: id) }
    return c
}

private func ids(_ raws: UInt32...) -> [DisplayID] { raws.map { DisplayID(raw: $0) } }

@Test func identityPlanRestoresOriginsAndMain() {
    let base = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    let plan = RestorePlanner.plan(baseline: base, current: [offline(Fixtures.legion), offline(Fixtures.p24)])
    #expect(plan.enable == ids(1, 3))
    #expect(plan.origins == [DisplayID(raw: 1): Point(x: 0, y: 0), DisplayID(raw: 3): Point(x: -1920, y: -326)])
    #expect(plan.modes[DisplayID(raw: 1)] == Fixtures.legion.mode)
    #expect(plan.main == DisplayID(raw: 1))
    #expect(plan.unmatched.isEmpty)
}

@Test func restoreMatchesByUUIDWhenIDsChange() {
    let base = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    let plan = RestorePlanner.plan(baseline: base, current: [offline(Fixtures.p24, id: 9), offline(Fixtures.legion, id: 7)])
    #expect(plan.enable == ids(7, 9))
    #expect(plan.origins[DisplayID(raw: 7)] == Point(x: 0, y: 0))
    #expect(plan.origins[DisplayID(raw: 9)] == Point(x: -1920, y: -326))
    #expect(plan.main == DisplayID(raw: 7))
}

@Test func matchesByVendorModelLocationWithoutUUID() {
    var l = Fixtures.legion; l.uuid = nil
    var p = Fixtures.p24; p.uuid = nil
    let base = Fixtures.snapshot([l, p])
    let plan = RestorePlanner.plan(baseline: base, current: [offline(p, id: 9), offline(l, id: 7)])
    #expect(plan.enable == ids(7, 9))
    #expect(plan.main == DisplayID(raw: 7))
}

@Test func matchesByVendorModelWhenUnique() {
    var l = Fixtures.legion; l.uuid = nil
    var cur = offline(l, id: 7); cur.location = "other"
    let plan = RestorePlanner.plan(baseline: Fixtures.snapshot([l]), current: [cur])
    #expect(plan.enable == ids(7))
    #expect(plan.main == DisplayID(raw: 7))
}

@Test func identicalMonitorsDistinguishedByLocation() {
    var a = Fixtures.p24; a.uuid = nil; a.id = DisplayID(raw: 3); a.location = "dispext0"; a.origin = Point(x: 0, y: 0); a.name = "A"
    var b = a; b.id = DisplayID(raw: 4); b.location = "dispext1"; b.origin = Point(x: 1920, y: 0); b.name = "B"
    let base = Fixtures.snapshot([a, b])
    // current order swapped and IDs changed
    var ca = offline(a, id: 11); ca.origin = Point(x: 5, y: 5)
    var cb = offline(b, id: 12); cb.origin = Point(x: 6, y: 6)
    let plan = RestorePlanner.plan(baseline: base, current: [cb, ca])
    #expect(plan.origins[DisplayID(raw: 11)] == Point(x: 0, y: 0))
    #expect(plan.origins[DisplayID(raw: 12)] == Point(x: 1920, y: 0))
    #expect(plan.enable == ids(11, 12))
}

@Test func identicalMonitorsWithoutLocationAreNotGuessed() {
    var a = Fixtures.p24; a.uuid = nil; a.location = nil
    var b = a; b.id = DisplayID(raw: 4)
    let plan = RestorePlanner.plan(baseline: Fixtures.snapshot([a, b]), current: [offline(a, id: 11), offline(b, id: 12)])
    #expect(plan.origins.isEmpty)
    #expect(plan.unmatched == [a.name, b.name])
    #expect(plan.enable == ids(11, 12))
}

@Test func missingBaselineMonitorIsUnmatched() {
    let base = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    let plan = RestorePlanner.plan(baseline: base, current: [offline(Fixtures.legion)])
    #expect(plan.enable == ids(1))
    #expect(plan.unmatched == ["P24FBA-RAGL"])
}

@Test func missingMainYieldsNilMain() {
    let base = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    let plan = RestorePlanner.plan(baseline: base, current: [offline(Fixtures.p24)])
    #expect(plan.main == nil)
}

@Test func newMonitorIsEnabledWithoutOrigin() {
    var extra = Fixtures.p24
    extra.uuid = "UUID-NEW"; extra.vendor = 0x9999; extra.id = DisplayID(raw: 20); extra.isOnline = false
    let base = Fixtures.snapshot([Fixtures.legion])
    let plan = RestorePlanner.plan(baseline: base, current: [extra, offline(Fixtures.legion)])
    #expect(plan.enable == ids(1, 20))
    #expect(plan.origins[DisplayID(raw: 20)] == nil)
    #expect(plan.modes[DisplayID(raw: 20)] == nil)
}

@Test func alreadyOnlineDisplayIsNotEnabledButKeepsOrigin() {
    let base = Fixtures.snapshot([Fixtures.legion, Fixtures.p24])
    let plan = RestorePlanner.plan(baseline: base, current: [Fixtures.legion, offline(Fixtures.p24)])
    #expect(plan.enable == ids(3))
    #expect(plan.origins[DisplayID(raw: 1)] == Point(x: 0, y: 0))
}

@Test func virtualAndSidecarAreNeverInPlan() {
    var sidecar = Fixtures.virtualRemote
    sidecar.id = DisplayID(raw: 60); sidecar.kind = .sidecar; sidecar.isOnline = false
    var virt = Fixtures.virtualRemote; virt.isOnline = false
    let base = Fixtures.snapshot([Fixtures.legion, Fixtures.virtualRemote])
    let plan = RestorePlanner.plan(baseline: base, current: [virt, sidecar, offline(Fixtures.legion)])
    #expect(plan.enable == ids(1))
    #expect(plan.origins.keys.contains(DisplayID(raw: 50)) == false)
    #expect(plan.origins.keys.contains(DisplayID(raw: 60)) == false)
    #expect(plan.unmatched.isEmpty)
}

@Test func offlineBaselineEntryGetsNoOriginButIsEnabled() {
    var p = Fixtures.p24; p.isOnline = false; p.isActive = false; p.mode = nil; p.origin = Point(x: 0, y: 0)
    let base = Fixtures.snapshot([Fixtures.legion, p])
    let plan = RestorePlanner.plan(baseline: base, current: [Fixtures.legion, offline(Fixtures.p24)])
    #expect(plan.origins[DisplayID(raw: 3)] == nil)
    #expect(plan.modes[DisplayID(raw: 3)] == nil)
    #expect(plan.enable == ids(3))
    #expect(plan.origins[DisplayID(raw: 1)] == Point(x: 0, y: 0))
}
