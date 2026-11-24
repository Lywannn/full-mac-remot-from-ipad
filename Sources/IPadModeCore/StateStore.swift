import Foundation

public protocol StateStore: AnyObject {
    func load() -> PersistedState?
    func save(_ s: PersistedState) throws
}

enum AtomicFile {
    /// tulis ke <nama>.tmp -> fsync -> rename -> fsync folder; mode 0600.
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        func fail(_ what: String) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "\(what) \(tmp.path): \(String(cString: strerror(errno)))"])
        }
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw fail("open") }
        var isOpen = true
        do {
            var off = 0
            try data.withUnsafeBytes { buf in
                while off < buf.count {
                    let n = Foundation.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; throw fail("write") }
                    off += n
                }
            }
            guard fsync(fd) == 0 else { throw fail("fsync") }
            _ = fchmod(fd, 0o600)
            isOpen = false
            close(fd)
            guard rename(tmp.path, url.path) == 0 else { throw fail("rename") }
        } catch {
            // B-4: closed once only. When the rename failed the fd is closed already, and by then its number may
            // belong to a file another thread opened.
            if isOpen { close(fd) }
            unlink(tmp.path)
            throw error
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
        _ = chmod(url.path, 0o600)
    }
}

public final class FileStateStore: StateStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PersistedState.self, from: data)
    }

    public func save(_ s: PersistedState) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try enc.encode(s), to: url)
    }
}

public final class MemoryStateStore: StateStore {
    private var current: PersistedState?
    public private(set) var saves: [PersistedState] = []
    /// Asked before each save: an error it returns is thrown instead of saving, as a full disk would.
    public var saveFailure: ((PersistedState) -> (any Error)?)?
    public init(_ s: PersistedState?) { current = s }
    public func load() -> PersistedState? { current }
    public func save(_ s: PersistedState) throws {
        if let error = saveFailure?(s) { throw error }
        current = s; saves.append(s)
    }
}
