// Read-only display queries. Changes nothing. Prints no serials/UUID values.
import Foundation
import CoreGraphics
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

typealias InfoDictFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
let infoFn = dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary").map { unsafeBitCast($0, to: InfoDictFn.self) }

func list(_ online: Bool) -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    let err = online ? CGGetOnlineDisplayList(16, &ids, &n) : CGGetActiveDisplayList(16, &ids, &n)
    return err == .success ? Array(ids.prefix(Int(n))) : []
}
let online = list(true), active = list(false)
print("online=\(online.count) active=\(active.count) main=\(CGMainDisplayID())")

let sensitive = ["serial", "uuid", "edid", "name", "productname", "alphanumeric", "week", "year"]
for d in online {
    let mode = CGDisplayCopyDisplayMode(d)
    print("\n### display \(d)")
    print("  main=\(CGDisplayIsMain(d) != 0) builtin=\(CGDisplayIsBuiltin(d) != 0) active=\(CGDisplayIsActive(d) != 0) online=\(CGDisplayIsOnline(d) != 0) asleep=\(CGDisplayIsAsleep(d) != 0) inMirrorSet=\(CGDisplayIsInMirrorSet(d) != 0) mirrorsDisplay=\(CGDisplayMirrorsDisplay(d))")
    print(String(format: "  vendor=0x%x model=0x%x serialNonZero=%@ uuidPresent=%@", CGDisplayVendorNumber(d), CGDisplayModelNumber(d),
                 (CGDisplaySerialNumber(d) != 0 ? "yes" : "no") as NSString,
                 (CGDisplayCreateUUIDFromDisplayID(d) != nil ? "yes" : "no") as NSString))
    if let m = mode {
        print("  mode: \(m.width)x\(m.height) pt, \(m.pixelWidth)x\(m.pixelHeight) px, \(m.refreshRate) Hz, ioModeID=\(m.ioDisplayModeID)")
    }
    let b = CGDisplayBounds(d); print("  bounds=\(b)")
    if let infoFn, let dict = infoFn(d)?.takeRetainedValue() as? [String: Any] {
        print("  CoreDisplay info keys (\(dict.count)):")
        for k in dict.keys.sorted() {
            let v = dict[k]!
            let low = k.lowercased()
            if sensitive.contains(where: { low.contains($0) }) { print("    \(k) = <redacted>") ; continue }
            var s = "\(v)".replacingOccurrences(of: "\n", with: " ")
            if s.count > 90 { s = String(s.prefix(90)) + "…" }
            print("    \(k) = \(s)")
        }
    } else { print("  CoreDisplay info: unavailable") }
}

print("\n### NSScreen")
for s in NSScreen.screens {
    let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    print("  screen id=\(num) frame=\(s.frame) backingScale=\(s.backingScaleFactor) maxFPS=\(s.maximumFramesPerSecond) deviceDescKeys=\(s.deviceDescription.keys.map{$0.rawValue}.sorted())")
}
