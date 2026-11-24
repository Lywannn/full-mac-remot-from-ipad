import Foundation
import CoreGraphics
import ColorSync
import CPrivateDisplay
import IPadModeCore

public enum DisplayBackendError: Error, Equatable {
    case begin
    case configure(DisplayID, CGError)
    case complete(CGError)
    case modeNotFound(DisplayID)
    case privateAPIUnavailable
    case listFailed(CGError)
}

/// What the logs and `lastError` show: the raw CoreGraphics code, e.g. `complete(CGError 1001)`, where the default
/// description prints only `complete(__C.CGError)` (A-2).
extension DisplayBackendError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .begin: "begin"
        case .configure(let id, let error): "configure(\(id.raw), CGError \(error.rawValue))"
        case .complete(let error): "complete(CGError \(error.rawValue))"
        case .modeNotFound(let id): "modeNotFound(\(id.raw))"
        case .privateAPIUnavailable: "privateAPIUnavailable"
        case .listFailed(let error): "listFailed(CGError \(error.rawValue))"
        }
    }
}

@MainActor public final class CGDisplayBackend: DisplayBackend {
    public init() {}

    public func listDisplays() throws -> [DisplayInfo] {
        var all = [CGDirectDisplayID](repeating: 0, count: 64)
        let n = Int(IPMCopyAllDisplayIDs(&all, 64))
        var ids = Array(all.prefix(n))
        let online = try Self.idList(CGGetOnlineDisplayList)
        let active = Set(try Self.idList(CGGetActiveDisplayList))
        // Online displays the private list somehow missed must still be reported.
        for d in online where !ids.contains(d) { ids.append(d) }
        let onlineSet = Set(online)
        let main = CGMainDisplayID()
        return ids.map { id in
            let isOnline = onlineSet.contains(id)
            // B1: a sleeping display reads inactive but is still part of the layout.
            let isActive = isOnline && (active.contains(id) || CGDisplayIsAsleep(id) != 0)
            let info = IPMCopyDisplayInfo(id)?.takeRetainedValue() as? [String: Any]
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
            let isVirtual = (info?["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue ?? false
            let isAirPlay = (info?["kCGDisplayIsAirPlay"] as? NSNumber)?.boolValue ?? false
            let bounds = CGDisplayBounds(id)
            let mirror = CGDisplayMirrorsDisplay(id)
            return DisplayInfo(
                id: DisplayID(raw: id), uuid: Self.uuid(id), vendor: vendor, model: model,
                serial: CGDisplaySerialNumber(id), location: info?["IODisplayLocation"] as? String,
                name: DisplayModeMatcher.productName(info?["DisplayProductName"], fallbackID: id),
                kind: DisplayClassifier.classify(vendor: vendor, product: model, isVirtual: isVirtual, isAirPlay: isAirPlay),
                isOnline: isOnline, isActive: isActive, isMain: id == main,
                origin: Point(x: Self.int32(bounds.origin.x), y: Self.int32(bounds.origin.y)),
                mode: CGDisplayCopyDisplayMode(id).flatMap { DisplayModeMatcher.normalized(Self.describe($0), isOnline: isOnline) },
                mirrorOf: mirror == kCGNullDirectDisplay ? nil : DisplayID(raw: mirror))
        }
    }

    public func setEnabled(_ ids: [DisplayID], enabled: Bool, scope: ConfigScope) throws {
        guard !ids.isEmpty else { return }
        try transaction(scope) { cfg in
            for id in ids {
                let e = IPMConfigureDisplayEnabled(cfg, id.raw, enabled)
                if e == .notImplemented { throw DisplayBackendError.privateAPIUnavailable }
                if e != .success { throw DisplayBackendError.configure(id, e) }
            }
        }
    }

    public func setOrigins(_ origins: [DisplayID: Point], scope: ConfigScope) throws {
        guard !origins.isEmpty else { return }
        try transaction(scope) { cfg in
            for (id, p) in origins.sorted(by: { $0.key.raw < $1.key.raw }) {
                let e = CGConfigureDisplayOrigin(cfg, id.raw, p.x, p.y)
                if e != .success { throw DisplayBackendError.configure(id, e) }
            }
        }
    }

    public func setMode(_ id: DisplayID, _ mode: DisplayMode, scope: ConfigScope) throws {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id.raw, opts) as? [CGDisplayMode]) ?? []
        guard let i = DisplayModeMatcher.bestMatch(mode, in: modes.map { Self.candidate($0) }, rotation: CGDisplayRotation(id.raw)) else {
            throw DisplayBackendError.modeNotFound(id)
        }
        try transaction(scope) { cfg in
            let e = CGConfigureDisplayWithDisplayMode(cfg, id.raw, modes[i], nil)
            if e != .success { throw DisplayBackendError.configure(id, e) }
        }
    }

    // MARK: - Helpers

    /// One configuration: begin, body, complete. Any failure cancels so nothing is left open.
    private func transaction(_ scope: ConfigScope, _ body: (CGDisplayConfigRef) throws -> Void) throws {
        var ref: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&ref) == .success, let cfg = ref else { throw DisplayBackendError.begin }
        do { try body(cfg) } catch { CGCancelDisplayConfiguration(cfg); throw error }
        let e = CGCompleteDisplayConfiguration(cfg, scope == .appOnly ? .forAppOnly : .forSession)
        if e != .success { throw DisplayBackendError.complete(e) }
    }

    private static func idList(_ f: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) throws -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64); var n: UInt32 = 0
        let e = f(64, &ids, &n)
        if e != .success { throw DisplayBackendError.listFailed(e) }
        return Array(ids.prefix(Int(n)))
    }

    private static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }

    private static func int32(_ v: CGFloat) -> Int32 { Int32(max(Double(Int32.min), min(Double(Int32.max), Double(v).rounded()))) }

    private static func candidate(_ m: CGDisplayMode) -> DisplayModeMatcher.Candidate {
        .init(mode: describe(m), usable: m.isUsableForDesktopGUI())
    }

    /// Also used by the `vdisplay` child to read its own display's modes.
    static func describe(_ m: CGDisplayMode) -> DisplayMode {
        DisplayMode(widthPoints: m.width, heightPoints: m.height, widthPixels: m.pixelWidth, heightPixels: m.pixelHeight, refreshHz: m.refreshRate)
    }
}
