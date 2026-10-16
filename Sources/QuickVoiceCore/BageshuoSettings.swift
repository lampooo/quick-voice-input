import Foundation

/// NetEase Bageshuo keeps its settings in one JSON file. Its 「语音输入」 shortcut is
/// `settings.polishHotkeys` (a list; `polishHotkey` is the older single value) and is written as
/// names joined by `+`, such as `LeftCommand`, `Fn+LeftShift` or `mouse4`. The same file holds the
/// account session and history, which are never read: only the shortcut names are picked out.
public enum BageshuoSettings {
    public static let relativePath = "Library/Application Support/com.bageshuo/bageshuo-store.json"

    public enum ReadError: Error, Equatable {
        case notJSONObject
        case noSettings
    }

    static let listKey = "polishHotkeys"
    static let singleKey = "polishHotkey"

    public static func parse(_ data: Data) throws -> IMEVoiceConfig {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReadError.notJSONObject
        }
        guard let settings = root["settings"] as? [String: Any] else {
            throw ReadError.noSettings
        }
        return IMEVoiceConfig(toggle: voiceShortcut(in: settings))
    }

    /// The shortcut to follow. With several bound, the first one this app can synthesize wins.
    static func voiceShortcut(in settings: [String: Any]) -> VoiceShortcut? {
        var names: [String] = []
        if let list = settings[listKey] as? [Any] {
            names = list.compactMap { $0 as? String }
        }
        if names.isEmpty, let single = settings[singleKey] as? String {
            names = [single]
        }
        guard !names.isEmpty else { return nil }
        let shortcuts = names.map(shortcut(named:))
        return shortcuts.first { $0.hotkey != nil } ?? shortcuts.first { !$0.isCleared } ?? shortcuts.first
    }

    public static func shortcut(named name: String) -> VoiceShortcut {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return VoiceShortcut(keyCodes: []) }
        var codes: [Int] = []
        var unknown = false
        for token in trimmed.split(separator: "+", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let code = keyCode(forToken: token) {
                codes.append(code)
            } else {
                unknown = true
            }
        }
        if let mouse = mouseDisplayName(trimmed) {
            return VoiceShortcut(keyCodes: [], unsynthesizableName: mouse)
        }
        if unknown {
            return VoiceShortcut(keyCodes: [], unsynthesizableName: trimmed)
        }
        return VoiceShortcut(keyCodes: codes)
    }

    private static func mouseDisplayName(_ name: String) -> String? {
        let tokens = name.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let mouse = tokens.first(where: { $0.lowercased().hasPrefix("mouse") })?.lowercased() else { return nil }
        let label: String
        switch mouse {
        case "mousemiddle": label = "鼠标中键"
        case "mouse4": label = "鼠标侧键 4"
        case "mouse5": label = "鼠标侧键 5"
        default: label = "鼠标键 " + mouse.dropFirst(5)
        }
        let others = tokens.filter { !$0.lowercased().hasPrefix("mouse") }.map { token in
            keyCode(forToken: token).map(KeyNames.name(for:)) ?? token
        }
        return (others + [label]).joined(separator: " + ")
    }

    /// A name without a side (`Command`) means either side; the left key is synthesized for it.
    private static let modifierCodes: [String: ModifierKey] = [
        "leftcommand": .leftCommand, "rightcommand": .rightCommand, "command": .leftCommand, "cmd": .leftCommand,
        "leftshift": .leftShift, "rightshift": .rightShift, "shift": .leftShift,
        "leftoption": .leftOption, "rightoption": .rightOption, "option": .leftOption,
        "leftalt": .leftOption, "rightalt": .rightOption, "alt": .leftOption,
        "leftcontrol": .leftControl, "rightcontrol": .rightControl, "control": .leftControl,
        "leftctrl": .leftControl, "rightctrl": .rightControl, "ctrl": .leftControl,
    ]

    private static let namedKeys: [String: Int] = {
        var table: [String: Int] = [
            "space": 49, "enter": 36, "return": 36, "tab": 48, "escape": 53, "esc": 53,
            "backspace": 51, "delete": 51, "forwarddelete": 117,
            "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124,
            "down": 125, "arrowdown": 125, "up": 126, "arrowup": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
        ]
        let letters: [(String, Int)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5), ("h", 4), ("i", 34), ("j", 38),
            ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31), ("p", 35), ("q", 12), ("r", 15), ("s", 1),
            ("t", 17), ("u", 32), ("v", 9), ("w", 13), ("x", 7), ("y", 16), ("z", 6),
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ]
        for (name, code) in letters {
            table[name] = code
            table["key" + name] = code
            table["digit" + name] = code
        }
        let functionKeys: [Int] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() {
            table["f\(index + 1)"] = code
        }
        return table
    }()

    static func keyCode(forToken token: String) -> Int? {
        let lowered = token.lowercased()
        if lowered == "fn" || lowered == "function" { return Int(KeyCode.function) }
        if let modifier = modifierCodes[lowered] { return Int(modifier.keyCode) }
        if lowered.hasPrefix("mouse") { return nil }
        return namedKeys[lowered]
    }
}
