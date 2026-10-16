import Foundation

/// Where an input method's voice hotkey comes from.
public enum HotkeySource: String, Codable, CaseIterable, Sendable {
    /// Read the input method's own voice shortcut and press exactly that.
    case followIME
    /// Use the hotkey chosen or recorded in this app.
    case manual
}

/// The user's hotkey settings for one input method.
public struct IMEHotkeySetting: Codable, Hashable, Sendable {
    public var source: HotkeySource
    /// The chosen or recorded hotkey; also held when following the input method is not possible.
    public var manual: Hotkey

    public init(source: HotkeySource, manual: Hotkey) {
        self.source = source
        self.manual = manual
    }

    public static func standard(for ime: VoiceIME) -> IMEHotkeySetting {
        IMEHotkeySetting(source: .followIME, manual: ime.defaultHotkey)
    }

    /// Settings saved before the input method could be chosen (`hotkeySource`, `hotkey`) were
    /// WeType's; nil when there are none.
    public static func migrated(legacySource: String?, legacyHotkey: Hotkey?) -> IMEHotkeySetting? {
        guard legacySource != nil || legacyHotkey != nil else { return nil }
        return IMEHotkeySetting(
            source: legacySource == HotkeySource.manual.rawValue ? .manual : .followIME,
            manual: legacyHotkey.flatMap { $0.isValid ? $0 : nil } ?? VoiceIME.weType.defaultHotkey
        )
    }
}

public struct HotkeyResolution: Equatable, Sendable {
    public var ime: VoiceIME
    public var hotkey: Hotkey
    /// True when `hotkey` is the input method's own voice shortcut.
    public var followsIME: Bool
    /// Why following the input method was not possible, shown to the user.
    public var fallbackReason: String?

    public init(ime: VoiceIME, hotkey: Hotkey, followsIME: Bool, fallbackReason: String? = nil) {
        self.ime = ime
        self.hotkey = hotkey
        self.followsIME = followsIME
        self.fallbackReason = fallbackReason
    }

    /// Where the hotkey came from, for the log and menus.
    public var origin: String {
        followsIME ? "跟随\(ime.name)" : (fallbackReason ?? "手动设置")
    }
}

public enum HotkeyResolver {
    public static func resolve(_ setting: IMEHotkeySetting, ime: VoiceIME, config: IMEVoiceConfig?) -> HotkeyResolution {
        let manual = setting.manual
        guard setting.source == .followIME else {
            return HotkeyResolution(ime: ime, hotkey: manual, followsIME: false)
        }
        func fallback(_ reason: String) -> HotkeyResolution {
            HotkeyResolution(ime: ime, hotkey: manual, followsIME: false, fallbackReason: reason + "，暂时\(ime.trigger.verb)「\(manual.displayName)」")
        }
        let shortcutName = "\(ime.name)的「\(ime.shortcutName)」"
        guard let config else {
            return fallback("没能读取\(ime.name)的设置")
        }
        guard let shortcut = config.shortcut(for: ime.trigger) else {
            return fallback("\(ime.name)没有记录「\(ime.shortcutName)」快捷键（默认是 Fn，程序无法模拟）")
        }
        if shortcut.isCleared {
            return fallback("\(shortcutName)快捷键是空的，请先在\(ime.name)里设置它")
        }
        if shortcut.enabled == false {
            return fallback("\(shortcutName)已关闭，请先在\(ime.name)里打开它")
        }
        if shortcut.usesFn {
            return fallback("\(shortcutName)是「\(shortcut.displayName)」，Fn 无法被程序模拟")
        }
        guard let hotkey = shortcut.hotkey else {
            return fallback("\(shortcutName)是「\(shortcut.displayName)」，程序无法模拟")
        }
        return HotkeyResolution(ime: ime, hotkey: hotkey, followsIME: true)
    }
}
