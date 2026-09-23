import Foundation

/// Doubao IME keeps its settings as one NSKeyedArchiver dictionary stored as an MMKV value (key
/// `d`). Each voice shortcut is a virtual key code plus NSEvent modifier flags that include the
/// device bits telling left from right; a key code of -1 means the user cleared the shortcut.
public enum DoubaoSettings {
    public static let relativePath = "Library/Application Support/DoubaoIme/.com.apple.xpc.activityd/com.apple.xpc.activity"

    public enum ReadError: Error, Equatable {
        case noSettingsDictionary
    }

    /// 「按住说话，松手结束」
    static let pushToTalkKeyCode = "asrLongPressShortcutKeyCode"
    static let pushToTalkFlags = "asrLongPressShortcutModifierFlags"
    /// 「按一次即可开始说话，再按任意键可结束」
    static let toggleKeyCode = "asrShortcutKeyCode"
    static let toggleFlags = "asrShortcutModifierFlags"
    static let toggleEnabled = "isStartASRShortcutEnable"
    static let commandCandidates = "useLeftRightCommandToSelectCandidate"
    static let globalVoice = "isGloableASRShortcutEnable"

    public static func parse(_ values: [String: Data]) throws -> IMEVoiceConfig {
        let keys = values.keys.sorted { lhs, rhs in (lhs == "d") != (rhs == "d") ? lhs == "d" : lhs < rhs }
        for key in keys {
            guard let value = values[key], let dictionary = decodeDictionary(value),
                  dictionary[pushToTalkKeyCode] != nil || dictionary[toggleKeyCode] != nil else { continue }
            return parse(dictionary: dictionary)
        }
        throw ReadError.noSettingsDictionary
    }

    public static func parse(dictionary: [String: Any]) -> IMEVoiceConfig {
        IMEVoiceConfig(
            pushToTalk: shortcut(dictionary, keyCode: pushToTalkKeyCode, flags: pushToTalkFlags, enabled: nil),
            toggle: shortcut(dictionary, keyCode: toggleKeyCode, flags: toggleFlags, enabled: toggleEnabled),
            commandSelectsCandidates: (dictionary[commandCandidates] as? NSNumber)?.boolValue,
            worksInOtherInputMethods: (dictionary[globalVoice] as? NSNumber)?.boolValue
        )
    }

    static func shortcut(_ dictionary: [String: Any], keyCode: String, flags: String, enabled: String?) -> VoiceShortcut? {
        guard let code = (dictionary[keyCode] as? NSNumber)?.intValue else { return nil }
        let modifierFlags = (dictionary[flags] as? NSNumber)?.int64Value ?? 0
        return VoiceShortcut(
            keyCodes: keyCodes(keyCode: code, modifierFlags: modifierFlags),
            modifierFlags: modifierFlags,
            enabled: enabled.flatMap { (dictionary[$0] as? NSNumber)?.boolValue }
        )
    }

    /// The physical keys of a stored shortcut, modifiers first. A shortcut on a modifier key
    /// carries that key's own flag, which is not a second key.
    public static func keyCodes(keyCode: Int, modifierFlags: Int64) -> [Int] {
        guard keyCode >= 0 else { return [] }
        let flags = UInt64(bitPattern: modifierFlags)
        let own = ModifierKey(keyCode: keyCode)
        let hasDeviceBits = flags & HotkeyRecorder.deviceBitsMask != 0
        var codes: [Int] = []
        for modifier in ModifierKey.allCases where modifier != own {
            let held: Bool
            if hasDeviceBits {
                held = flags & modifier.deviceFlag != 0
            } else {
                held = !modifier.isRight && modifier.genericFlag != own?.genericFlag && flags & modifier.genericFlag != 0
            }
            if held { codes.append(Int(modifier.keyCode)) }
        }
        return codes + [keyCode]
    }

    /// Decodes with an allowlist of plain value classes, so the archive cannot instantiate anything else.
    static func decodeDictionary(_ value: Data) -> [String: Any]? {
        guard let archive = archiveData(in: value) else { return nil }
        let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSDate.self]
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: archive)) as? [String: Any]
    }

    /// MMKV stores archived objects as raw bytes; tolerate a length prefix in front as well.
    static func archiveData(in value: Data) -> Data? {
        let magic = Data("bplist00".utf8)
        if value.starts(with: magic) { return value }
        let bytes = [UInt8](value)
        guard let length = MMKVReader.readVarint(bytes, 0, bytes.count),
              length.next + Int(length.value) == bytes.count else { return nil }
        let inner = Data(bytes[length.next...])
        return inner.starts(with: magic) ? inner : nil
    }
}
