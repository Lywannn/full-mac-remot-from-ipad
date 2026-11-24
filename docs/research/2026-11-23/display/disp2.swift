// Read-only inspection of a display ID that SLSGetDisplayList reports but CG online list does not.
import Foundation
import CoreGraphics
import ColorSync
setvbuf(stdout, nil, _IONBF, 0)
typealias InfoDictFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
let infoFn = unsafeBitCast(dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary")!, to: InfoDictFn.self)
let d = CGDirectDisplayID(CommandLine.arguments.count > 1 ? UInt32(CommandLine.arguments[1])! : 2)
print("id=\(d) online=\(CGDisplayIsOnline(d)) active=\(CGDisplayIsActive(d)) builtin=\(CGDisplayIsBuiltin(d)) asleep=\(CGDisplayIsAsleep(d)) vendor=0x\(String(CGDisplayVendorNumber(d), radix:16)) model=0x\(String(CGDisplayModelNumber(d), radix:16)) serialNonZero=\(CGDisplaySerialNumber(d) != 0) uuidPresent=\(CGDisplayCreateUUIDFromDisplayID(d) != nil) unit=\(CGDisplayUnitNumber(d)) bounds=\(CGDisplayBounds(d)) pixels=\(CGDisplayPixelsWide(d))x\(CGDisplayPixelsHigh(d))")
let sensitive = ["serial", "uuid", "edid", "name", "week", "year", "cadevice"]
if let dict = infoFn(d)?.takeRetainedValue() as? [String: Any] {
    for k in dict.keys.sorted() {
        let low = k.lowercased()
        if sensitive.contains(where: { low.contains($0) }) { print("  \(k) = <redacted>"); continue }
        var s = "\(dict[k]!)".replacingOccurrences(of: "\n", with: " "); if s.count > 120 { s = String(s.prefix(120)) + "…" }
        print("  \(k) = \(s)")
    }
} else { print("  no CoreDisplay info dictionary") }
