public struct RestorePlan: Equatable, Sendable {
    public var enable: [DisplayID]
    public var origins: [DisplayID: Point]
    public var modes: [DisplayID: DisplayMode]
    public var main: DisplayID?
    public var unmatched: [String]

    public init(enable: [DisplayID] = [], origins: [DisplayID: Point] = [:],
                modes: [DisplayID: DisplayMode] = [:], main: DisplayID? = nil, unmatched: [String] = []) {
        self.enable = enable; self.origins = origins; self.modes = modes
        self.main = main; self.unmatched = unmatched
    }
}

public enum RestorePlanner {
    public static func plan(baseline: Snapshot, current: [DisplayInfo]) -> RestorePlan {
        let base = baseline.displays.filter { $0.kind == .physical }
        let cur = current.filter { $0.kind == .physical }

        // match[baselineIndex] = index into cur
        var match: [Int: Int] = [:]
        var taken = Set<Int>()

        func pass(_ rule: (DisplayInfo, DisplayInfo) -> Bool, uniqueOnly: Bool = false) {
            for (bi, b) in base.enumerated() where match[bi] == nil {
                let candidates = cur.indices.filter { !taken.contains($0) && rule(b, cur[$0]) }
                guard let ci = candidates.first, !uniqueOnly || candidates.count == 1 else { continue }
                match[bi] = ci
                taken.insert(ci)
            }
        }
        pass { b, c in b.uuid != nil && b.uuid == c.uuid }
        pass { b, c in b.location != nil && b.vendor == c.vendor && b.model == c.model && b.location == c.location }
        // Unique on both sides: exactly one unmatched baseline and one unmatched current share the pair,
        // so identical monitors without location are never guessed.
        pass({ b, c in
            guard b.vendor == c.vendor, b.model == c.model else { return false }
            let sameBase = base.indices.filter { match[$0] == nil && base[$0].vendor == b.vendor && base[$0].model == b.model }
            return sameBase.count == 1
        }, uniqueOnly: true)

        var plan = RestorePlan()
        var matchedCurrent: [Int] = []
        for (bi, b) in base.enumerated() {
            guard let ci = match[bi] else {
                plan.unmatched.append(b.name)
                continue
            }
            let id = cur[ci].id
            matchedCurrent.append(ci)
            // An offline baseline entry has no layout position: CGDisplayBounds of a disabled display is meaningless.
            if b.isOnline {
                plan.origins[id] = b.origin
                if let mode = b.mode { plan.modes[id] = mode }
            }
            if b.isMain { plan.main = id }
        }
        for ci in matchedCurrent where !cur[ci].isOnline { plan.enable.append(cur[ci].id) }
        for ci in cur.indices where !taken.contains(ci) && !cur[ci].isOnline { plan.enable.append(cur[ci].id) }
        return plan
    }
}
