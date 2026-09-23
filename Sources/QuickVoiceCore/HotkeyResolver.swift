import Foundation

/// Where the voice hotkey comes from.
public enum HotkeySource: String, Codable, CaseIterable, Sendable {
    /// Read WeType's 「按住说话」 shortcut and hold exactly that.
    case followWeType
    /// Use the hotkey chosen or recorded in this app.
    case manual
}

public struct HotkeyResolution: Equatable, Sendable {
    public var hotkey: Hotkey
    /// True when `hotkey` is WeType's own 「按住说话」 shortcut.
    public var followsWeType: Bool
    /// Why following WeType was not possible, shown to the user.
    public var fallbackReason: String?

    public init(hotkey: Hotkey, followsWeType: Bool, fallbackReason: String? = nil) {
        self.hotkey = hotkey
        self.followsWeType = followsWeType
        self.fallbackReason = fallbackReason
    }
}

public enum HotkeyResolver {
    public static func resolve(source: HotkeySource, manual: Hotkey, weType: WeTypeVoiceConfig?) -> HotkeyResolution {
        guard source == .followWeType else {
            return HotkeyResolution(hotkey: manual, followsWeType: false)
        }
        let fallback = "，暂时按住「\(manual.displayName)」"
        guard let weType else {
            return HotkeyResolution(hotkey: manual, followsWeType: false, fallbackReason: "没能读取微信输入法的设置" + fallback)
        }
        guard let shortcut = weType.pushToTalk else {
            return HotkeyResolution(hotkey: manual, followsWeType: false,
                                    fallbackReason: "微信输入法没有记录「按住说话」快捷键（默认是 Fn，程序无法模拟）" + fallback)
        }
        if shortcut.enabled == false {
            return HotkeyResolution(hotkey: manual, followsWeType: false,
                                    fallbackReason: "微信输入法的「按住说话」已关闭，请先在微信输入法里打开它" + fallback)
        }
        if shortcut.usesFn {
            return HotkeyResolution(hotkey: manual, followsWeType: false,
                                    fallbackReason: "微信输入法的「按住说话」是「\(shortcut.displayName)」，Fn 无法被程序模拟" + fallback)
        }
        guard let hotkey = shortcut.hotkey else {
            return HotkeyResolution(hotkey: manual, followsWeType: false,
                                    fallbackReason: "微信输入法的「按住说话」是「\(shortcut.displayName)」，程序无法模拟" + fallback)
        }
        return HotkeyResolution(hotkey: hotkey, followsWeType: true)
    }
}
