import Foundation

public enum LogTail {
    /// The last `count` lines of the file, reading backwards from its end in chunks; nil if it cannot be opened.
    public static func lastLines(of url: URL, count: Int, chunkSize: Int = 64 * 1024) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var offset = size
        var buffer = Data()
        func newlines(_ d: Data) -> Int { d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }
        // Need count lines plus the newline that ends the line before them (or the file start).
        while offset > 0 && newlines(buffer) <= count {
            let step = UInt64(min(UInt64(chunkSize), offset))
            offset -= step
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(step)) else { return nil }
            buffer = chunk + buffer
        }
        var text = String(decoding: buffer, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if buffer.isEmpty { return [] }
        if offset > 0 { lines.removeFirst() }   // the first line may be cut by the chunk edge
        return Array(lines.suffix(count))
    }
}
