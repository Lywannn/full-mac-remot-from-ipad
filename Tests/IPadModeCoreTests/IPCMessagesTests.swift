import Testing
import Foundation
@testable import IPadModeCore

@Suite struct IPCMessagesTests {
    static let requests: [IPCRequest] = [
        .remote(confirmSeconds: nil), .remote(confirmSeconds: 0), .remote(confirmSeconds: 20),
        .sidecar, .normal, .status, .resolution("1180x820"), .shutdownForDisable,
    ]

    @Test func requestResponseRoundTrip() throws {
        for r in Self.requests {
            let data = try IPCFraming.encode(r)
            #expect(try IPCFraming.decodeLine(data, as: IPCRequest.self) == r)
        }
        let busy = IPCResponse(result: .refused(.busy, Messages.busy), state: nil, displays: nil)
        #expect(try IPCFraming.decodeLine(IPCFraming.encode(busy), as: IPCResponse.self) == busy)
        let full = IPCResponse(
            result: .ok("x"),
            state: PersistedState(phase: .active(.remote), baseline: Fixtures.snapshot([Fixtures.legion]), target: nil,
                                  virtualPID: 7, cleanShutdown: true, uncleanStarts: [], lastError: nil,
                                  updatedAt: Date(timeIntervalSince1970: 5)),
            displays: [Fixtures.legion, Fixtures.p24])
        #expect(try IPCFraming.decodeLine(IPCFraming.encode(full), as: IPCResponse.self) == full)
    }

    @Test func dateRoundTripsExactly() throws {
        let now = Date()
        var st = PersistedState.initial
        st.updatedAt = now
        st.uncleanStarts = [now.addingTimeInterval(0.123456)]
        let back = try IPCFraming.decodeLine(IPCFraming.encode(IPCResponse(result: .ok("x"), state: st)), as: IPCResponse.self)
        #expect(back.state?.updatedAt == now)
        #expect(back.state == st)
    }

    @Test func framingIsOneJSONLine() throws {
        let data = try IPCFraming.encode(IPCRequest.status)
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(data.dropLast().contains(UInt8(ascii: "\n")) == false)
        let bare = data.dropLast()
        #expect(try IPCFraming.decodeLine(Data(bare), as: IPCRequest.self) == .status)
        #expect(try IPCFraming.decodeLine(data, as: IPCRequest.self) == .status)
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try IPCFraming.decodeLine(Data("nope".utf8), as: IPCRequest.self) }
    }
}
