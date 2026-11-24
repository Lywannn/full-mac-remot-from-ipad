import Testing
import Carbon.HIToolbox
@testable import IPadModeSystem
@testable import IPadModeCore

@Suite struct LockParsingTests {
    @Test func lockParsing() {
        #expect(isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": true]))
        #expect(isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": 1]))
        #expect(isScreenLocked(sessionInfo: [:]) == false)
        #expect(isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": false]) == false)
        #expect(isScreenLocked(sessionInfo: ["CGSSessionScreenIsLocked": 0]) == false)
        #expect(isScreenLocked(sessionInfo: ["kCGSSessionOnConsoleKey": false]))
        #expect(isScreenLocked(sessionInfo: ["kCGSSessionOnConsoleKey": true]) == false)
        #expect(isScreenLocked(sessionInfo: ["kCGSSessionOnConsoleKey": NSNumber(value: 0)]))
    }

    @MainActor @Test func liveReadDoesNotCrash() {
        let m = ScreenLockMonitor(onChange: { _ in })
        let v: Bool = m.isLocked
        _ = v
    }

    @Test func everyKeyMatchesCarbon() {
        let letters: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        #expect(letters.count == 36)
        for (k, code) in letters { #expect(HotkeySpec(parsing: "ctrl+\(k)")?.keyCode == UInt32(code), "\(k)") }
        let fs = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fs.enumerated() { #expect(HotkeySpec(parsing: "ctrl+f\(i + 1)")?.keyCode == UInt32(code), "f\(i + 1)") }
    }

    @Test func hotkeyMatchesCarbon() throws {
        let s = try #require(HotkeySpec(parsing: "ctrl+opt+cmd+n"))
        #expect(s.keyCode == UInt32(kVK_ANSI_N))
        #expect(s.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(HotkeySpec(parsing: "shift+cmd+f1")?.keyCode == UInt32(kVK_F1))
        #expect(HotkeySpec(parsing: "cmd+shift+n")?.carbonModifiers == UInt32(cmdKey | shiftKey))
    }
}
