import Foundation

/// WeType keeps its settings in MMKV. Its voice shortcuts are `voicePTTShortcut_*` (「按住说话」)
/// and `voiceToggleShortcut_*` (「启动语音输入」); key codes are stored as text such as `[58,49]`.
public enum WeTypeSettings {
    public static let relativePath = "Library/Application Support/WeType/mmkv/wetype.settings"

    public static func parse(_ values: [String: Data]) -> IMEVoiceConfig {
        IMEVoiceConfig(
            version: values["currentVersion"].flatMap(MMKVReader.string),
            pushToTalk: shortcut(values, prefix: "voicePTTShortcut", enabledKey: "voicePTTHotKey"),
            toggle: shortcut(values, prefix: "voiceToggleShortcut", enabledKey: "voiceToggleHotKey"),
            commandSelectsCandidates: values["commandCandidateShortcut"].flatMap(MMKVReader.bool)
        )
    }

    static func shortcut(_ values: [String: Data], prefix: String, enabledKey: String) -> VoiceShortcut? {
        guard let raw = values["\(prefix)_keyCodes"].flatMap(MMKVReader.string),
              let codes = parseKeyCodes(raw) else { return nil }
        let tapCount = values["\(prefix)_tapCount"].flatMap(MMKVReader.int).map { max(1, Int($0)) } ?? 1
        return VoiceShortcut(
            keyCodes: codes,
            modifierFlags: values["\(prefix)_modifiers"].flatMap(MMKVReader.int),
            tapCount: tapCount,
            enabled: values[enabledKey].flatMap(MMKVReader.bool)
        )
    }

    /// Parses WeType's JSON-like key code list, e.g. `[58,49]`; `[]` is a cleared shortcut.
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
