// Throwaway diagnostic tool for display experiments. `list` is read-only; every other
// subcommand changes the display configuration. Scope is only app/session, never permanent.
import Foundation
import CoreGraphics
import CPrivateDisplay

setvbuf(stdout, nil, _IONBF, 0)

let usage = """
usage: ipadmode-spike <command> [options]
  list
  vdisplay --points WxH [--hold S]
  disable <id...> --scope app|session [--hold S] [--crash]
  enable-all --scope session
  main <id> --scope app|session
  remote-sim --points WxH --scope app|session --hold S
  safetynet --after S
"""

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

// MARK: helpers

let vendorVirtual: UInt32 = 0x1A1D
let modePoints: [(UInt32, UInt32)] = [(1180, 820), (1321, 918), (1416, 984), (1534, 1066), (1652, 1148)]

func opt(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func scope(_ args: [String], default d: CGConfigureOption? = nil) -> CGConfigureOption {
    switch opt(args, "--scope") {
    case "app": return .forAppOnly
    case "session": return .forSession
    case nil: if let d { return d }; die("--scope app|session required")
    default: die("--scope must be app or session")
    }
}
func parsePoints(_ s: String?) -> (UInt32, UInt32) {
    guard let s, let p = modePoints.first(where: { "\($0.0)x\($0.1)" == s }) else {
        die("--points must be one of: " + modePoints.map { "\($0.0)x\($0.1)" }.joined(separator: ", "))
    }
    return p
}
func hold(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

func isVirtual(_ d: CGDirectDisplayID) -> Bool {
    if let info = IPMCopyDisplayInfo(d)?.takeRetainedValue() as? [String: Any],
       let v = info["kCGDisplayIsVirtualDevice"] as? NSNumber, v.boolValue { return true }
    return CGDisplayVendorNumber(d) == vendorVirtual
}
func onlineIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32); var n: UInt32 = 0
    return CGGetOnlineDisplayList(32, &ids, &n) == .success ? Array(ids.prefix(Int(n))) : []
}
func allIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    let n = IPMCopyAllDisplayIDs(&ids, 32)
    return Array(ids.prefix(Int(n)))
}
/// Physical displays that exist but are not online (software-disabled).
func disconnectedPhysical() -> [CGDirectDisplayID] {
    let on = Set(onlineIDs())
    return allIDs().filter { !on.contains($0) && !isVirtual($0) }
}

@discardableResult
func configure(_ option: CGConfigureOption, _ body: (CGDisplayConfigRef) -> CGError) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { print("begin failed"); return false }
    let e = body(c)
    if e != .success { print("configure step failed err=\(e.rawValue)"); CGCancelDisplayConfiguration(c); return false }
    let r = CGCompleteDisplayConfiguration(c, option)
    print("complete err=\(r.rawValue)")
    return r == .success
}
func setEnabled(_ ids: [CGDirectDisplayID], _ enabled: Bool, _ option: CGConfigureOption) -> Bool {
    configure(option) { c in
        for d in ids {
            let e = IPMConfigureDisplayEnabled(c, d, enabled)
            if e != .success { print("enable(\(d), \(enabled)) err=\(e.rawValue)"); return e }
        }
        return .success
    }
}
/// Make `target` the main display: origin (0,0); the others are laid out to its right.
func makeMain(_ target: CGDirectDisplayID, _ option: CGConfigureOption) -> Bool {
    configure(option) { c in
        let e = CGConfigureDisplayOrigin(c, target, 0, 0)
        if e != .success { return e }
        var x = Int32(CGDisplayBounds(target).width)
        for d in onlineIDs() where d != target {
            let e2 = CGConfigureDisplayOrigin(c, d, x, 0)
            if e2 != .success { return e2 }
            x += Int32(CGDisplayBounds(d).width)
        }
        return .success
    }
}

func createRemote(points: (UInt32, UInt32)) -> (handle: UnsafeMutableRawPointer, id: CGDirectDisplayID)? {
    // Requested size first, so it is the default; the remaining modes follow.
    let ordered = [points] + modePoints.filter { $0 != points }
    var specs = ordered.map { IPMModeSpec(widthPoints: $0.0, heightPoints: $0.1, refreshHz: 60) }
    var id: CGDirectDisplayID = 0
    guard let h = IPMVirtualDisplayCreate("iPad Remote", 0x1A1D, 0x0001, 0x1A1D0001, 227, 158, 3304, 2296, true,
                                          &specs, Int32(specs.count), &id) else { return nil }
    return (h, id)
}

// MARK: commands

