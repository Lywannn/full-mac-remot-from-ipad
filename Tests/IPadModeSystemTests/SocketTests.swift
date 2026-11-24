import Testing
import Foundation
import Darwin
@testable import IPadModeSystem
@testable import IPadModeCore

enum SocketTestSupport {
    /// `/tmp/ipm-xxxxxx/s.sock`: short enough for `sun_path` (104 bytes), unlike `$TMPDIR` (R8).
    static func tempSocket() -> (dir: URL, path: URL) {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let tag = String((0..<6).map { _ in chars.randomElement()! })
        let dir = URL(fileURLWithPath: "/tmp/ipm-\(tag)", isDirectory: true)
        return (dir, dir.appendingPathComponent("s.sock"))
    }

    static func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    static func statusHandler(_ req: IPCRequest) async -> IPCResponse {
        IPCResponse(result: .ok("status:\(req)"))
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// A connected client fd that sends nothing; nil if the connect fails.
    static func connectRaw(_ path: URL) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let p = path.path
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, p, 104) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    /// The blocking client off the main actor, so the server (on the main actor) can answer.
    static func send(_ r: IPCRequest, path: URL, timeout: Duration = .seconds(5)) async throws -> IPCResponse {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global().async { c.resume(with: Result { try SocketClient.send(r, path: path, timeout: timeout) }) }
        }
    }

    /// Connects raw, writes `bytes`, then reads until EOF or `readTimeout`. `eof` says whether the server closed.
    static func raw(path: URL, write bytes: Data, readTimeout: TimeInterval = 8) async -> (data: Data, eof: Bool) {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                defer { close(fd) }
                var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
                let p = path.path
                withUnsafeMutablePointer(to: &addr.sun_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, p, 104) }
                }
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard rc == 0 else { c.resume(returning: (Data(), true)); return }
                var sent = 0
                bytes.withUnsafeBytes { raw in
                    while sent < bytes.count {
                        let n = write(fd, raw.baseAddress! + sent, bytes.count - sent)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                var out = Data(); var eof = false
                let deadline = Date().addingTimeInterval(readTimeout)
                var buf = [UInt8](repeating: 0, count: 4096)
                while Date() < deadline {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    if poll(&pfd, 1, 100) <= 0 { continue }
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { eof = true; break }
                    out.append(buf, count: n)
                }
                c.resume(returning: (out, eof))
            }
        }
    }
}

