import Testing
@testable import IPadModeCore

@Suite struct HotkeySpecTests {
    @Test func hotkeyParsing() throws {
        let s = try #require(HotkeySpec(parsing: "ctrl+opt+cmd+n"))
        #expect(s.keyCode == 0x2D)
        #expect(s.carbonModifiers == (0x1000 | 0x0800 | 0x0100))
        #expect(HotkeySpec(parsing: " Control + Option + Command + N ") == s)
        #expect(HotkeySpec(parsing: "alt+control+command+n") == s)
        #expect(HotkeySpec(parsing: "foo") == nil)
        #expect(HotkeySpec(parsing: "ctrl+opt+cmd+n\n") == s)
        #expect(HotkeySpec(parsing: "\tctrl+opt+cmd+n \r\n") == s)
    }

    @Test func shiftAddsModifier() throws {
        let s = try #require(HotkeySpec(parsing: "cmd+shift+f12"))
        #expect(s.keyCode == 0x6F)
        #expect(s.carbonModifiers == (0x0100 | 0x0200))
    }

    @Test func rejections() {
        for bad in ["shift+n", "n", "ctrl+opt+cmd", "ctrl+opt+cmd+n+m", "foo", "", "ctrl+ctrl+n", "ctrl++n",
                    "ctrl+opt+f13", "ctrl+cmd+-", "cmd+control+alt+shift", "ctrl+n+"] {
            #expect(HotkeySpec(parsing: bad) == nil, "\(bad)")
        }
    }

    @Test func everyAllowedKeyParses() {
        for k in "abcdefghijklmnopqrstuvwxyz0123456789" { #expect(HotkeySpec(parsing: "ctrl+\(k)") != nil) }
        for i in 1...12 { #expect(HotkeySpec(parsing: "ctrl+f\(i)") != nil) }
    }
}
