import Foundation

/// Raw `CGEventFlags` bit values. The device-dependent bits come from `IOLLEvent.h`
/// (`NX_DEVICE*KEYMASK`); apps and input methods use them to tell left from right.
public enum EventFlagBits {
    public static let alphaShift: UInt64 = 0x0001_0000
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let secondaryFn: UInt64 = 0x0080_0000
    public static let nonCoalesced: UInt64 = 0x0000_0100

    public static let deviceLeftControl: UInt64 = 0x0000_0001
    public static let deviceLeftShift: UInt64 = 0x0000_0002
    public static let deviceRightShift: UInt64 = 0x0000_0004
    public static let deviceLeftCommand: UInt64 = 0x0000_0008
    public static let deviceRightCommand: UInt64 = 0x0000_0010
    public static let deviceLeftOption: UInt64 = 0x0000_0020
    public static let deviceRightOption: UInt64 = 0x0000_0040
    public static let deviceRightControl: UInt64 = 0x0000_2000

    /// Modifiers that make a click "not a plain click" (Caps Lock is a lock state, so it is ignored).
    public static let userModifiers: UInt64 = shift | control | option | command
}

public enum KeyCode {
    public static let space: UInt16 = 49
    public static let capsLock: UInt16 = 57
    public static let function: UInt16 = 63
}

public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case leftCommand, rightCommand
    case leftShift, rightShift
    case leftOption, rightOption
    case leftControl, rightControl

    public var keyCode: UInt16 {
        switch self {
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftControl: return 59
        case .rightControl: return 62
        }
    }

    public var genericFlag: UInt64 {
        switch self {
        case .leftCommand, .rightCommand: return EventFlagBits.command
        case .leftShift, .rightShift: return EventFlagBits.shift
        case .leftOption, .rightOption: return EventFlagBits.option
        case .leftControl, .rightControl: return EventFlagBits.control
        }
    }

    public var deviceFlag: UInt64 {
        switch self {
        case .leftCommand: return EventFlagBits.deviceLeftCommand
        case .rightCommand: return EventFlagBits.deviceRightCommand
        case .leftShift: return EventFlagBits.deviceLeftShift
        case .rightShift: return EventFlagBits.deviceRightShift
        case .leftOption: return EventFlagBits.deviceLeftOption
        case .rightOption: return EventFlagBits.deviceRightOption
        case .leftControl: return EventFlagBits.deviceLeftControl
        case .rightControl: return EventFlagBits.deviceRightControl
        }
    }

    public var isRight: Bool {
        switch self {
        case .rightCommand, .rightShift, .rightOption, .rightControl: return true
        default: return false
        }
    }

    public var symbol: String {
        switch self {
        case .leftCommand, .rightCommand: return "⌘"
        case .leftShift, .rightShift: return "⇧"
        case .leftOption, .rightOption: return "⌥"
        case .leftControl, .rightControl: return "⌃"
        }
    }

    public var displayName: String {
        let side = isRight ? "右" : "左"
        switch self {
        case .leftCommand, .rightCommand: return "\(side) Command"
        case .leftShift, .rightShift: return "\(side) Shift"
        case .leftOption, .rightOption: return "\(side) Option"
        case .leftControl, .rightControl: return "\(side) Control"
        }
    }

    public init?(keyCode: Int) {
        guard let match = ModifierKey.allCases.first(where: { Int($0.keyCode) == keyCode }) else { return nil }
        self = match
    }
}

/// One synthesized keyboard event, independent of CoreGraphics so it can be unit tested.
public struct KeyStroke: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case flagsChanged
        case keyDown
        case keyUp
    }

    public var kind: Kind
    public var keyCode: UInt16
    public var flags: UInt64

    public init(_ kind: Kind, keyCode: UInt16, flags: UInt64) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
    }
}

/// A voice hotkey: zero or more modifiers pressed in order, optionally followed by one ordinary key.
public struct Hotkey: Codable, Hashable, Sendable {
    public var modifiers: [ModifierKey]
    public var key: UInt16?

    public init(modifiers: [ModifierKey], key: UInt16? = nil) {
        self.modifiers = modifiers
        self.key = key
    }

    public var isValid: Bool {
        guard !modifiers.isEmpty || key != nil else { return false }
        guard Set(modifiers).count == modifiers.count else { return false }
        if let key {
            return key != KeyCode.function && key != KeyCode.capsLock && ModifierKey(keyCode: Int(key)) == nil
        }
        return true
    }

