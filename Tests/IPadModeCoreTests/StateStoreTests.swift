import Foundation
import Testing
@testable import IPadModeCore

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func sampleState() -> PersistedState {
    var s = PersistedState.initial
    s.phase = .active(.remote)
    s.target = DisplayID(raw: 12345)
    s.virtualPID = 99
    s.cleanShutdown = false
    s.uncleanStarts = [Date(timeIntervalSince1970: 1000)]
    s.lastError = "x"
    s.updatedAt = Date(timeIntervalSince1970: 2000)
    let d = DisplayInfo(id: DisplayID(raw: 1), uuid: "U", vendor: 1, model: 2, serial: 3, location: nil,
                        name: "Mac", kind: .physical, isOnline: true, isActive: true, isMain: true,
                        origin: Point(x: 0, y: 0),
                        mode: DisplayMode(widthPoints: 1, heightPoints: 2, widthPixels: 3, heightPixels: 4, refreshHz: 60),
                        mirrorOf: nil)
    s.baseline = Snapshot(displays: [d], takenAt: Date(timeIntervalSince1970: 3000))
    return s
}

@Test func initialStateValues() {
    let s = PersistedState.initial
    #expect(s.phase == .normal); #expect(s.cleanShutdown); #expect(s.lastError == nil)
    #expect(s.updatedAt == Date(timeIntervalSince1970: 0)); #expect(s.uncleanStarts.isEmpty)
}

@Test func saveLoadRoundTrip() throws {
    let store = FileStateStore(url: tempDir().appendingPathComponent("state.json"))
    let s = sampleState()
    try store.save(s)
    #expect(store.load() == s)
}

@Test func loadMissingReturnsNil() {
    #expect(FileStateStore(url: tempDir().appendingPathComponent("state.json")).load() == nil)
}

@Test func loadCorruptStateReturnsNil() throws {
    let url = tempDir().appendingPathComponent("state.json")
    let store = FileStateStore(url: url)
    try store.save(sampleState())
    let data = try Data(contentsOf: url).prefix(10)
    try Data(data).write(to: url)
    #expect(store.load() == nil)
}

@Test func saveLeavesNoTempFilesAndMode0600() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("state.json")
    let store = FileStateStore(url: url)
    try store.save(sampleState()); try store.save(sampleState())
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix("._") }
    #expect(names == ["state.json"])
    let perm = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perm == 0o600)
}

@Test func memoryStoreRecordsSaves() throws {
    let m = MemoryStateStore(nil)
    #expect(m.load() == nil)
    try m.save(.initial)
    #expect(m.saves.count == 1); #expect(m.load() == .initial)
}

@Test func failedRenameThrowsAndLeavesNoTempFile() throws {
    // B-4: the rename fails after the temp file is closed (a directory holds the name). The write throws, the temp
    // file goes, and the fd is closed once only: by code, since a second close is not visible from one thread.
    let dir = tempDir()
    let url = dir.appendingPathComponent("state.json")
    try FileManager.default.createDirectory(at: url.appendingPathComponent("inside"), withIntermediateDirectories: true)
    let store = FileStateStore(url: url)
    #expect(throws: (any Error).self) { try store.save(sampleState()) }
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
}
