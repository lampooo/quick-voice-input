import Foundation

/// A voice shortcut as recorded in WeType's settings (`voicePTTShortcut_*` / `voiceToggleShortcut_*`).
public struct WeTypeShortcut: Equatable, Sendable {
    public var keyCodes: [Int]
    public var modifierFlags: Int64?
    public var tapCount: Int
    public var enabled: Bool?

    public init(keyCodes: [Int], modifierFlags: Int64? = nil, tapCount: Int = 1, enabled: Bool? = nil) {
        self.keyCodes = keyCodes
        self.modifierFlags = modifierFlags
        self.tapCount = tapCount
        self.enabled = enabled
    }

    public var usesFn: Bool { keyCodes.contains(Int(KeyCode.function)) }

    /// The equivalent hotkey this app can synthesize, or nil (Fn, multi-tap, unusual keys).
    public var hotkey: Hotkey? {
        guard tapCount <= 1 else { return nil }
        return Hotkey(weTypeKeyCodes: keyCodes)
    }

    public var displayName: String {
        let keys = keyCodes.map { KeyNames.name(for: $0) }.joined(separator: " + ")
        return tapCount > 1 ? "连按 \(tapCount) 次 \(keys)" : keys
    }
}

public struct WeTypeVoiceConfig: Equatable, Sendable {
    public var version: String?
    /// 「按住说话」: hold to talk, release to finish.
    public var pushToTalk: WeTypeShortcut?
    /// 「启动语音输入」: press once to start, any key to stop.
    public var toggle: WeTypeShortcut?

    public init(version: String? = nil, pushToTalk: WeTypeShortcut? = nil, toggle: WeTypeShortcut? = nil) {
        self.version = version
        self.pushToTalk = pushToTalk
        self.toggle = toggle
    }

    public static let settingsRelativePath = "Library/Application Support/WeType/mmkv/wetype.settings"

    public static func parse(_ values: [String: Data]) -> WeTypeVoiceConfig {
        WeTypeVoiceConfig(
            version: values["currentVersion"].flatMap(MMKVReader.string),
            pushToTalk: shortcut(values, prefix: "voicePTTShortcut", enabledKey: "voicePTTHotKey"),
            toggle: shortcut(values, prefix: "voiceToggleShortcut", enabledKey: "voiceToggleHotKey")
        )
    }

    public static func load(fromFile url: URL) throws -> WeTypeVoiceConfig {
        parse(try MMKVReader.parse(try Data(contentsOf: url)))
    }

    static func shortcut(_ values: [String: Data], prefix: String, enabledKey: String) -> WeTypeShortcut? {
        guard let raw = values["\(prefix)_keyCodes"].flatMap(MMKVReader.string),
              let codes = parseKeyCodes(raw), !codes.isEmpty else { return nil }
        let tapCount = values["\(prefix)_tapCount"].flatMap(MMKVReader.int).map { max(1, Int($0)) } ?? 1
        return WeTypeShortcut(
            keyCodes: codes,
            modifierFlags: values["\(prefix)_modifiers"].flatMap(MMKVReader.int),
            tapCount: tapCount,
            enabled: values[enabledKey].flatMap(MMKVReader.bool)
        )
    }

    /// Parses WeType's JSON-like key code list, e.g. `[58,49]`.
    public static func parseKeyCodes(_ text: String) -> [Int]? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var codes: [Int] = []
        for item in array {
            guard let number = item as? NSNumber else { return nil }
            codes.append(number.intValue)
        }
        return codes
    }
}
