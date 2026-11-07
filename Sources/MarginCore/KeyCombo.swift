import Foundation

/// A parsed shortcut such as `cmd+shift+]`, using ANSI virtual key codes.
public struct KeyCombo: Equatable, Sendable {
    public var keyCode: UInt16
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init?(_ text: String) {
        var key: UInt16?
        // A literal "+" is the last token: "cmd++" splits to ["cmd", "", ""].
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if text.hasSuffix("+") {
            parts.removeLast(2)
            parts.append("=")
        }
        for part in parts {
            switch part {
            case "cmd", "command": command = true
            case "shift": shift = true
            case "opt", "option", "alt": option = true
            case "ctrl", "control": control = true
            default:
                guard key == nil, let code = Self.codes[part] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        keyCode = key
    }

    /// True for a key that would type into a text box instead of commanding the
    /// app, such as a site's plain `k`. Arrows, Return and Tab don't count.
    public var typesText: Bool {
        !command && !control && !option && keyCode < 51 && keyCode != 36 && keyCode != 48
    }

    /// One spelling for a shortcut, so `cmd+=` and `command + =` compare equal.
    public static func canonical(_ text: String) -> String? {
        guard let combo = KeyCombo(text) else { return nil }
        return Self.text(keyCode: combo.keyCode, command: combo.command, shift: combo.shift, option: combo.option, control: combo.control)
    }

    /// The text form of a pressed key, as `KeyCombo` parses it. Nil for a key
    /// it has no name for.
    public static func text(keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool) -> String? {
        guard let key = codes.filter({ $0.value == keyCode }).keys.min(by: { ($0.count, $0) < ($1.count, $1) }) else { return nil }
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("opt") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "home": 115, "pageup": 116, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
