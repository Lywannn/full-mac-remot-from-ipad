// Read-only introspection of private display APIs.
// Does NOT instantiate any class, does NOT call any configuration function.
import Foundation
import ObjectiveC
import CoreGraphics

let frameworks = [
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
    "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
]
var handles: [String: UnsafeMutableRawPointer] = [:]
for f in frameworks {
    if let h = dlopen(f, RTLD_LAZY) { handles[f] = h; print("dlopen OK   \(f)") }
    else { print("dlopen FAIL \(f): \(String(cString: dlerror()))") }
}

let symbols = [
    "CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled",
    "CGSCompleteDisplayConfiguration", "SLSCompleteDisplayConfiguration",
    "SLSCompleteDisplayConfigurationWithOption",
    "CGSBeginDisplayConfiguration", "SLSBeginDisplayConfiguration",
    "SLSConfigureDisplayMirrored", "SLSConfigureDisplayIndependentOutput",
    "CGSGetDisplayList", "SLSGetDisplayList", "SLSGetOnlineDisplayList",
    "CoreDisplay_DisplayCreateInfoDictionary",
    "CGVirtualDisplaySettingsRefreshDeadlineNone",
    "CGSDisplayIsVirtual", "SLSDisplayIsVirtual", "SLSIsDisplayVirtual",
    "CGSMainConnectionID", "SLSMainConnectionID",
]
for s in symbols {
    let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), s) // RTLD_DEFAULT
    var info = Dl_info()
    var img = "-"
    if let p, dladdr(p, &info) != 0, let fname = info.dli_fname { img = String(cString: fname) }
    print(String(format: "dlsym %-45@ %@  %@", s as NSString, (p == nil ? "MISSING" : "FOUND") as NSString, img as NSString))
}

// Read the data constant (no side effects).
if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGVirtualDisplaySettingsRefreshDeadlineNone") {
    let raw = p.load(as: UInt64.self)
    let dbl = p.load(as: Double.self)
    print("CGVirtualDisplaySettingsRefreshDeadlineNone raw=0x\(String(raw, radix: 16)) asDouble=\(dbl)")
}

func dump(_ name: String) {
    guard let cls: AnyClass = objc_getClass(name) as? AnyClass else { print("\n## \(name): NOT FOUND"); return }
    let img = class_getImageName(cls).map { String(cString: $0) } ?? "?"
    let sup = class_getSuperclass(cls).map { NSStringFromClass($0) } ?? "nil"
    print("\n## \(name) : \(sup)   [image: \(img)]")
    var n: UInt32 = 0
    if let protos = class_copyProtocolList(cls, &n) {
        let names = (0..<Int(n)).map { String(cString: protocol_getName(protos[$0])) }
        print("  protocols: \(names.joined(separator: ", "))"); free(UnsafeMutableRawPointer(protos))
    }
    if let props = class_copyPropertyList(cls, &n) {
        for i in 0..<Int(n) {
            let p = props[i]
            print("  @property \(String(cString: property_getName(p)))  [\(String(cString: property_getAttributes(p)!))]")
        }
        free(props)
    }
    if let ivars = class_copyIvarList(cls, &n) {
        for i in 0..<Int(n) {
            let iv = ivars[i]
            let nm = ivar_getName(iv).map { String(cString: $0) } ?? "?"
            let ty = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? "?"
            print("  ivar \(nm) \(ty)")
        }
        free(ivars)
    }
    for (label, c) in [("-", cls), ("+", object_getClass(cls)!)] {
        if let ms = class_copyMethodList(c, &n) {
            let lines = (0..<Int(n)).map { i -> String in
                let m = ms[i]
                let sel = NSStringFromSelector(method_getName(m))
                let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
                return "  \(label)\(sel)  \(enc)"
            }.sorted()
            lines.forEach { print($0) }
            free(ms)
        }
    }
}

// Find classes by image (C strings only; avoids messaging odd root classes).
setvbuf(stdout, nil, _IONBF, 0)
var found: [String] = []
for img in ["/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"] {
    var count: UInt32 = 0
    if let names = objc_copyClassNamesForImage(img, &count) {
        let all = (0..<Int(count)).map { String(cString: names[$0]) }
        print("\nimage \(img): \(count) classes")
        let hits = all.filter { $0.contains("VirtualDisplay") || $0.contains("Sidecar") }
        print("  VirtualDisplay/Sidecar classes: \(hits.sorted())")
        found += hits.filter { $0.contains("VirtualDisplay") }
        free(UnsafeMutableRawPointer(mutating: names))
    } else { print("image \(img): objc_copyClassNamesForImage returned nil") }
}
for c in found.sorted() { dump(c) }
