import Foundation

/// A process seen through its heartbeat file: nil `pid` means no file; `age` is how long ago it last beat.
public struct ProcessLiveness: Equatable, Sendable {
    public var pid: Int32?
    public var age: Duration?
    public init(pid: Int32?, age: Duration?) { self.pid = pid; self.age = age }
}

public enum StatusFormatter {
    /// `locked` nil means unknown (no GUI session, e.g. over SSH).
    /// `stateKnown` false (state.json missing or unreadable) shows the mode as unknown.
    public static func text(_ s: PersistedState, displays: [DisplayInfo], locked: Bool?,
                            daemon: ProcessLiveness? = nil, watchdog: ProcessLiveness? = nil,
                            stateKnown: Bool = true) -> String {
        var lines = ["Mode: " + (stateKnown ? modeText(s.phase) : "tidak diketahui")]
        lines.append("Layar:")
        if displays.isEmpty { lines.append("  (tidak ada data layar)") }
        for d in displays { lines.append("  " + displayLine(d)) }
        if let e = s.lastError, !e.isEmpty { lines.append("Kesalahan terakhir: \(e)") }
        lines.append("Mac terkunci: " + (locked.map { $0 ? "ya" : "tidak" } ?? "tidak diketahui"))
        lines.append(processLine("Daemon", daemon))
        lines.append(processLine("Watchdog", watchdog))
        return lines.joined(separator: "\n")
    }

    static func modeText(_ phase: Phase) -> String {
        func name(_ m: Mode) -> String { m == .remote ? "Remote" : "Sidecar" }
        switch phase {
        case .normal: return "Normal"
        case .active(let m): return name(m)
        case .confirming(let m): return "\(name(m)) (menunggu konfirmasi)"
        case .entering(let m): return "\(name(m)) (sedang berpindah)"
        case .exiting: return "kembali ke Normal (tertunda)"
        }
    }

    static func displayLine(_ d: DisplayInfo) -> String {
        let kind: String
        switch d.kind {
        case .physical: kind = "monitor"
        case .sidecar: kind = "Sidecar"
        case .ownVirtual: kind = "virtual ipadmode"
        case .otherVirtual: kind = "virtual lain"
        }
        var flags = [d.isOnline ? "online" : "offline", d.isActive ? "aktif" : "tidak aktif"]
        if d.isMain { flags.append("utama") }
        var line = "\(d.name) [\(kind), id \(d.id.raw)] \(flags.joined(separator: ", "))"
        if let m = d.mode {
            line += " — \(m.widthPoints)x\(m.heightPoints)"
            if m.refreshHz > 0 { line += " @\(Int(m.refreshHz.rounded()))Hz" }
        }
        return line
    }

    static func processLine(_ label: String, _ p: ProcessLiveness?) -> String {
        guard let p, let pid = p.pid else { return "\(label): tidak ada detak" }
        guard let age = p.age else { return "\(label): PID \(pid), detak tidak terbaca" }
        let c = age.components
        if c.seconds > 86_400 { return "\(label): PID \(pid), detak basi" }
        return "\(label): PID \(pid), detak \(c.seconds) dtk lalu"
    }
}
