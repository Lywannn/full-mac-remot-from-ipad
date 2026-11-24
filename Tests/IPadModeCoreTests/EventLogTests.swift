import Foundation
import Testing
@testable import IPadModeCore

@Test func eventLogRotatesAtMaxBytes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = EventLog(directory: dir, maxBytes: 200, keep: 3)
    for i in 0..<30 { log.record("evt", ["i": String(i)]) }
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix("._") })
    #expect(names == ["ipadmode.jsonl", "ipadmode.jsonl.1", "ipadmode.jsonl.2", "ipadmode.jsonl.3"])
}

@Test func eventLogLineFormat() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = EventLog(directory: dir)
    log.record("hello", ["a": "b"])
    let text = try String(contentsOf: dir.appendingPathComponent("ipadmode.jsonl"), encoding: .utf8)
    #expect(text.hasSuffix("\n"))
    let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    #expect(obj?["name"] as? String == "hello")
    #expect((obj?["fields"] as? [String: String]) == ["a": "b"])
    #expect(ISO8601DateFormatter().date(from: obj?["ts"] as? String ?? "") != nil)
}
