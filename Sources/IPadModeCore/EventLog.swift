import Foundation
import os

public protocol EventSink: AnyObject, Sendable {
    func record(_ name: String, _ fields: [String: String])
}

public final class EventLog: EventSink, @unchecked Sendable {
    private let directory: URL, baseName: String
    private let maxBytes: Int, keep: Int
    private let logger: Logger
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(directory: URL, baseName: String = "ipadmode", maxBytes: Int = 5_000_000,
                keep: Int = 3, subsystem: String = "local.ipadmode") {
        self.directory = directory; self.baseName = baseName
        self.maxBytes = maxBytes; self.keep = keep
        self.logger = Logger(subsystem: subsystem, category: "events")
    }

    private var current: URL { directory.appendingPathComponent("\(baseName).jsonl") }
    private func rotated(_ i: Int) -> URL { directory.appendingPathComponent("\(baseName).jsonl.\(i)") }

    public func record(_ name: String, _ fields: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        let entry: [String: Any] = ["ts": formatter.string(from: Date()), "name": name, "fields": fields]
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        logger.notice("\(name, privacy: .public) \(fields.description, privacy: .public)")

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > maxBytes { rotate() }
        if !fm.fileExists(atPath: current.path) { fm.createFile(atPath: current.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: current) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    private func rotate() {
        let fm = FileManager.default
        guard keep > 0 else { try? fm.removeItem(at: current); return }
        try? fm.removeItem(at: rotated(keep))
        for i in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: rotated(i).path) {
            try? fm.moveItem(at: rotated(i), to: rotated(i + 1))
        }
        try? fm.moveItem(at: current, to: rotated(1))
    }
}
