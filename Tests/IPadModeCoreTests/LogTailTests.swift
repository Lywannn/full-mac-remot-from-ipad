import Foundation
import Testing
@testable import IPadModeCore

struct LogTailTests {
    private func file(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-log-" + UUID().uuidString)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func lastLinesOfShortFile() throws {
        let url = try file("a\nb\nc\n")
        #expect(LogTail.lastLines(of: url, count: 50) == ["a", "b", "c"])
        #expect(LogTail.lastLines(of: url, count: 2) == ["b", "c"])
    }

    @Test func noTrailingNewline() throws {
        #expect(LogTail.lastLines(of: try file("a\nb"), count: 5) == ["a", "b"])
    }

    @Test func largeFileOnlyTail() throws {
        let content = (1...20_000).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n") + "\n"
        let url = try file(content)
        let lines = LogTail.lastLines(of: url, count: 50, chunkSize: 4096)
        #expect(lines?.count == 50)
        #expect(lines?.first?.hasPrefix("line 19951 ") == true)
        #expect(lines?.last?.hasPrefix("line 20000 ") == true)
    }

    @Test func missingOrEmptyFile() throws {
        #expect(LogTail.lastLines(of: URL(fileURLWithPath: "/nonexistent/ipm"), count: 5) == nil)
        #expect(LogTail.lastLines(of: try file(""), count: 5) == [])
    }

    @Test func multibyteLinesSurviveChunkBoundaries() throws {
        let content = (1...500).map { "baris \($0) — ✓✓✓" }.joined(separator: "\n") + "\n"
        let lines = LogTail.lastLines(of: try file(content), count: 100, chunkSize: 37)
        #expect(lines?.count == 100)
        #expect(lines?.first == "baris 401 — ✓✓✓")
    }

    @Test func displaysFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-disp-" + UUID().uuidString)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try WatchdogFiles.writeDisplays([Fixtures.legion], at: t, to: url)
        let f = WatchdogFiles.readDisplays(at: url)
        #expect(f?.displays == [Fixtures.legion])
        #expect(f?.time == t)
        #expect(WatchdogFiles.readDisplays(at: URL(fileURLWithPath: "/nonexistent/x")) == nil)
    }
}
