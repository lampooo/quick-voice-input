import Foundation

/// Turns the key events of one "press the shortcut now" session into a `Hotkey`.
/// Modifiers are recorded in press order and keep their side (left/right); the recording
/// finishes when an ordinary key goes down or when every held modifier has been released.
public struct HotkeyRecorder: Sendable {
    public enum Step: Equatable, Sendable {
        case waiting
        case holding([ModifierKey])
        case finished(Hotkey)
        case rejected(String)
        case cancelled
    }

    public private(set) var step: Step = .waiting
    private var order: [ModifierKey] = []
    private var held: Set<ModifierKey> = []

    static let escapeKeyCode = 53
    static let deviceBitsMask: UInt64 = 0x207F

    public init() {}

    public mutating func flagsChanged(keyCode: Int, flags: UInt64) -> Step {
        guard isActive else { return step }
        if keyCode == Int(KeyCode.function) {
            step = .rejected("Fn 键无法被程序模拟，请换一个键，比如右 Option 或右 Command。")
            return step
        }
        if keyCode == Int(KeyCode.capsLock) {
            step = .rejected("Caps Lock 不能用作语音快捷键。")
            return step
        }
        guard let modifier = ModifierKey(keyCode: keyCode) else { return step }
        if Self.isDown(modifier, flags: flags) {
            held.insert(modifier)
            if !order.contains(modifier) { order.append(modifier) }
            step = .holding(order.filter(held.contains))
        } else {
            held.remove(modifier)
            if held.isEmpty, !order.isEmpty {
                step = .finished(Hotkey(modifiers: order))
            } else {
                step = .holding(order.filter(held.contains))
            }
        }
        return step
    }

    public mutating func keyDown(keyCode: Int, isRepeat: Bool) -> Step {
        guard isActive, !isRepeat else { return step }
        if keyCode == Self.escapeKeyCode, held.isEmpty {
            step = .cancelled
            return step
        }
        guard keyCode >= 0, keyCode < 128, ModifierKey(keyCode: keyCode) == nil else { return step }
        let hotkey = Hotkey(modifiers: order.filter(held.contains), key: UInt16(keyCode))
        step = hotkey.isValid ? .finished(hotkey) : .rejected("这个键不能用作语音快捷键。")
        return step
    }

    private var isActive: Bool {
        switch step {
        case .waiting, .holding: return true
        case .finished, .rejected, .cancelled: return false
        }
    }

    /// Uses the side-specific device bit when the event carries any, else the generic flag.
    public static func isDown(_ modifier: ModifierKey, flags: UInt64) -> Bool {
        if flags & deviceBitsMask != 0 {
            return flags & modifier.deviceFlag != 0
        }
        return flags & modifier.genericFlag != 0
    }
}
