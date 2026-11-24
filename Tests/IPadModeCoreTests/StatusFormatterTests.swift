import Foundation
import Testing
@testable import IPadModeCore

struct StatusFormatterTests {
    private func state(_ phase: Phase, error: String? = nil) -> PersistedState {
        var s = PersistedState.initial
        s.phase = phase; s.lastError = error
        return s
    }
    private func text(_ phase: Phase, error: String? = nil, locked: Bool? = false,
                      daemon: ProcessLiveness? = nil, watchdog: ProcessLiveness? = nil) -> String {
        StatusFormatter.text(state(phase, error: error), displays: [Fixtures.virtualRemote, Fixtures.legion, Fixtures.off(Fixtures.p24)],
                             locked: locked, daemon: daemon, watchdog: watchdog)
    }

    @Test func statusTextShowsModeAndDisplays() {
        let t = text(.active(.remote))
        #expect(t.contains("Mode: Remote"))
        #expect(t.contains("iPad Remote"))
        #expect(t.contains("Legion 34W-2c"))
        #expect(t.contains("P24FBA-RAGL"))
    }

    @Test func everyPhaseLine() {
        #expect(text(.normal).contains("Mode: Normal"))
        #expect(text(.active(.remote)).contains("Mode: Remote\n"))
        #expect(text(.confirming(.remote)).contains("Mode: Remote (menunggu konfirmasi)"))
        #expect(text(.entering(.remote)).contains("Mode: Remote (sedang berpindah)"))
        #expect(text(.exiting).contains("Mode: kembali ke Normal (tertunda)"))
        #expect(text(.active(.sidecar)).contains("Mode: Sidecar"))
    }

    @Test func statusTextShowsLastError() {
        let t = text(.normal, error: "Layar virtual gagal dibuat — Mac tetap Normal.")
        #expect(t.contains("Layar virtual gagal dibuat — Mac tetap Normal."))
        #expect(!text(.normal).contains("Kesalahan terakhir"))
    }

    @Test func lockState() {
        #expect(text(.normal, locked: true).contains("Mac terkunci: ya"))
        #expect(text(.normal, locked: false).contains("Mac terkunci: tidak"))
        #expect(text(.normal, locked: nil).contains("Mac terkunci: tidak diketahui"))
    }

    @Test func processesWithPidsAndAges() {
        let t = text(.normal, daemon: ProcessLiveness(pid: 123, age: .seconds(1)), watchdog: nil)
        #expect(t.contains("Daemon: PID 123"))
        #expect(t.contains("detak 1 dtk lalu"))
        #expect(t.contains("Watchdog: tidak ada detak"))
    }

    @Test func displayFlags() {
        let t = text(.active(.remote))
        #expect(t.contains("offline"))
        #expect(t.contains("utama"))
        #expect(t.contains("1180x820"))
    }
}

struct StatusUnknownTests {
    @Test func unknownStateShowsUnknownMode() {
        let t = StatusFormatter.text(.initial, displays: [], locked: nil, stateKnown: false)
        #expect(t.contains("Mode: tidak diketahui"))
        #expect(!t.contains("Mode: Normal"))
    }
}
