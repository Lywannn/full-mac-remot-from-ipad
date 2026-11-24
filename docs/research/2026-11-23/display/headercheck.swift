// Compile/link check of CGVirtualDisplayPrivate.h plus runtime selector checks.
// Instantiates nothing: the API-using function below is never called.
import Foundation
import ObjectiveC

@inline(never)
func neverCalled_typecheckOnly() {
    let d = CGVirtualDisplayDescriptor()
    d.queue = DispatchQueue.main
    d.name = "x"; d.maxPixelsWide = 3304; d.maxPixelsHigh = 2296
    d.sizeInMillimeters = CGSize(width: 227.1, height: 157.8)
    d.vendorID = 1; d.productID = 1; d.serialNumber = 1
    d.terminationHandler = { _, _ in }
    let s = CGVirtualDisplaySettings()
    s.hiDPI = 1
    s.modes = [CGVirtualDisplayMode(width: 1180, height: 820, refreshRate: 60)]
    if let v = CGVirtualDisplay(descriptor: d) { _ = v.apply(s); _ = v.displayID }
    var cfg: CGDisplayConfigRef?
    if let c = cfg { _ = CGSConfigureDisplayEnabled(c, 0, true) }
    _ = CGSGetDisplayList(0, nil, nil)
    _ = CoreDisplay_DisplayCreateInfoDictionary(0)
    cfg = nil
}

let checks: [(String, [String])] = [
    ("CGVirtualDisplayDescriptor", ["setQueue:", "setDispatchQueue:", "setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:",
                                    "setSizeInMillimeters:", "setVendorID:", "setProductID:", "setSerialNumber:", "setSerialNum:",
                                    "setTerminationHandler:"]),
    ("CGVirtualDisplayMode", ["initWithWidth:height:refreshRate:", "width", "height", "refreshRate"]),
    ("CGVirtualDisplaySettings", ["setModes:", "setHiDPI:", "setRotation:"]),
    ("CGVirtualDisplay", ["initWithDescriptor:", "applySettings:", "displayID", "hiDPI", "modes"]),
]
var ok = true
for (cls, sels) in checks {
    guard let c = objc_getClass(cls) as? AnyClass else { print("MISSING class \(cls)"); ok = false; continue }
    for s in sels where class_getInstanceMethod(c, NSSelectorFromString(s)) == nil { print("MISSING \(cls) -\(s)"); ok = false }
}
print(ok ? "all declared selectors present" : "some selectors missing")
if CommandLine.arguments.count > 99 { neverCalled_typecheckOnly() } // never true; keeps the function linked
