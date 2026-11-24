import Foundation
@testable import IPadModeCore

enum Fixtures {
    static let legion = DisplayInfo(
        id: DisplayID(raw: 1), uuid: "UUID-LEGION", vendor: 0x30AE, model: 0x68F6, serial: 0,
        location: "dispext0", name: "Legion 34W-2c", kind: .physical,
        isOnline: true, isActive: true, isMain: true,
        origin: Point(x: 0, y: 0),
        mode: DisplayMode(widthPoints: 3440, heightPoints: 1440, widthPixels: 3440, heightPixels: 1440, refreshHz: 240),
        mirrorOf: nil)

    static let p24 = DisplayInfo(
        id: DisplayID(raw: 3), uuid: "UUID-P24", vendor: 0x61A9, model: 0xB016, serial: 0,
        location: "dispext1", name: "P24FBA-RAGL", kind: .physical,
        isOnline: true, isActive: true, isMain: false,
        origin: Point(x: -1920, y: -326),
        mode: DisplayMode(widthPoints: 1920, heightPoints: 1080, widthPixels: 1920, heightPixels: 1080, refreshHz: 100),
        mirrorOf: nil)

    static let virtualRemote = DisplayInfo(
        id: DisplayID(raw: 50), uuid: nil, vendor: 0x1A1D, model: 1, serial: 0,
        location: nil, name: "iPad Remote", kind: .ownVirtual,
        isOnline: true, isActive: true, isMain: false,
        origin: Point(x: 0, y: 0),
        mode: DisplayMode(widthPoints: 1180, heightPoints: 820, widthPixels: 2360, heightPixels: 1640, refreshHz: 60),
        mirrorOf: nil)

    /// `d` as a disabled monitor lists: offline, inactive, not main, and without a mode (B2).
    static func off(_ d: DisplayInfo) -> DisplayInfo {
        var x = d
        x.isOnline = false; x.isActive = false; x.isMain = false; x.mode = nil
        return x
    }

    static func snapshot(_ displays: [DisplayInfo]) -> Snapshot {
        Snapshot(displays: displays, takenAt: Date(timeIntervalSince1970: 0))
    }
}
