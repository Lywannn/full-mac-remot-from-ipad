import Testing
@testable import IPadModeCore

@Suite struct VDisplayProtocolTests {
    @Test func readyLineRoundTrip() {
        let id = DisplayID(raw: 12345)
        #expect(VDisplayProtocol.readyLine(id) == "READY 12345\n")
        #expect(VDisplayProtocol.parseReady(VDisplayProtocol.readyLine(id)) == id)
        #expect(VDisplayProtocol.parseReady("READY 12345") == id)
        #expect(VDisplayProtocol.parseReady("READY 4294967295") == DisplayID(raw: .max))
        #expect(VDisplayProtocol.parseReady("garbage") == nil)
        #expect(VDisplayProtocol.parseReady("READY 12\n\n") == nil)   // one line only
    }

    @Test(arguments: ["", "READY", "READY ", "READY x", "READY 0", "READY -1", "READY +5", "READY 4294967296",
                      "READY 12 34", "READY  12", " READY 12", "ready 12", "READY 0x1A",
                      "ERROR 12"])
    func parseReadyRejects(_ line: String) {
        #expect(VDisplayProtocol.parseReady(line) == nil)
    }

    @Test func errorLineRoundTrip() {
        #expect(VDisplayProtocol.errorLine("mode-unavailable") == "ERROR mode-unavailable\n")
        #expect(VDisplayProtocol.parseError(VDisplayProtocol.errorLine("mode-unavailable")) == "mode-unavailable")
        #expect(VDisplayProtocol.parseError("ERROR mode-unavailable") == "mode-unavailable")
        // Always exactly one line, whatever the reason holds.
        #expect(VDisplayProtocol.errorLine("two\nlines\r\n") == "ERROR two lines\n")
        #expect(VDisplayProtocol.errorLine("") == "ERROR\n")
        #expect(VDisplayProtocol.parseError("ERROR") == "")
        #expect(VDisplayProtocol.parseError("ERROR\n") == "")
        #expect(VDisplayProtocol.parseError("READY 12") == nil)
        #expect(VDisplayProtocol.parseError("ERRORS x") == nil)
        #expect(VDisplayProtocol.parseError("error x") == nil)
    }

    @Test func argumentsRoundTrip() {
        #expect(VDisplayProtocol.arguments(role: .remote, resolution: .defaultRemote, parentPID: 123)
                == ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "123"])
        for role in [VirtualRole.remote, .anchor, .fallback] {
            for resolution in Resolution.allowed {
                let args = VDisplayProtocol.arguments(role: role, resolution: resolution, parentPID: 4242)
                let parsed = VDisplayProtocol.parseArguments(args)
                #expect(parsed?.role == role)
                #expect(parsed?.resolution == resolution)
                #expect(parsed?.parentPID == 4242)
            }
        }
    }

    @Test func parseArgumentsAcceptsAnyFlagOrder() {
        let parsed = VDisplayProtocol.parseArguments(
            ["vdisplay", "--parent", "77", "--resolution", "1321x918", "--role", "anchor"])
        #expect(parsed?.role == .anchor)
        #expect(parsed?.resolution == Resolution(parsing: "1321x918"))
        #expect(parsed?.parentPID == 77)
    }

    @Test(arguments: [
        [],
        ["vdisplay"],
        ["daemon", "--role", "remote", "--resolution", "1180x820", "--parent", "123"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820"],
        ["vdisplay", "--role", "tv", "--resolution", "1180x820", "--parent", "123"],
        ["vdisplay", "--role", "remote", "--resolution", "1024x768", "--parent", "123"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "1"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "0"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "-5"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "+123"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "abc"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "99999999999"],
        ["vdisplay", "--role", "remote", "--role", "anchor", "--resolution", "1180x820", "--parent", "123"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "123", "--extra", "1"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent", "123", "stray"],
        ["vdisplay", "--role", "remote", "--resolution", "1180x820", "--parent"],
        ["vdisplay", "--role", "remote", "--size", "1180x820", "--parent", "123"],
    ])
    func parseArgumentsRejects(_ args: [String]) {
        #expect(VDisplayProtocol.parseArguments(args) == nil)
    }
}
