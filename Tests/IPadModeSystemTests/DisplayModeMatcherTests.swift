import Testing
import IPadModeCore
@testable import IPadModeSystem

@Suite struct DisplayModeMatcherTests {
    func m(_ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double) -> DisplayMode {
        DisplayMode(widthPoints: w, heightPoints: h, widthPixels: pw, heightPixels: ph, refreshHz: hz)
    }

    func best(_ w: DisplayMode, in c: [DisplayMode], rotation: Double) -> Int? {
        DisplayModeMatcher.bestMatch(w, in: c.map { .init(mode: $0) }, rotation: rotation)
    }

    @Test func matchesPointsAndPixelsNotJustPoints() {
        let c = [m(1180, 820, 1180, 820, 60), m(1180, 820, 2360, 1640, 60)]
        #expect(best(m(1180, 820, 2360, 1640, 60), in: c, rotation: 0) == 1)
    }
    @Test func rotatedAcceptsSwappedOnly() {
        let c = [m(1920, 1080, 1920, 1080, 100)]
        let want = m(1080, 1920, 1080, 1920, 100)
        #expect(best(want, in: c, rotation: 0) == nil)
        #expect(best(want, in: c, rotation: 90) == 0)
        #expect(best(want, in: c, rotation: 270) == 0)
        #expect(best(want, in: c, rotation: 180) == nil)
    }
    @Test func refreshPrefersClosestWithinHalfHzElseAny() {
        let c = [m(100, 100, 100, 100, 60), m(100, 100, 100, 100, 120)]
        #expect(best(m(100, 100, 100, 100, 119.8), in: c, rotation: 0) == 1)
        #expect(best(m(100, 100, 100, 100, 75), in: c, rotation: 0) == 0)
    }
    @Test func refreshPicksNearestAmongSeveralWithinTolerance() {
        let c = [m(100, 100, 100, 100, 59.94), m(100, 100, 100, 100, 60)]
        #expect(best(m(100, 100, 100, 100, 60), in: c, rotation: 0) == 1)
        #expect(best(m(100, 100, 100, 100, 59.9), in: c, rotation: 0) == 0)
        // nothing within tolerance: nearest overall, not first listed
        let d = [m(100, 100, 100, 100, 30), m(100, 100, 100, 100, 50)]
        #expect(best(m(100, 100, 100, 100, 60), in: d, rotation: 0) == 1)
        // exact tie keeps list order
        let e = [m(100, 100, 100, 100, 60), m(100, 100, 100, 100, 60)]
        #expect(best(m(100, 100, 100, 100, 60), in: e, rotation: 0) == 0)
    }
    @Test func prefersDesktopUsableButNeverFiltersToZero() {
        let w = m(100, 100, 100, 100, 60)
        let mixed: [DisplayModeMatcher.Candidate] = [.init(mode: w, usable: false), .init(mode: w, usable: true)]
        #expect(DisplayModeMatcher.bestMatch(w, in: mixed, rotation: 0) == 1)
        let none: [DisplayModeMatcher.Candidate] = [.init(mode: w, usable: false)]
        #expect(DisplayModeMatcher.bestMatch(w, in: none, rotation: 0) == 0)
    }
    @Test func directMatchStillAcceptedWhenRotated() {
        let c = [m(1080, 1920, 1080, 1920, 100)]
        #expect(best(m(1080, 1920, 1080, 1920, 100), in: c, rotation: 90) == 0)
    }
    @Test func noMatchIsNil() {
        #expect(best(m(1, 2, 3, 4, 60), in: [m(100, 100, 100, 100, 60)], rotation: 0) == nil)
    }
    @Test func oneByOneAndOfflineMapToNil() {
        #expect(DisplayModeMatcher.normalized(m(1, 1, 1, 1, 0), isOnline: true) == nil)
        #expect(DisplayModeMatcher.normalized(m(1920, 1080, 1920, 1080, 60), isOnline: false) == nil)
        #expect(DisplayModeMatcher.normalized(m(1920, 1080, 1920, 1080, 60), isOnline: true) != nil)
    }
    @Test func productName() {
        #expect(DisplayModeMatcher.productName(["de_DE": "A", "en_US": "B"], fallbackID: 7) == "B")
        #expect(DisplayModeMatcher.productName(["de_DE": "A"], fallbackID: 7) == "A")
        #expect(DisplayModeMatcher.productName([String: String](), fallbackID: 7) == "Display 7")
        #expect(DisplayModeMatcher.productName(nil, fallbackID: 7) == "Display 7")
    }
}
