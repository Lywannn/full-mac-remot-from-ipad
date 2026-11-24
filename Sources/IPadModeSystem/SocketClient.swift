import Foundation
import Darwin
import IPadModeCore

public enum SocketClientError: Error, Equatable {
    /// The socket file is missing or nothing listens on it: the daemon is not running (`Messages.daemonDown`).
    case notRunning
    /// No complete answer before the deadline.
    case timeout
    /// EOF before a full line, an oversize line, or JSON that does not decode.
    case badResponse
    /// Any other system failure: name and errno.
    case system(String, Int32)
}

/// The CLI's end: synchronous and blocking, for a short-lived process. Every wait is a `poll` against one deadline.
public enum SocketClient {
    public static let maxResponseBytes = 4 * 1024 * 1024

    public static func send(_ request: IPCRequest, path: URL, timeout: Duration) throws -> IPCResponse {
        let deadline = ContinuousClock.now + timeout
        let p = path.path
        guard p.utf8.count < 104 else { throw SocketClientError.notRunning }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError.system("socket", errno) }
        defer { close(fd) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
        else { throw SocketClientError.system("configure", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, p, 104) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED, ENOTDIR: throw SocketClientError.notRunning
            case EINPROGRESS, EAGAIN, EINTR:
                try wait(fd, POLLOUT, deadline)
                var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == ENOENT || err == ECONNREFUSED { throw SocketClientError.notRunning }
                if err != 0 { throw SocketClientError.system("connect", err) }
            default: throw SocketClientError.system("connect", errno)
            }
        }

        let line: Data
        do { line = try IPCFraming.encode(request) } catch { throw SocketClientError.system("encode", 0) }
        var sent = 0
        while sent < line.count {
            let n = line.withUnsafeBytes { write(fd, $0.baseAddress! + sent, line.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EAGAIN || errno == EINTR { try wait(fd, POLLOUT, deadline); continue }
            if n < 0, errno == EPIPE || errno == ECONNRESET { throw SocketClientError.badResponse }
            throw SocketClientError.system("write", errno)
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let nl = response.firstIndex(of: 0x0A) {
                do { return try IPCFraming.decodeLine(Data(response[response.startIndex..<nl]), as: IPCResponse.self) }
                catch { throw SocketClientError.badResponse }
            }
            guard response.count <= maxResponseBytes else { throw SocketClientError.badResponse }
            try wait(fd, POLLIN, deadline)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { response.append(chunk, count: n); continue }
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            if n < 0, errno == ECONNRESET { throw SocketClientError.badResponse }
            if n < 0 { throw SocketClientError.system("read", errno) }
            throw SocketClientError.badResponse   // EOF before "\n"
        }
    }

    /// Waits for `events` on `fd`; throws `.timeout` once `deadline` has passed.
    private static func wait(_ fd: Int32, _ events: Int32, _ deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = deadline - ContinuousClock.now
            let c = remaining.components
            let ms = c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
            if ms <= 0 { throw SocketClientError.timeout }
            var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
            let r = poll(&pfd, 1, Int32(min(ms, 1000)))
            if r > 0 { return }
            if r < 0 && errno != EINTR { throw SocketClientError.system("poll", errno) }
        }
    }
}
