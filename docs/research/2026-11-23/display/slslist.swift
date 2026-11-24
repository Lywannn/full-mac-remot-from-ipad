// Read-only: compare symbol addresses and call SLSGetDisplayList (a pure query).
import Foundation
import CoreGraphics

let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let a = dlsym(h, "SLSConfigureDisplayEnabled"), b = dlsym(h, "CGSConfigureDisplayEnabled")
let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
let c = dlsym(cg, "CGSConfigureDisplayEnabled")
print("SLSConfigureDisplayEnabled=\(String(describing: a)) CGSConfigureDisplayEnabled(SkyLight)=\(String(describing: b)) CGSConfigureDisplayEnabled(via CG)=\(String(describing: c)) same=\(a == b && b == c)")

typealias ListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
for name in ["SLSGetDisplayList", "SLSGetOnlineDisplayList", "SLSGetActiveDisplayList"] {
    guard let p = dlsym(h, name) else { print("\(name): missing"); continue }
    let f = unsafeBitCast(p, to: ListFn.self)
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    let err = f(16, &ids, &n)
    print("\(name) -> err=\(err.rawValue) count=\(n) ids=\(Array(ids.prefix(Int(n))))")
}
var pub = [CGDirectDisplayID](repeating: 0, count: 16); var pn: UInt32 = 0
_ = CGGetOnlineDisplayList(16, &pub, &pn)
print("CGGetOnlineDisplayList count=\(pn) ids=\(Array(pub.prefix(Int(pn))))")
