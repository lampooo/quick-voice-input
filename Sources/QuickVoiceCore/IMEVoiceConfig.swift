import Foundation

/// A voice shortcut as an input method stores it: the physical keys and how they are pressed.
public struct VoiceShortcut: Equatable, Sendable {
    /// Physical key codes, modifiers included. Empty when the user cleared the shortcut.
    public var keyCodes: [Int]
    public var modifierFlags: Int64?
    public var tapCount: Int
    /// The input method's on/off switch for this shortcut; nil when it has none.
    public var enabled: Bool?

    public init(keyCodes: [Int], modifierFlags: Int64? = nil, tapCount: Int = 1, enabled: Bool? = nil) {
        self.keyCodes = keyCodes
        self.modifierFlags = modifierFlags
        self.tapCount = tapCount
        self.enabled = enabled
    }

    public var isCleared: Bool { keyCodes.isEmpty }

    public var usesFn: Bool { keyCodes.contains(Int(KeyCode.function)) }

    /// The equivalent hotkey this app can synthesize, or nil (Fn, multi-tap, unusual keys).
    public var hotkey: Hotkey? {
        guard tapCount <= 1 else { return nil }
        return Hotkey(physicalKeyCodes: keyCodes)
    }

    public var displayName: String {
        guard !keyCodes.isEmpty else { return "未设置" }
        let keys = keyCodes.map { KeyNames.name(for: $0) }.joined(separator: " + ")
        return tapCount > 1 ? "连按 \(tapCount) 次 \(keys)" : keys
    }
}

/// How an input method stores its settings on disk.
public enum IMESettingsFormat: Sendable {
    /// MMKV with `voicePTTShortcut_*` keys (WeType).
    case weTypeMMKV
    /// MMKV holding one NSKeyedArchiver dictionary with `asr*Shortcut*` keys (Doubao).
    case doubaoMMKV
}

/// What an input method's settings say about voice input.
public struct IMEVoiceConfig: Equatable, Sendable {
    public var version: String?
    /// Hold to talk, release to finish (「按住说话」).
    public var pushToTalk: VoiceShortcut?
    /// Press once to start, press again to finish.
    public var toggle: VoiceShortcut?
    /// 「用左右 Command 选候选词」: while candidates are showing, Command picks one.
    public var commandSelectsCandidates: Bool?
    /// The shortcuts also work while another input method is selected (Doubao's 「全局唤起语音」).
    public var worksInOtherInputMethods: Bool?

    public init(
        version: String? = nil,
        pushToTalk: VoiceShortcut? = nil,
        toggle: VoiceShortcut? = nil,
        commandSelectsCandidates: Bool? = nil,
        worksInOtherInputMethods: Bool? = nil
    ) {
        self.version = version
        self.pushToTalk = pushToTalk
        self.toggle = toggle
        self.commandSelectsCandidates = commandSelectsCandidates
        self.worksInOtherInputMethods = worksInOtherInputMethods
    }

    public static func parse(_ data: Data, format: IMESettingsFormat) throws -> IMEVoiceConfig {
        let values = try MMKVReader.parse(data)
        switch format {
        case .weTypeMMKV: return WeTypeSettings.parse(values)
        case .doubaoMMKV: return try DoubaoSettings.parse(values)
        }
    }
}
