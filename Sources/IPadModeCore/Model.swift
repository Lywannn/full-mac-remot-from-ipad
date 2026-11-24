import Foundation

public struct DisplayID: Hashable, Codable, Sendable {
    public var raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

public enum DisplayKind: String, Codable, Sendable { case physical, sidecar, ownVirtual, otherVirtual }

public struct Point: Hashable, Codable, Sendable {
    public var x: Int32
    public var y: Int32
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }
}

public struct DisplayMode: Hashable, Codable, Sendable {
    public var widthPoints: Int, heightPoints: Int, widthPixels: Int, heightPixels: Int
    public var refreshHz: Double
    public init(widthPoints: Int, heightPoints: Int, widthPixels: Int, heightPixels: Int, refreshHz: Double) {
        self.widthPoints = widthPoints; self.heightPoints = heightPoints
        self.widthPixels = widthPixels; self.heightPixels = heightPixels
        self.refreshHz = refreshHz
    }

    /// The same size in points and in pixels, at a refresh within 0.5 Hz of `other`'s.
    public func isSameMode(as other: DisplayMode) -> Bool {
        widthPoints == other.widthPoints && heightPoints == other.heightPoints
            && widthPixels == other.widthPixels && heightPixels == other.heightPixels
            && abs(refreshHz - other.refreshHz) <= 0.5
    }
}

public struct DisplayInfo: Hashable, Codable, Sendable {
    public var id: DisplayID
    public var uuid: String?
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var location: String?
    public var name: String
    public var kind: DisplayKind
    public var isOnline: Bool
    public var isActive: Bool
    public var isMain: Bool
    public var origin: Point
    public var mode: DisplayMode?
    public var mirrorOf: DisplayID?

    public init(id: DisplayID, uuid: String?, vendor: UInt32, model: UInt32, serial: UInt32,
                location: String?, name: String, kind: DisplayKind,
                isOnline: Bool, isActive: Bool, isMain: Bool,
                origin: Point, mode: DisplayMode?, mirrorOf: DisplayID?) {
        self.id = id; self.uuid = uuid; self.vendor = vendor; self.model = model; self.serial = serial
        self.location = location; self.name = name; self.kind = kind
        self.isOnline = isOnline; self.isActive = isActive; self.isMain = isMain
        self.origin = origin; self.mode = mode; self.mirrorOf = mirrorOf
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var displays: [DisplayInfo]
    public var takenAt: Date
    public init(displays: [DisplayInfo], takenAt: Date) { self.displays = displays; self.takenAt = takenAt }
}

public enum Mode: String, Codable, Sendable { case remote, sidecar }

public enum Phase: Codable, Equatable, Sendable {
    case normal, entering(Mode), confirming(Mode), active(Mode), exiting
}

public struct PersistedState: Codable, Equatable, Sendable {
    public var phase: Phase
    public var baseline: Snapshot?
    public var target: DisplayID?
    public var virtualPID: Int32?
    public var cleanShutdown: Bool
    public var uncleanStarts: [Date]
    public var lastError: String?
    public var updatedAt: Date

    public init(phase: Phase, baseline: Snapshot?, target: DisplayID?, virtualPID: Int32?,
                cleanShutdown: Bool, uncleanStarts: [Date], lastError: String?, updatedAt: Date) {
        self.phase = phase; self.baseline = baseline; self.target = target; self.virtualPID = virtualPID
        self.cleanShutdown = cleanShutdown; self.uncleanStarts = uncleanStarts
        self.lastError = lastError; self.updatedAt = updatedAt
    }

    public static let initial = PersistedState(
        phase: .normal, baseline: nil, target: nil, virtualPID: nil, cleanShutdown: true,
        uncleanStarts: [], lastError: nil, updatedAt: Date(timeIntervalSince1970: 0))
}

public enum RefusalReason: String, Codable, Sendable {
    case locked, busy, sidecarActive, unavailable, safeMode, unsupported, invalid, noPhysicalMonitor
}

public enum CommandResult: Codable, Equatable, Sendable {
    case ok(String), refused(RefusalReason, String), failed(String)
}