    public var keyCodes: [UInt16] {
        modifiers.map(\.keyCode) + (key.map { [$0] } ?? [])
    }

    public var displayName: String {
        var parts = modifiers.map(\.displayName)
        if let key { parts.append(KeyNames.name(for: Int(key))) }
        return parts.joined(separator: " + ")
    }

    /// Order-insensitive comparison with a list of physical key codes (as stored by WeType).
    public func matches(keyCodes other: [Int]) -> Bool {
        Set(keyCodes.map(Int.init)) == Set(other) && keyCodes.count == other.count
    }

    public var pressSequence: [KeyStroke] {
        var strokes: [KeyStroke] = []
        var held: [ModifierKey] = []
        for modifier in modifiers {
            held.append(modifier)
            strokes.append(KeyStroke(.flagsChanged, keyCode: modifier.keyCode, flags: Hotkey.flags(for: held)))
        }
        if let key {
            strokes.append(KeyStroke(.keyDown, keyCode: key, flags: Hotkey.flags(for: held)))
        }
        return strokes
    }

    public var releaseSequence: [KeyStroke] {
        var strokes: [KeyStroke] = []
        var held = modifiers
        if let key {
            strokes.append(KeyStroke(.keyUp, keyCode: key, flags: Hotkey.flags(for: held)))
        }
        for modifier in modifiers.reversed() {
            held.removeAll { $0 == modifier }
            strokes.append(KeyStroke(.flagsChanged, keyCode: modifier.keyCode, flags: Hotkey.flags(for: held)))
        }
        return strokes
    }

    static func flags(for held: [ModifierKey]) -> UInt64 {
        held.reduce(EventFlagBits.nonCoalesced) { $0 | $1.genericFlag | $1.deviceFlag }
    }

    /// Builds a hotkey from the physical key codes an input method stored. Returns nil when the
    /// combination cannot be synthesized with CGEventPost (Fn, Caps Lock, several ordinary keys).
    public init?(physicalKeyCodes codes: [Int]) {
        guard !codes.isEmpty else { return nil }
        var modifiers: [ModifierKey] = []
        var key: UInt16?
        for code in codes {
            if let modifier = ModifierKey(keyCode: code) {
                guard !modifiers.contains(modifier) else { return nil }
                modifiers.append(modifier)
            } else {
                guard key == nil, code >= 0, code < 128 else { return nil }
                key = UInt16(code)
            }
        }
        let hotkey = Hotkey(modifiers: modifiers, key: key)
        guard hotkey.isValid else { return nil }
        self = hotkey
    }
}

public struct HotkeyPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let hotkey: Hotkey
    public let name: String
    public let note: String

    /// The preset's name, marked when it is the input method's recommended key.
    public func title(for ime: VoiceIME) -> String {
        hotkey == ime.defaultHotkey ? "\(name)（推荐）" : name
    }

    public static let rightOption = HotkeyPreset(
        id: "rightOption",
        hotkey: Hotkey(modifiers: [.rightOption]),
        name: "右 Option",
        note: "程序可以模拟；平时单独按它不会触发任何功能，Mac 自带键盘也有这个键。"
    )
    public static let rightCommand = HotkeyPreset(
        id: "rightCommand",
        hotkey: Hotkey(modifiers: [.rightCommand]),
        name: "右 Command",
        note: "程序可以模拟，Mac 自带键盘也有这个键；如果输入法开启了「用左右 Command 选候选词」，有候选词时会冲突。"
    )
    public static let rightControl = HotkeyPreset(
        id: "rightControl",
        hotkey: Hotkey(modifiers: [.rightControl]),
        name: "右 Control",
        note: "程序可以模拟；Mac 自带键盘没有这个键，需要外接键盘才能在输入法设置里录入。"
    )
    public static let rightShift = HotkeyPreset(
        id: "rightShift",
        hotkey: Hotkey(modifiers: [.rightShift]),
        name: "右 Shift",
        note: "程序可以模拟；输入法通常用 Shift 切换中英文，可能冲突。"
    )
    public static let optionSpace = HotkeyPreset(
        id: "optionSpace",
        hotkey: Hotkey(modifiers: [.leftOption], key: KeyCode.space),
        name: "⌥ + 空格",
        note: "程序可以模拟；一些启动器（如 Raycast、ChatGPT）也常用这个组合。"
    )

    public static let all: [HotkeyPreset] = [rightOption, rightCommand, rightControl, rightShift, optionSpace]

    public static func matching(_ hotkey: Hotkey) -> HotkeyPreset? {
        all.first { $0.hotkey == hotkey }
    }
}
