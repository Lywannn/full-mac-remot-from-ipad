import Foundation
import Darwin
import IPadModeCore

public enum SocketServerError: Error, Equatable {
    /// `sun_path` holds fewer than 104 bytes.
    case pathTooLong
    /// A live server already answers on this path; its file is left alone.
    case alreadyRunning
    /// The path exists and is not a socket.
    case notASocket
    /// A system call failed: name and errno.
    case system(String, Int32)
}

/// The daemon's end of the CLI socket (spec: Unix socket, 0600). One JSON line in, one JSON line out, per connection.
///
/// The daemon must survive any client (R42): no SIGPIPE, bounded input (64 KiB, 5 s), bad JSON is answered, only our
/// own uid may talk, and an existing live socket is never stolen. All socket I/O runs on a private serial queue and
/// never blocks the main thread; the request handler is reached with a `Task` hop onto the MainActor (never
/// `MainActor.assumeIsolated`, which traps off the real main thread, R76), and the response is written when its async
/// result arrives.
public final class SocketServer {
    public static let maxRequestBytes = 64 * 1024
    public static let requestTimeout: TimeInterval = 5

    private let path: URL
    private let handler: @MainActor (IPCRequest) async -> IPCResponse
    private let queue = DispatchQueue(label: "ipadmode.socket-server")
    private static let queueKey = DispatchSpecificKey<Void>()

    // Touched only on `queue` (and in init/deinit).
    private var listenFD: Int32
    private var boundDev: dev_t = 0
    private var boundIno: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var stopped = false
    /// Entered while the accept source exists, left once its cancel handler has closed the listening fd.
    private let listenerClosed = DispatchGroup()
    private var acceptSuspended = false
    static let maxConnections = 32

    public init(path: URL, handler: @escaping @MainActor (IPCRequest) async -> IPCResponse) throws {
        self.path = path
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: ())
        let p = path.path
        guard p.utf8.count < 104 else { throw SocketServerError.pathTooLong }

        try Self.ensureDirectory(path.deletingLastPathComponent())
        var st = stat()
        if lstat(p, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw SocketServerError.notASocket }
            if Self.liveServerAnswers(at: p) { throw SocketServerError.alreadyRunning }
            unlink(p)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.system("socket", errno) }
        do {
            try Self.configure(fd)
            var addr = Self.address(p)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard rc == 0 else { throw SocketServerError.system("bind", errno) }
            // From here the file is ours; any failure below removes it again.
            var bound = stat()
            guard lstat(p, &bound) == 0 else { throw SocketServerError.system("stat", errno) }
            boundDev = bound.st_dev; boundIno = bound.st_ino
            guard chmod(p, 0o600) == 0 else { throw SocketServerError.system("chmod", errno) }
            guard listen(fd, 16) == 0 else { throw SocketServerError.system("listen", errno) }
        } catch {
            close(fd)
            if boundIno != 0 { unlink(p) }
            throw error
        }
        listenFD = fd
    }

    deinit { stop() }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.acceptSource == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: self.listenFD, queue: self.queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            let fd = self.listenFD
            let closed = self.listenerClosed
            closed.enter()
            source.setCancelHandler { close(fd); closed.leave() }
            self.acceptSource = source
            source.resume()
        }
    }

    /// Cancels everything, closes every fd and unlinks the socket file only if it is still the one we bound.
    public func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { stopOnQueue(unlink: true) }
        else { queue.sync { stopOnQueue(unlink: true) } }
    }

    /// Test hook: what a crash leaves behind: no listener, the file still there.
    func abandonForTesting() {
        queue.sync { stopOnQueue(unlink: false) }
        listenerClosed.wait()   // the listening fd is really closed when this returns
    }

    private func stopOnQueue(unlink doUnlink: Bool) {
        guard !stopped else { return }
        stopped = true
        for c in connections.values { c.close() }
        connections.removeAll()
        if let source = acceptSource {
            if acceptSuspended { acceptSuspended = false; source.resume() }   // a suspended source cannot finish cancelling
            source.cancel(); acceptSource = nil
        } else { close(listenFD) }
        if doUnlink {
            var st = stat()
            let p = path.path
            if lstat(p, &st) == 0, st.st_dev == boundDev, st.st_ino == boundIno { unlink(p) }
        }
    }

    // MARK: accept

    private func acceptPending() {
        while !stopped {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EMFILE || errno == ENFILE { pauseAccepting() }   // else EAGAIN: drained
                return
            }
            guard connections.count < Self.maxConnections else { close(fd); continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(), (try? Self.configure(fd)) != nil else {
                close(fd); continue
            }
            let conn = Connection(fd: fd, queue: queue)
            connections[ObjectIdentifier(conn)] = conn
            conn.onClose = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.connections[ObjectIdentifier(conn)] = nil
            }
            conn.beginReading { [weak self] line in self?.dispatch(line, on: conn) }
        }
    }

    /// Out of descriptors: the pending connection would keep the source firing, so stop for 100 ms.
    private func pauseAccepting() {
        guard let source = acceptSource, !acceptSuspended else { return }
        acceptSuspended = true
        source.suspend()
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, self.acceptSuspended, let source = self.acceptSource else { return }
            self.acceptSuspended = false
            source.resume()
        }
    }

    private func dispatch(_ line: Data, on conn: Connection) {
        guard let request = try? IPCFraming.decodeLine(line, as: IPCRequest.self) else {
            let bad = IPCResponse(result: .refused(.invalid, Messages.badRequest))
            conn.respond((try? IPCFraming.encode(bad)) ?? Data())
            return
        }
        let handler = self.handler
        let queue = self.queue
        Task { @MainActor in
            let response = await handler(request)
            let data = (try? IPCFraming.encode(response)) ?? Data()
            queue.async { conn.respond(data) }
        }
    }

    // MARK: setup helpers

    private static func ensureDirectory(_ dir: URL) throws {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { throw SocketServerError.system("mkdir", Int32(truncatingIfNeeded: (error as NSError).code)) }
    }

    /// Close-on-exec, non-blocking, no SIGPIPE (R42.1).
    fileprivate static func configure(_ fd: Int32) throws {
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
        else { throw SocketServerError.system("configure", errno) }
    }

    fileprivate static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        return addr
    }

    /// Whether something accepts connections on this socket file: a live server, which we must not replace.
    private static func liveServerAnswers(at p: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = try? configure(fd)
        var addr = address(p)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc == 0 { return true }
        // ECONNREFUSED / ENOENT: nobody listens. A busy listener (EAGAIN/EINPROGRESS) is alive.
        return errno == EAGAIN || errno == EINPROGRESS
    }
}

