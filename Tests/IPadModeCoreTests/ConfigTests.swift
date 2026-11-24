import Foundation
import Testing
@testable import IPadModeCore

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func loadJSON(_ s: String) -> (config: Config, warnings: [String]) {
    let url = tempDir().appendingPathComponent("config.json")
    try! s.write(to: url, atomically: true, encoding: .utf8)
    return ConfigLoader.load(from: url)
}

@Test func defaultsMatchSpec() {
    let c = Config.default
    #expect(c.remote.resolution == "1180x820"); #expect(c.remote.confirmSeconds == 20)
    #expect(c.sidecar.disconnectOnNormal == false); #expect(c.sidecar.autoConnectWhenHeadless == false)
    #expect(c.sidecar.deviceId == nil); #expect(c.sidecar.transport == "auto")
    #expect(c.headlessFallback == true); #expect(c.hotkey == "ctrl+opt+cmd+n")
    #expect(c.watchdog.intervalMs == 500); #expect(c.watchdog.heartbeatStaleSeconds == 5)
}

@Test func partialJSONKeepsOtherDefaults() {
    let r = loadJSON(#"{"remote":{"resolution":"1321x918"}}"#)
    #expect(r.config.remote.resolution == "1321x918")
    #expect(r.config.remote.confirmSeconds == 20)
    #expect(r.config.hotkey == "ctrl+opt+cmd+n")
    #expect(r.warnings.isEmpty)
}

@Test func invalidJSONFallsBackWithOneWarning() {
    let r = loadJSON("{not json")
    #expect(r.config == Config.default)
    #expect(r.warnings.count == 1)
}

@Test func missingFileReturnsDefaultsWithoutWarning() {
    let r = ConfigLoader.load(from: tempDir().appendingPathComponent("nope.json"))
    #expect(r.config == Config.default); #expect(r.warnings.isEmpty)
}

@Test func unknownResolutionFallsBack() {
    let r = loadJSON(#"{"remote":{"resolution":"1920x1080"}}"#)
    #expect(r.config.remote.resolution == "1180x820")
    #expect(r.warnings.count == 1)
}

@Test func negativeConfirmSecondsFallBackWithOneWarning() {
    let remote = loadJSON(#"{"remote":{"confirmSeconds":-5}}"#)
    #expect(remote.config.remote.confirmSeconds == 20)
    #expect(remote.warnings.count == 1)
    let sidecar = loadJSON(#"{"sidecar":{"confirmSeconds":-1}}"#)
    #expect(sidecar.config.sidecar.confirmSeconds == 20)
    #expect(sidecar.warnings.count == 1)
    let zero = loadJSON(#"{"remote":{"confirmSeconds":0},"sidecar":{"confirmSeconds":0}}"#)   // 0: no confirmation
    #expect(zero.config.remote.confirmSeconds == 0 && zero.config.sidecar.confirmSeconds == 0)
    #expect(zero.warnings.isEmpty)
}

@Test func unknownKeysIgnored() {
    let r = loadJSON(#"{"remote":{"graceMinutes":5},"extra":1}"#)
    #expect(r.config == Config.default); #expect(r.warnings.isEmpty)
}

@Test func saveThenLoadRoundTrips() throws {
    let url = tempDir().appendingPathComponent("config.json")
    var c = Config.default
    c.remote.resolution = "1652x1148"; c.sidecar.deviceId = "abc"
    try ConfigLoader.save(c, to: url)
    let r = ConfigLoader.load(from: url)
    #expect(r.config == c); #expect(r.warnings.isEmpty)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("\"deviceId\""))
}

@Test func resolutionParsing() {
    let r = Resolution(parsing: "1534x1066")
    #expect(r?.width == 1534); #expect(r?.height == 1066); #expect(r?.text == "1534x1066")
    #expect(Resolution(parsing: "abc") == nil)
    #expect(Resolution(parsing: "1920x1080") == nil)
    #expect(Resolution.allowed.count == 5)
    #expect(Resolution.defaultRemote.text == "1180x820")
}

@Test func messagesExactSamples() {
    #expect(Messages.confirmBody(20) == "Kembali otomatis dalam 20 detik.")
    #expect(Messages.resolutionSet(.defaultRemote) == "Resolusi diganti ke 1180x820.")
    #expect(Messages.flapping("X") == "Monitor X terus menyala sendiri — dibiarkan menyala.")
    #expect(Messages.remoteEntered(seconds: 20) == "Mode Remote iPad aktif — konfirmasi di layar dalam 20 detik.")
    #expect(Messages.remoteEntered(seconds: 120) == "Mode Remote iPad aktif — konfirmasi di layar dalam 120 detik.")
    #expect(Messages.remoteEntered(seconds: 0) == "Mode Remote iPad aktif.")
    #expect(Messages.noPhysicalMonitor == "Tidak ada monitor fisik yang tersambung — layar iPad tetap dipakai.")
    #expect(Messages.enterFailed == "Gagal masuk mode Remote — Mac tetap Normal. Lihat `ipadmode logs`.")
    #expect(Messages.exitFailed
            == "Gagal menyalakan monitor — layar iPad tetap dipakai. Coba Layar Normal lagi atau tekan ⌃⌥⌘N.")
}

@Test func pathsDeriveNames() {
    let s = URL(fileURLWithPath: "/tmp/s"), l = URL(fileURLWithPath: "/tmp/l")
    let p = Paths(support: s, logs: l)
    #expect(p.config.path == "/tmp/s/config.json"); #expect(p.socket.lastPathComponent == "ipadmode.sock")
    #expect(p.watchdogHeartbeat.lastPathComponent == "watchdog-heartbeat.json")
    #expect(p.disabledMarker.lastPathComponent == "disabled"); #expect(p.logs == l)
    #expect(Paths.standard.support.path.hasSuffix("Library/Application Support/ipadmode"))
}

@Test func watchdogTimingIsClamped() {
    let r = loadJSON(#"{"watchdog":{"intervalMs":5,"heartbeatStaleSeconds":1}}"#)
    #expect(r.config.watchdog.intervalMs == 50); #expect(r.config.watchdog.heartbeatStaleSeconds == 3)
    #expect(r.warnings.count == 2)
    let hi = loadJSON(#"{"watchdog":{"intervalMs":60000}}"#)
    #expect(hi.config.watchdog.intervalMs == 5000); #expect(hi.warnings.count == 1)
    let ok = loadJSON(#"{"watchdog":{"intervalMs":50,"heartbeatStaleSeconds":3}}"#)
    #expect(ok.warnings.isEmpty)
    #expect(loadJSON("{}").warnings.isEmpty)
}

@Test func remoteModeIsHiDPIAtSixtyHertz() throws {
    // A-3: the mode the child selects and the Coordinator keeps.
    let r = try #require(Resolution(parsing: "1321x918"))
    let mode = r.remoteMode
    #expect(mode == DisplayMode(widthPoints: 1321, heightPoints: 918, widthPixels: 2642, heightPixels: 1836, refreshHz: 60))
    var close = mode
    close.refreshHz = 59.94
    #expect(close.isSameMode(as: mode))
    var other = mode
    other.widthPixels = 1321; other.heightPixels = 918   // 1x
    #expect(!other.isSameMode(as: mode))
    #expect(!Resolution.defaultRemote.remoteMode.isSameMode(as: mode))
}