func cmdList() {
    let on = Set(onlineIDs()); let main = CGMainDisplayID()
    let s = IPMGetPrivateAPIStatus()
    print("private API: virtualDisplay=\(s.virtualDisplay) configureEnabled=\(s.configureEnabled) displayList=\(s.displayList) displayInfo=\(s.displayInfo)")
    for d in allIDs() {
        print(String(format: "display %u vendor=0x%x model=0x%x online=%@ active=%@ main=%@ virtual=%@", d,
                     CGDisplayVendorNumber(d), CGDisplayModelNumber(d),
                     "\(on.contains(d))", "\(CGDisplayIsActive(d) != 0)", "\(d == main)", "\(isVirtual(d))"))
        if let m = CGDisplayCopyDisplayMode(d) {
            print("  mode \(m.width)x\(m.height) pt, \(m.pixelWidth)x\(m.pixelHeight) px, \(m.refreshRate) Hz")
        }
    }
}

func cmdVDisplay(_ a: [String]) {
    let pts = parsePoints(opt(a, "--points"))
    guard let (h, id) = createRemote(points: pts) else { die("virtual display creation failed") }
    print("READY \(id)")
    hold(Double(opt(a, "--hold") ?? "30") ?? 30)
    IPMVirtualDisplayRelease(h)
}

func cmdDisable(_ a: [String]) {
    let opts = scope(a)
    var ids: [CGDirectDisplayID] = []
    var i = 0
    while i < a.count {
        if a[i].hasPrefix("--") { i += (a[i] == "--crash" ? 1 : 2); continue }
        if let v = UInt32(a[i]) { ids.append(v) }
        i += 1
    }
    guard !ids.isEmpty else { die("disable needs display ids") }
    let ok = setEnabled(ids, false, opts)
    print("disable ok=\(ok)")
    if a.contains("--crash") { abort() }
    hold(Double(opt(a, "--hold") ?? "0") ?? 0)
}

func cmdEnableAll(_ a: [String]) {
    // Only session scope: an app-only restore would revert when this process exits.
    guard opt(a, "--scope") == "session" else { die("enable-all requires --scope session") }
    let off = disconnectedPhysical()
    print("disabled physical: \(off)")
    guard !off.isEmpty else { return }
    print("enable ok=\(setEnabled(off, true, .forSession))")
}

func cmdMain(_ a: [String]) {
    guard let s = a.first, let id = UInt32(s) else { die("main <id> --scope app|session") }
    print("main ok=\(makeMain(id, scope(a)))")
}

func cmdRemoteSim(_ a: [String]) {
    let opts = scope(a)
    let pts = parsePoints(opt(a, "--points"))
    guard let secs = Double(opt(a, "--hold") ?? "") else { die("--hold S required") }
    guard let (h, id) = createRemote(points: pts) else { die("virtual display creation failed") }
    print("READY \(id)")
    // Invariant: physical monitors are disabled only once the virtual display is online, active and main.
    func abortSim(_ why: String) -> Never {
        print("ABORT: \(why); nothing disabled")
        IPMVirtualDisplayRelease(h)
        exit(1)
    }
    let deadline = Date(timeIntervalSinceNow: 5)
    while !(onlineIDs().contains(id) && CGDisplayIsActive(id) != 0) {
        if Date() > deadline { abortSim("virtual display not online+active within 5s") }
        hold(0.2)
    }
    guard makeMain(id, opts) else { abortSim("makeMain failed") }
    hold(1)
    guard CGMainDisplayID() == id else { abortSim("virtual display is not main") }
    let physical = onlineIDs().filter { !isVirtual($0) }
    print("disabling physical \(physical): ok=\(setEnabled(physical, false, opts))")
    hold(secs)
    IPMVirtualDisplayRelease(h)
}

func cmdSafetynet(_ a: [String]) {
    guard let secs = Double(opt(a, "--after") ?? "") else { die("--after S required") }
    setvbuf(stdout, nil, _IOLBF, 0)   // keep the log even if this process is killed
    hold(secs)
    let opts = CGConfigureOption.forSession   // never app-only: it would revert at exit
    let off = disconnectedPhysical()
    print("disabled physical: \(off)")
    if !off.isEmpty { print("enable ok=\(setEnabled(off, true, opts))") }
    hold(1)
    // Re-lay out only when no physical monitor is main: makeMain lines every display up to the right of the
    // target, which would move a correctly placed monitor when nothing went wrong.
    let main = CGMainDisplayID()
    if isVirtual(main) || !onlineIDs().contains(main) {
        if let first = onlineIDs().first(where: { !isVirtual($0) }) {
            print("main ok=\(makeMain(first, opts))")
        }
    } else {
        print("main unchanged: \(main)")
    }
    cmdList()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { die(usage) }
let rest = Array(args.dropFirst())
switch cmd {
case "list": cmdList()
case "vdisplay": cmdVDisplay(rest)
case "disable": cmdDisable(rest)
case "enable-all": cmdEnableAll(rest)
case "main": cmdMain(rest)
case "remote-sim": cmdRemoteSim(rest)
case "safetynet": cmdSafetynet(rest)
default: die(usage)
}
