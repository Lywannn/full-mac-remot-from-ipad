import Foundation

/// The emergency hotkey from `Config.hotkey`, e.g. "ctrl+opt+cmd+n". Parsing only: Core must not import Carbon, so the
/// values are copied from Carbon (`kVK_ANSI_*`, `kVK_F*`, `controlKey` ...); a System test cross-checks them.
public struct HotkeySpec: Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    private static let modifiers: [String: UInt32] = [
        "ctrl": 0x1000, "control": 0x1000,
        "opt": 0x0800, "option": 0x0800, "alt": 0x0800,
        "cmd": 0x0100, "command": 0x0100,
        "shift": 0x0200,
    ]
    /// Without one of these a bare key (or shift+key) would hijack normal typing.
    private static let required: UInt32 = 0x1000 | 0x0800 | 0x0100

    private static let keys: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C,
        "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    public init?(parsing text: String) {
        var mods: UInt32 = 0
        var key: UInt32?
        var seen = Set<String>()
        for raw in text.split(separator: "+", omittingEmptySubsequences: false) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !token.isEmpty, seen.insert(token).inserted else { return nil }
            if let m = Self.modifiers[token] {
                guard mods & m == 0 else { return nil }   // synonyms of one modifier ("ctrl+control")
                mods |= m
            } else if let k = Self.keys[token] {
                guard key == nil else { return nil }
                key = k
            } else {
                return nil
            }
        }
        guard let key, mods & Self.required != 0 else { return nil }
        self.keyCode = key
        self.carbonModifiers = mods
    }
}
