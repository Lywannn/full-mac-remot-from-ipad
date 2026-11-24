import Foundation
import Testing
import IPadModeCore
@testable import IPadModeSystem

private typealias Support = VDisplayTestSupport

/// A-2: the logs show the raw CoreGraphics code.
@Suite struct DisplayBackendErrorTests {
    @Test func errorsDescribeTheirCGErrorCode() {
        #expect("\(DisplayBackendError.complete(.illegalArgument))" == "complete(CGError 1001)")
        #expect("\(DisplayBackendError.configure(DisplayID(raw: 3), .failure))" == "configure(3, CGError 1000)")
        let error: any Error = DisplayBackendError.listFailed(.cannotComplete)
        #expect("\(error)" == "listFailed(CGError 1004)")   // as the Coordinator logs it, through `any Error`
        #expect("\(DisplayBackendError.modeNotFound(DisplayID(raw: 50)))" == "modeNotFound(50)")
        #expect("\(DisplayBackendError.begin)" == "begin")
    }
}

extension DisplayChangingTests {
    /// The backend on this Mac's real displays, serialized with every other display-changing test (B-5). Every
    /// listing the round trip observes is a fresh one: another display-changing test may have run in this process
    /// before, and a stale start-of-test listing would record a wrong origin to put the monitor back at.
    @Suite struct CGDisplayBackendTests {
        @Test(.enabled(if: env("IPADMODE_HW_TESTS") == "1")) @MainActor
        func listsThisMacsMonitors() throws {
            let d = try CGDisplayBackend().listDisplays()
            for x in d {
                print("DISPLAY id=\(x.id.raw) name=\(x.name) kind=\(x.kind) vendor=0x\(String(x.vendor, radix: 16)) model=0x\(String(x.model, radix: 16)) online=\(x.isOnline) active=\(x.isActive) main=\(x.isMain) origin=(\(x.origin.x),\(x.origin.y)) mode=\(String(describing: x.mode)) uuid=\(x.uuid ?? "nil") loc=\(x.location ?? "nil")")
            }
            let phys = d.filter { $0.kind == .physical }
            #expect(phys.count >= 1); #expect(d.filter(\.isMain).count == 1)
            #expect(phys.contains { $0.vendor == 0x30AE && $0.model == 0x68F6 && $0.uuid != nil && $0.location != nil })
            #expect(d.allSatisfy { $0.mode.map { $0.widthPoints > 1 && $0.heightPoints > 1 } ?? true })
            let p24 = try #require(d.first { $0.vendor == 0x61A9 })
            let p24Mode = try #require(p24.mode)
            #expect((p24Mode.widthPoints, p24Mode.heightPoints) == (1080, 1920) || (p24Mode.widthPoints, p24Mode.heightPoints) == (1920, 1080))
            #expect(phys.filter(\.isOnline).allSatisfy { $0.mode != nil })
            #expect(phys.filter(\.isOnline).allSatisfy { $0.uuid != nil })
        }

        @Test(.enabled(if: env("IPADMODE_HW_TESTS") == "1" && env("IPADMODE_DISPLAY_TESTS") == "1")) @MainActor
        func toggleSecondaryMonitorRoundTrip() async throws {
            let b = CGDisplayBackend()
            let before = try Support.freshList(b)
            let main = try #require(before.first { $0.isMain })
            let target = try #require(before.first { $0.kind == .physical && $0.isOnline && !$0.isMain })

            func current() -> DisplayInfo? { Support.freshDisplays(b)?.first { $0.id == target.id } }
            func wait(_ secs: Double, _ cond: (DisplayInfo?) -> Bool) async throws -> Bool {
                let end = Date().addingTimeInterval(secs)
                while Date() < end {
                    if cond(try Support.freshList(b).first { $0.id == target.id }) { return true }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                return false
            }
            /// Re-enables the target, waits for it to be online and active, then restores its origin. Never throws.
            func restoreTarget() async -> (back: Bool, originOK: Bool) {
                for _ in 0..<3 {
                    try? b.setEnabled([target.id], enabled: true, scope: .session)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if current()?.isOnline == true { break }
                }
                var back = false
                let end = Date().addingTimeInterval(10)
                while Date() < end {
                    if let c = current(), c.isOnline, c.isActive { back = true; break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard back else { return (false, false) }
                let originOK = (try? b.setOrigins([target.id: target.origin], scope: .session)) != nil
                return (back, originOK)
            }

            try b.setEnabled([target.id], enabled: false, scope: .session)
            // Everything after the disable is inside this do: every exit path runs restoreTarget().
            do {
                #expect(try await wait(5) { $0?.isOnline != true })
                let off = try Support.freshList(b)
                let entry = try #require(off.first { $0.id == target.id })
                #expect(entry.kind == .physical); #expect(!entry.isOnline); #expect(!entry.isActive); #expect(entry.mode == nil)
                let mainNow = try #require(off.first { $0.id == main.id })
                #expect(mainNow.isMain); #expect(mainNow.isActive)

                let r = await restoreTarget()
                #expect(r.back); #expect(r.originOK)
                let after = try Support.freshList(b)
                #expect(after.first(where: { $0.isMain })?.id == main.id)
                #expect(after.first { $0.id == target.id }?.origin == target.origin)
            } catch {
                _ = await restoreTarget()
                throw error
            }
        }
    }
}
