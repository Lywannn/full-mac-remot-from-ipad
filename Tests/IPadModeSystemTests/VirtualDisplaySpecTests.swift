import Testing
import IPadModeCore
@testable import IPadModeSystem

/// The child's display, as pure values.
@Suite struct VirtualDisplaySpecTests {
    func m(_ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double) -> DisplayMode {
        DisplayMode(widthPoints: w, heightPoints: h, widthPixels: pw, heightPixels: ph, refreshHz: hz)
    }

    @Test func childLimitsAreTheRuled() {
        // R28; R25's own limits are R25Decision's (Core).
        #expect(VirtualDisplayChild.onlineTimeout == .seconds(3))
        #expect(VirtualDisplayChild.modeTimeout == .seconds(2))
        #expect(VirtualDisplayChild.pollInterval == 0.1)
        #expect(VirtualDisplayChild.dryRunVariable == "IPADMODE_VDISPLAY_DRY_RUN")
        #expect(VirtualDisplayChild.dryRunDisplayID == DisplayID(raw: 4242))
    }

    @Test func valuesMatchTheGlobalConstraints() {
        #expect(VirtualDisplaySpec.identity(.remote) == .init(name: "iPad Remote", productID: 0x0001, serial: 0x1A1D_0001))
        #expect(VirtualDisplaySpec.identity(.anchor) == .init(name: "iPad Jangkar", productID: 0x0002, serial: 0x1A1D_0002))
        #expect(VirtualDisplaySpec.identity(.fallback) == .init(name: "iPad Cadangan", productID: 0x0003, serial: 0x1A1D_0003))
        #expect(VirtualDisplaySpec.vendorID == 0x1A1D)
        #expect(VirtualDisplaySpec.widthMM == 227); #expect(VirtualDisplaySpec.heightMM == 158)
        #expect(VirtualDisplaySpec.maxPixelsWide == 3304); #expect(VirtualDisplaySpec.maxPixelsHigh == 2296)
        #expect(VirtualDisplaySpec.hiDPI)
    }

    @Test func requestedSizeIsTheFirstMode() throws {
        let r = try #require(Resolution(parsing: "1321x918"))
        #expect(VirtualDisplaySpec.modeOrder(requested: r).map(\.text)
                == ["1321x918", "1180x820", "1416x984", "1534x1066", "1652x1148"])
        #expect(VirtualDisplaySpec.modeOrder(requested: .defaultRemote) == Resolution.allowed)
    }

    @Test func requestedModeIsHiDPIAtSixtyHertz() {
        let r = Resolution.defaultRemote
        #expect(VirtualDisplaySpec.mode(r) == m(1180, 820, 2360, 1640, 60))
        #expect(VirtualDisplaySpec.isMode(m(1180, 820, 2360, 1640, 60), of: r))
        #expect(VirtualDisplaySpec.isMode(m(1180, 820, 2360, 1640, 59.94), of: r))
        #expect(!VirtualDisplaySpec.isMode(m(1180, 820, 1180, 820, 60), of: r))   // 1x
        #expect(!VirtualDisplaySpec.isMode(m(1180, 820, 2360, 1640, 30), of: r))
        #expect(!VirtualDisplaySpec.isMode(m(1321, 918, 2642, 1836, 60), of: r))
    }
}
