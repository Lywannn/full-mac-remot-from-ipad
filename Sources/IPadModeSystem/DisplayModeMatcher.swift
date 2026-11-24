import IPadModeCore

/// Pure helpers for the CoreGraphics backend, kept over value types so they can be unit tested.
enum DisplayModeMatcher {
    /// Index of the candidate that best matches `wanted`, or nil. Sizes must match in points and pixels;
    /// when the display is rotated 90/270 the swapped (h, w) match is accepted too (the direct one always is).
    /// Among size matches, desktop-usable modes are preferred (never filtered to zero), then the nearest
    /// refresh within 0.5 Hz, else the nearest overall; ties keep list order.
    static func bestMatch(_ wanted: DisplayMode, in candidates: [Candidate], rotation: Double) -> Int? {
        let rotated = Int(rotation.rounded()) % 180 != 0
        var sized = candidates.indices.filter { i in
            let c = candidates[i].mode
            let direct = c.widthPoints == wanted.widthPoints && c.heightPoints == wanted.heightPoints
                && c.widthPixels == wanted.widthPixels && c.heightPixels == wanted.heightPixels
            let swapped = c.widthPoints == wanted.heightPoints && c.heightPoints == wanted.widthPoints
                && c.widthPixels == wanted.heightPixels && c.heightPixels == wanted.widthPixels
            return direct || (rotated && swapped)
        }
        if sized.contains(where: { candidates[$0].usable }) { sized = sized.filter { candidates[$0].usable } }
        func delta(_ i: Int) -> Double { abs(candidates[i].mode.refreshHz - wanted.refreshHz) }
        let within = sized.filter { delta($0) <= 0.5 }
        let pool = within.isEmpty ? sized : within
        var best: Int?
        for i in pool where best == nil || delta(i) < delta(best!) { best = i }
        return best
    }

    struct Candidate: Equatable {
        var mode: DisplayMode
        var usable: Bool = true
    }

    /// CoreGraphics reports a 1x1 mode for offline displays; that is "no mode".
    static func normalized(_ mode: DisplayMode, isOnline: Bool) -> DisplayMode? {
        if !isOnline || (mode.widthPoints <= 1 && mode.heightPoints <= 1) || (mode.widthPixels <= 1 && mode.heightPixels <= 1) { return nil }
        return mode
    }

    /// `DisplayProductName` is a dictionary of localized names: en_US, else any (stable order), else a fallback.
    static func productName(_ raw: Any?, fallbackID: UInt32) -> String {
        if let d = raw as? [String: String] {
            if let n = d["en_US"], !n.isEmpty { return n }
            if let k = d.keys.sorted().first(where: { !(d[$0] ?? "").isEmpty }), let n = d[k] { return n }
        }
        return "Display \(fallbackID)"
    }
}