@Suite(.serialized) @MainActor struct SocketTests {
    @Test func socketRoundTripInTempDir() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let server = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        server.start(); defer { server.stop() }
        var st = stat(); #expect(stat(path.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        let r = try await SocketTestSupport.send(.status, path: path)
        #expect(r.result == .ok("status:status"))
        var dst = stat(); #expect(stat(dir.path, &dst) == 0)
        #expect(dst.st_mode & 0o777 == 0o700)
    }

    @Test func severalClientsAtOnceAllAnswered() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        var slowEntered = false
        let server = try SocketServer(path: path) { req in
            if case .resolution = req {
                slowEntered = true
                try? await Task.sleep(for: .milliseconds(2500))
            }
            return IPCResponse(result: .ok("\(req)"))
        }
        server.start(); defer { server.stop() }
        let slowDone = SocketTestSupport.Flag()
        let slow = Task {
            let r = try await SocketTestSupport.send(.resolution("slow"), path: path)
            slowDone.set(); return r
        }
        // Wait until the slow handler is really inside, then the fast ones must not be held up behind it.
        for _ in 0..<200 where !slowEntered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(slowEntered)
        let t0 = Date()
        let fast = try await withThrowingTaskGroup(of: IPCResponse.self) { g in
            for _ in 0..<8 { g.addTask { try await SocketTestSupport.send(.status, path: path) } }
            var all: [IPCResponse] = []
            for try await r in g { all.append(r) }
            return all
        }
        #expect(Date().timeIntervalSince(t0) < 1)
        #expect(!slowDone.value)
        #expect(fast.count == 8)
        #expect(fast.allSatisfy { $0.result == .ok("status") })
        #expect(try await slow.value.result == .ok("resolution(\"slow\")"))
    }

    @Test func connectionCapClosesTheExtraClient() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        var calls = 0
        let server = try SocketServer(path: path) { _ in calls += 1; return IPCResponse(result: .ok("x")) }
        server.start(); defer { server.stop() }
        var held: [Int32] = []
        defer { for fd in held { close(fd) } }
        for _ in 0..<SocketServer.maxConnections { held.append(try #require(SocketTestSupport.connectRaw(path))) }
        try await Task.sleep(for: .milliseconds(400))   // let the server accept them all
        let extra = try #require(SocketTestSupport.connectRaw(path)); defer { close(extra) }
        var pfd = pollfd(fd: extra, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pfd, 1, 1000) == 1)   // closed at once: readable with EOF, long before the 5 s limit
        var b: UInt8 = 0
        #expect(read(extra, &b, 1) == 0)
        // Freeing slots lets new clients in again.
        for fd in held { close(fd) }; held = []
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await SocketTestSupport.send(.status, path: path).result == .ok("x"))
    }

    @Test func silentClientClosedAfterAboutFiveSeconds() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        var calls = 0
        let server = try SocketServer(path: path) { _ in calls += 1; return IPCResponse(result: .ok("x")) }
        server.start(); defer { server.stop() }
        let t0 = Date()
        let r = await SocketTestSupport.raw(path: path, write: Data(), readTimeout: 10)
        let waited = Date().timeIntervalSince(t0)
        #expect(r.eof && r.data.isEmpty)
        #expect(waited > 4.5 && waited < 7)
        #expect(calls == 0)
        #expect(try await SocketTestSupport.send(.status, path: path).result == .ok("x"))
    }

    @Test func oversizeLineDropped() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        var calls = 0
        let server = try SocketServer(path: path) { _ in calls += 1; return IPCResponse(result: .ok("x")) }
        server.start(); defer { server.stop() }
        let r = await SocketTestSupport.raw(path: path, write: Data(repeating: UInt8(ascii: "a"), count: 200_000))
        #expect(r.eof && r.data.isEmpty)
        let r2 = await SocketTestSupport.raw(path: path, write: Data(repeating: UInt8(ascii: "a"), count: 70_000) + Data("\n".utf8))
        #expect(r2.eof && r2.data.isEmpty)
        #expect(calls == 0)
        #expect(try await SocketTestSupport.send(.status, path: path).result == .ok("x"))
    }

    @Test func badJSONGetsRefusal() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        var calls = 0
        let server = try SocketServer(path: path) { _ in calls += 1; return IPCResponse(result: .ok("x")) }
        server.start(); defer { server.stop() }
        for body in ["not json\n", "{\"frobnicate\":{}}\n"] {
            let r = await SocketTestSupport.raw(path: path, write: Data(body.utf8))
            let resp = try IPCFraming.decodeLine(r.data, as: IPCResponse.self)
            #expect(resp.result == .refused(.invalid, Messages.badRequest))
            #expect(r.eof)
        }
        #expect(calls == 0)
    }

    @Test func oneRequestPerConnection() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        var calls = 0
        let server = try SocketServer(path: path) { _ in calls += 1; return IPCResponse(result: .ok("x")) }
        server.start(); defer { server.stop() }
        let two = try IPCFraming.encode(IPCRequest.status) + IPCFraming.encode(IPCRequest.status)
        let r = await SocketTestSupport.raw(path: path, write: two)
        #expect(r.eof)
        #expect(r.data.filter { $0 == 0x0A }.count == 1)
        #expect(calls == 1)
    }

    @Test func secondServerOnLivePathThrowsAndFirstKeepsWorking() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let first = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        first.start(); defer { first.stop() }
        #expect(throws: SocketServerError.alreadyRunning) {
            _ = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        }
        #expect(try await SocketTestSupport.send(.status, path: path).result == .ok("status:status"))
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let dead = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        dead.start()
        // Simulate a crash: close the listener without unlinking the file.
        dead.abandonForTesting()
        #expect(FileManager.default.fileExists(atPath: path.path))
        let server = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        server.start(); defer { server.stop() }
        #expect(try await SocketTestSupport.send(.status, path: path).result == .ok("status:status"))
    }

    @Test func staleSocketReplacementIsRaceFree() throws {
        for _ in 0..<100 {
            let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
            let dead = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
            dead.start(); dead.abandonForTesting()
            let live = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
            live.start(); live.stop()
        }
    }

    @Test func stopUnlinksOnlyOurOwnFile() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let a = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        a.start()
        a.stop()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // Someone else's file at the path stays.
        let b = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        b.start()
        try FileManager.default.removeItem(at: path)
        try Data("other".utf8).write(to: path)
        b.stop()
        #expect(try Data(contentsOf: path) == Data("other".utf8))
    }

    @Test func tooLongPathThrows() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + "/s.sock")
        #expect(throws: SocketServerError.pathTooLong) {
            _ = try SocketServer(path: long, handler: SocketTestSupport.statusHandler)
        }
    }

    @Test func pathLengthBoundary() async throws {
        let (dir, _) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let prefix = dir.path + "/"
        let ok = URL(fileURLWithPath: prefix + String(repeating: "s", count: 103 - prefix.utf8.count))
        let tooLong = URL(fileURLWithPath: prefix + String(repeating: "s", count: 104 - prefix.utf8.count))
        #expect(ok.path.utf8.count == 103 && tooLong.path.utf8.count == 104)
        #expect(throws: SocketServerError.pathTooLong) { _ = try SocketServer(path: tooLong, handler: SocketTestSupport.statusHandler) }
        let server = try SocketServer(path: ok, handler: SocketTestSupport.statusHandler)
        server.start(); defer { server.stop() }
        #expect(try await SocketTestSupport.send(.status, path: ok).result == .ok("status:status"))
    }

    @Test func clientToStaleSocketFileThrowsNotRunning() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let dead = try SocketServer(path: path, handler: SocketTestSupport.statusHandler)
        dead.start(); dead.abandonForTesting()
        #expect(FileManager.default.fileExists(atPath: path.path))   // file exists, nobody listens: ECONNREFUSED
        await #expect(throws: SocketClientError.notRunning) { _ = try await SocketTestSupport.send(.status, path: path) }
    }

    @Test func clientToMissingPathThrowsNotRunning() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        await #expect(throws: SocketClientError.notRunning) { _ = try await SocketTestSupport.send(.status, path: path) }
    }

    @Test func clientTimesOutWhenHandlerNeverReturns() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let server = try SocketServer(path: path) { _ in
            try? await Task.sleep(for: .seconds(30)); return IPCResponse(result: .ok("late"))
        }
        server.start(); defer { server.stop() }
        let t0 = Date()
        await #expect(throws: SocketClientError.timeout) {
            _ = try await SocketTestSupport.send(.status, path: path, timeout: .seconds(1))
        }
        #expect(Date().timeIntervalSince(t0) < 2)
    }

    @Test func clientClosingBeforeResponseDoesNotKillServer() async throws {
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        let server = try SocketServer(path: path) { _ in
            try? await Task.sleep(for: .milliseconds(300)); return IPCResponse(result: .ok("x"))
        }
        server.start(); defer { server.stop() }
        for _ in 0..<5 {
            // Send the request and close at once; the server writes to a closed peer later.
            let line = try IPCFraming.encode(IPCRequest.status)
            _ = await SocketTestSupport.raw(path: path, write: line, readTimeout: 0)
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(try await SocketTestSupport.send(.status, path: path).result == .ok("x"))
    }

    @Test func garbageResponseIsBadResponse() async throws {
        // A fake server that answers non-JSON.
        let (dir, path) = SocketTestSupport.tempSocket(); defer { SocketTestSupport.cleanup(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd); unlink(path.path) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let p = path.path
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, p, 104) }
        }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(fd, 1)
        DispatchQueue.global().async {
            let c = accept(fd, nil, nil); var b = [UInt8](repeating: 0, count: 256); _ = read(c, &b, 256)
            _ = write(c, "garbage\n", 8); close(c)
        }
        await #expect(throws: SocketClientError.badResponse) { _ = try await SocketTestSupport.send(.status, path: path) }
    }
}
