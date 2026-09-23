import Foundation

/// Side effects a synthesized hotkey can have if the input method does not swallow it.
public enum HotkeyRisk: Equatable, Sendable {
    /// The combination is also a macOS shortcut (Spotlight, input source switching…).
    case systemShortcut(String)
    /// An ordinary key may reach the text field and type a character.
    case mayType(String)
    /// An ordinary key may trigger an app or system shortcut instead of typing.
    case mayTriggerShortcut(String)

    public var message: String {
        switch self {
        case let .systemShortcut(name):
            return "这个组合也是 macOS 的「\(name)」快捷键，按住时可能先触发系统功能。"
        case let .mayType(key):
            return "这个组合包含普通键「\(key)」。如果微信输入法没有拦截它，可能会在输入框里打出字符（例如 ⌥ + 空格 会打出一个不换行空格）。建议只用单个修饰键，比如右 Option。"
        case let .mayTriggerShortcut(key):
            return "这个组合包含普通键「\(key)」。如果微信输入法没有拦截它，可能会触发当前应用的快捷键。建议只用单个修饰键，比如右 Option。"
        }
    }
}

extension Hotkey {
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Known macOS shortcuts built on Space, keyed by the generic modifier flags they use.
    private static let systemSpaceShortcuts: [UInt64: String] = [
        EventFlagBits.command: "聚焦搜索（Spotlight）",
        EventFlagBits.command | EventFlagBits.option: "访达搜索窗口",
        EventFlagBits.control: "选择上一个输入法",
        EventFlagBits.control | EventFlagBits.option: "选择下一个输入法",
        EventFlagBits.control | EventFlagBits.command: "表情与符号",
    ]

    /// Empty for modifier-only hotkeys, which never produce characters.
    public var risks: [HotkeyRisk] {
        guard let key else { return [] }
        let generic = modifiers.reduce(UInt64(0)) { $0 | $1.genericFlag }
        let keyName = KeyNames.name(for: Int(key))
        var result: [HotkeyRisk] = []
        if key == KeyCode.space, let name = Self.systemSpaceShortcuts[generic] {
            result.append(.systemShortcut(name))
        }
        if Self.functionKeys.contains(key) || generic & (EventFlagBits.command | EventFlagBits.control) != 0 {
            result.append(.mayTriggerShortcut(keyName))
        } else {
            result.append(.mayType(keyName))
        }
        return result
    }
}