/// One accepted client. Every method runs on the server's queue. It ends in `close()`, from whichever of these comes
/// first: a bad or oversize request, the 5 s limit, EOF, a write error, or the response written.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let closer: FDCloser
    private let queue: DispatchQueue
    private var buffer = Data()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var timer: DispatchSourceTimer?
    private var pending = Data()
    private var closed = false
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) { self.fd = fd; self.closer = FDCloser(fd); self.queue = queue }

    func beginReading(onLine: @escaping (Data) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readable(onLine) }
        arm(source) { self.readSource = nil }
        readSource = source
        startTimer()
        source.resume()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + SocketServer.requestTimeout)
        t.setEventHandler { [weak self] in self?.close() }
        timer = t
        t.resume()
    }

    private func arm(_ source: DispatchSourceProtocol, onCancel: @escaping () -> Void) {
        // The cancel handler holds the closer, not `self`: the fd is closed whatever happens to the Connection.
        let closer = self.closer
        closer.live += 1
        source.setCancelHandler { onCancel(); closer.live -= 1; closer.closeIfDone() }
    }

    private func readable(_ onLine: (Data) -> Void) {
        guard !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { if errno == EAGAIN || errno == EINTR { return }; close(); return }
        if n == 0 { close(); return }   // EOF before a complete line
        buffer.append(chunk, count: n)
        if let nl = buffer.firstIndex(of: 0x0A) {
            guard nl - buffer.startIndex <= SocketServer.maxRequestBytes else { close(); return }
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer = Data()
            readSource?.cancel()   // one request per connection: anything after the first line is ignored
            timer?.cancel(); timer = nil
            onLine(line)
        } else if buffer.count > SocketServer.maxRequestBytes {
            close()
        }
    }

    /// Writes the response and closes; a peer that is gone (EPIPE) or too slow just ends the connection.
    func respond(_ data: Data) {
        guard !closed else { return }
        pending = data
        startTimer()   // a client that never reads gets the same 5 s
        flush()
    }

    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            if n > 0 { pending.removeFirst(n); continue }
            if n < 0, errno == EAGAIN || errno == EINTR {
                if writeSource == nil {
                    let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    w.setEventHandler { [weak self] in self?.flush() }
                    arm(w) { self.writeSource = nil }
                    writeSource = w
                    w.resume()
                }
                return
            }
            close(); return   // EPIPE, ECONNRESET, ...
        }
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        readSource?.cancel()
        writeSource?.cancel()
        closer.requestClose()
        onClose?(); onClose = nil
    }
}

/// Closes a connection's fd exactly once, after `close()` was requested and every source on it has finished
/// cancelling. Queue-confined like the Connection that owns it.
private final class FDCloser: @unchecked Sendable {
    let fd: Int32
    var live = 0
    private var requested = false, done = false
    init(_ fd: Int32) { self.fd = fd }
    func requestClose() { requested = true; closeIfDone() }
    func closeIfDone() { if requested, live == 0, !done { done = true; Darwin.close(fd) } }
}
