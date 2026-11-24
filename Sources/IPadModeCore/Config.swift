import Foundation

public struct Resolution: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public static let allowed: [Resolution] = [
        Resolution(width: 1180, height: 820), Resolution(width: 1321, height: 918),
        Resolution(width: 1416, height: 984), Resolution(width: 1534, height: 1066),
        Resolution(width: 1652, height: 1148),
    ]
    public static let defaultRemote = Resolution(width: 1180, height: 820)

    private init(width: Int, height: Int) { self.width = width; self.height = height }

    /// Hanya nilai di `allowed`.
    public init?(parsing s: String) {
        let parts = s.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              let match = Resolution.allowed.first(where: { $0.width == w && $0.height == h })
        else { return nil }
        self = match
    }

    public var text: String { "\(width)x\(height)" }

    /// The virtual display's mode at this resolution (R28): these points, twice as many pixels (HiDPI), 60 Hz.
    public var remoteMode: DisplayMode {
        DisplayMode(widthPoints: width, heightPoints: height, widthPixels: width * 2, heightPixels: height * 2,
                    refreshHz: 60)
    }
}

public enum ConfigScope: String, Codable, Sendable { case appOnly, session }

public struct Config: Codable, Equatable, Sendable {
    public struct Remote: Codable, Equatable, Sendable {
        public var resolution: String = "1180x820"
        public var confirmSeconds: Int = 20
        enum CodingKeys: String, CodingKey { case resolution, confirmSeconds }
        public init() {}
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? resolution
            confirmSeconds = try c.decodeIfPresent(Int.self, forKey: .confirmSeconds) ?? confirmSeconds
        }
    }
    public struct Sidecar: Codable, Equatable, Sendable {
        public var deviceId: String? = nil
        public var transport: String = "auto"
        public var disconnectOnNormal: Bool = false
        public var confirmSeconds: Int = 20
        public var autoConnectWhenHeadless: Bool = false
        enum CodingKeys: String, CodingKey { case deviceId, transport, disconnectOnNormal, confirmSeconds, autoConnectWhenHeadless }
        public init() {}
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
            transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? transport
            disconnectOnNormal = try c.decodeIfPresent(Bool.self, forKey: .disconnectOnNormal) ?? disconnectOnNormal
            confirmSeconds = try c.decodeIfPresent(Int.self, forKey: .confirmSeconds) ?? confirmSeconds
            autoConnectWhenHeadless = try c.decodeIfPresent(Bool.self, forKey: .autoConnectWhenHeadless) ?? autoConnectWhenHeadless
        }
        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(deviceId, forKey: .deviceId)   // tulis null eksplisit
            try c.encode(transport, forKey: .transport)
            try c.encode(disconnectOnNormal, forKey: .disconnectOnNormal)
            try c.encode(confirmSeconds, forKey: .confirmSeconds)
            try c.encode(autoConnectWhenHeadless, forKey: .autoConnectWhenHeadless)
        }
    }
    public struct Watchdog: Codable, Equatable, Sendable {
        public var intervalMs: Int = 500
        public var heartbeatStaleSeconds: Int = 5
        enum CodingKeys: String, CodingKey { case intervalMs, heartbeatStaleSeconds }
        public init() {}
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            intervalMs = try c.decodeIfPresent(Int.self, forKey: .intervalMs) ?? intervalMs
            heartbeatStaleSeconds = try c.decodeIfPresent(Int.self, forKey: .heartbeatStaleSeconds) ?? heartbeatStaleSeconds
        }
    }

    public var remote = Remote()
    public var sidecar = Sidecar()
    public var headlessFallback = true
    public var hotkey = "ctrl+opt+cmd+n"
    public var watchdog = Watchdog()

    enum CodingKeys: String, CodingKey { case remote, sidecar, headlessFallback, hotkey, watchdog }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        remote = try c.decodeIfPresent(Remote.self, forKey: .remote) ?? remote
        sidecar = try c.decodeIfPresent(Sidecar.self, forKey: .sidecar) ?? sidecar
        headlessFallback = try c.decodeIfPresent(Bool.self, forKey: .headlessFallback) ?? headlessFallback
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? hotkey
        watchdog = try c.decodeIfPresent(Watchdog.self, forKey: .watchdog) ?? watchdog
    }

    public static let `default` = Config()
}

public enum ConfigLoader {
    /// File tidak ada -> default tanpa peringatan. Rusak atau resolusi tak dikenal -> default/pengganti + peringatan.
    public static func load(from url: URL) -> (config: Config, warnings: [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.default, []) }
        guard let data = try? Data(contentsOf: url) else {
            return (.default, ["Config tidak bisa dibaca (\(url.path)); memakai default."])
        }
        guard var config = try? JSONDecoder().decode(Config.self, from: data) else {
            return (.default, ["Config rusak (\(url.path)); memakai default."])
        }
        var warnings: [String] = []
        if Resolution(parsing: config.remote.resolution) == nil {
            warnings.append("Resolusi \"\(config.remote.resolution)\" tidak didukung; memakai \(Resolution.defaultRemote.text).")
            config.remote.resolution = Resolution.defaultRemote.text
        }
        // 0 means no confirmation; a negative window makes no sense.
        if config.remote.confirmSeconds < 0 {
            let fallback = Config.Remote().confirmSeconds
            warnings.append("remote.confirmSeconds \(config.remote.confirmSeconds) tidak boleh negatif; memakai \(fallback).")
            config.remote.confirmSeconds = fallback
        }
        if config.sidecar.confirmSeconds < 0 {
            let fallback = Config.Sidecar().confirmSeconds
            warnings.append("sidecar.confirmSeconds \(config.sidecar.confirmSeconds) tidak boleh negatif; memakai \(fallback).")
            config.sidecar.confirmSeconds = fallback
        }
        // The watchdog is the last-resort safety process: keep its timing sane.
        if config.watchdog.heartbeatStaleSeconds < 3 {
            warnings.append("watchdog.heartbeatStaleSeconds \(config.watchdog.heartbeatStaleSeconds) terlalu kecil; memakai 3.")
            config.watchdog.heartbeatStaleSeconds = 3
        }
        if !(50...5000).contains(config.watchdog.intervalMs) {
            let clamped = min(5000, max(50, config.watchdog.intervalMs))
            warnings.append("watchdog.intervalMs \(config.watchdog.intervalMs) di luar 50...5000; memakai \(clamped).")
            config.watchdog.intervalMs = clamped
        }
        return (config, warnings)
    }

    public static func save(_ c: Config, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(c)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
