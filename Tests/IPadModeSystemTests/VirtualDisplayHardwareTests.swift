import Foundation
import Darwin
import Testing
import IPadModeCore
@testable import IPadModeSystem

private typealias Support = VDisplayTestSupport

extension DisplayChangingTests {
    /// These create a virtual display and change the layout: run them by hand, with a safety net. Every
    /// listing they observe, and every listing of the host they test, is a fresh one (B-5, R75): the child and earlier
    /// tests change the displays from other processes and transactions.
    @Suite struct VirtualDisplayHardwareTests {
        @Test(.enabled(if: env("IPADMODE_HW_TESTS") == "1" && env("IPADMODE_DISPLAY_TESTS") == "1")) @MainActor
        func startAndStopVirtualDisplay() async throws {
            let bin = try #require(env("IPADMODE_BIN"), "IPADMODE_BIN names the built ipadmode binary")
            let backend = CGDisplayBackend()
            let dir = URL(fileURLWithPath: "/tmp/ipm-hw-" + UUID().uuidString.prefix(8), isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let pidFile = dir.appendingPathComponent("vdisplay-remote.pid")
            let host = ChildProcessVirtualDisplayHost(executable: URL(fileURLWithPath: bin),
                                                      backend: Support.FreshBackend(backend), pidDirectory: dir,
                                                      clock: ContinuousClock())

            let handle = try await host.start(role: .remote, resolution: .defaultRemote)
            // Everything after the start is inside this do: every exit path stops the display.
            do {
                let display = try #require(try Support.freshList(backend).first { $0.id == handle.displayID })
                #expect(display.kind == .ownVirtual)
                #expect(display.isOnline); #expect(display.isActive)
                let mode = try #require(display.mode)
                #expect((mode.widthPoints, mode.heightPoints) == (1180, 820))
                #expect((mode.widthPixels, mode.heightPixels) == (2360, 1640))
                #expect(Support.readPID(pidFile) == handle.pid)
            } catch {
                await host.stop(handle)
                throw error
            }

            let start = ContinuousClock.now
            await host.stop(handle)

            #expect(Support.elapsed(since: start) <= .seconds(3))
            #expect(try Support.freshList(backend).contains { $0.id == handle.displayID } == false)
            #expect(Support.isGone(handle.pid))
            #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        }

        /// R25: the child outlives its parent only long enough to turn the monitors back on.
        @Test(.enabled(if: env("IPADMODE_HW_TESTS") == "1" && env("IPADMODE_DISPLAY_TESTS") == "1")) @MainActor
        func childRestoresMonitorsWhenParentDies() async throws {
            let bin = try #require(env("IPADMODE_BIN"), "IPADMODE_BIN names the built ipadmode binary")
            let backend = CGDisplayBackend()
            let target = try #require(
                try Support.freshList(backend).first { $0.kind == .physical && $0.isOnline && !$0.isMain },
                "needs a second, non-main monitor")
            let clock = ContinuousClock()

            // The child's parent, as far as it knows: a helper that ends 3 s from now.
            let helper = try Support.spawn("/bin/sleep", ["3"])
            let child = Process()
            child.executableURL = URL(fileURLWithPath: bin)
            child.arguments = VDisplayProtocol.arguments(role: .remote, resolution: .defaultRemote,
                                                         parentPID: helper.processIdentifier)
            let stdout = Pipe()
            child.standardOutput = stdout
            child.standardInput = FileHandle.nullDevice
            try child.run()
            let output = ChildOutput(stdout.fileHandleForReading)
            defer {
                // Every path, a failed expectation included: the monitor on, and no process left behind.
                if Support.freshDisplays(backend)?.first(where: { $0.id == target.id })?.isOnline != true {
                    try? backend.setEnabled([target.id], enabled: true, scope: .session)
                }
                Support.end(child)
                Support.end(helper)
            }
            /// Turns the monitor on, waits for it, then puts it back where it was. Never throws. The enable is
            /// unconditional: on a monitor that is on already CoreGraphics refuses it (1001), which changes nothing.
            func restoreTarget() async -> Bool {
                func current() -> DisplayInfo? { Support.freshDisplays(backend)?.first { $0.id == target.id } }
                try? backend.setEnabled([target.id], enabled: true, scope: .session)
                let back = await clock.poll(timeout: .seconds(10), every: .milliseconds(250)) {
                    current().map { $0.isOnline && $0.isActive } ?? false
                }
                guard back else { return false }
                return (try? backend.setOrigins([target.id: target.origin], scope: .session)) != nil
            }

            do {
                _ = await clock.poll(timeout: .seconds(5), every: .milliseconds(50)) { output.outcome != nil }
                guard case .ready(let id)? = output.outcome else {
                    Issue.record("the child did not say READY: \(String(describing: output.outcome))")
                    return
                }
                // Every display poll below goes through `freshDisplays`: the changes come from another process (R75).
                #expect(await clock.poll(timeout: .seconds(5), every: .milliseconds(100)) {
                    Support.freshDisplays(backend)?.contains { $0.id == id && $0.kind == .ownVirtual && $0.isActive }
                        == true
                })
                try backend.setEnabled([target.id], enabled: false, scope: .session)
                #expect(await clock.poll(timeout: .seconds(3), every: .milliseconds(100)) {
                    Support.freshDisplays(backend)?.first { $0.id == target.id }?.isOnline == false
                })

                #expect(await clock.poll(timeout: .seconds(5), every: .milliseconds(50)) { !helper.isRunning })
                // R25 may take up to its 6 s deadline, and a monitor waking from standby needs 2–4 s (SP4): within
                // 8 s of the parent's end, in this order, the monitor is active again, the virtual display is gone,
                // and the child has exited 0.
                let limit = ContinuousClock.now.advanced(by: .seconds(8))
                func remaining() -> Duration { max(.zero, ContinuousClock.now.duration(to: limit)) }
                // T1: R25 releases only once every monitor it knows of is back, so its display must not be gone while
                // the target is not online yet.
                var goneEarly = false
                let back = await clock.poll(timeout: remaining(), every: .milliseconds(100)) {
                    guard let list = Support.freshDisplays(backend) else { return false }
                    let targetOnline = list.contains { $0.id == target.id && $0.isOnline }
                    if !targetOnline, !list.contains(where: { $0.id == id }) { goneEarly = true }
                    return list.contains { $0.id == target.id && $0.isOnline && $0.isActive }
                }
                #expect(!goneEarly, "the virtual display went before the monitor was back online")
                #expect(back, "the monitor active again within 8 s of the parent's end")
                let gone = await clock.poll(timeout: remaining(), every: .milliseconds(100)) {
                    Support.freshDisplays(backend).map { list in !list.contains { $0.id == id } } ?? false
                }
                #expect(gone, "the virtual display gone within 8 s of the parent's end")
                let exited = await clock.poll(timeout: remaining(), every: .milliseconds(50)) { !child.isRunning }
                #expect(exited, "the child ended within 8 s of the parent's end")
                if exited { #expect(child.terminationReason == .exit && child.terminationStatus == 0) }
                #expect(await restoreTarget(), "the monitor back at its original origin")
            } catch {
                _ = await restoreTarget()
                throw error
            }
        }
    }
}
