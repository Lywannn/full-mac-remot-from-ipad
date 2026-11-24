import Foundation
import Testing
@testable import IPadModeCore

@Test func heartbeatRoundTripCorruptAndAge() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("heartbeat.json")
    let hb = Heartbeat.now(pid: 42)
    try hb.write(url)
    #expect(Heartbeat.read(url) == hb)
    #expect(hb.age(nowNanos: hb.monotonicNanos + 6_000_000_000) == .seconds(6))
    #expect(hb.age(nowNanos: hb.monotonicNanos) == .zero)
    #expect(hb.age(nowNanos: hb.monotonicNanos - 1) == .zero)                     // sampling skew
    #expect(hb.age(nowNanos: hb.monotonicNanos - 2_000_000_000) == .zero)
    #expect(hb.age(nowNanos: hb.monotonicNanos - 2_000_000_001) > .seconds(3600))   // from a previous boot: stale
    try Data("{trunc".utf8).write(to: url)
    #expect(Heartbeat.read(url) == nil)
    #expect(Heartbeat.read(dir.appendingPathComponent("none.json")) == nil)
}
