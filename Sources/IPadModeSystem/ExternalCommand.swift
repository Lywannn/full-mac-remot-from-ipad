import Foundation

/// Runs one external tool with a deadline. Never throws or crashes: a missing tool, a failed launch or a timeout is `nil`.
public enum ExternalCommand {
    public struct Result {
        public var status: Int32
        public var output: String
        public var ok: Bool { status == 0 }
    }

    public static let defaultTimeout: TimeInterval = 5

    /// One reader only (the readability handler, collecting under a lock). After exit or kill, at most 1 s is
    /// spent waiting for EOF, then the pipe is closed.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = defaultTimeout) -> Result? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        let eof = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let lock = NSLock()
        var collected = Data()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; eof.signal(); return }
            lock.lock(); collected.append(chunk); lock.unlock()
        }
        func finish() {
            _ = eof.wait(timeout: .now() + 1)
            reader.readabilityHandler = nil
            try? reader.close()
        }
        do { try process.run() } catch {
            reader.readabilityHandler = nil
            try? reader.close()
            return nil
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            finish()
            return nil
        }
        finish()
        lock.lock(); let data = collected; lock.unlock()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
