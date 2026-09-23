import Foundation

/// Result of holding one candidate key during the 「测试语音快捷键」 diagnostic.
public enum HotkeyTestOutcome: Equatable, Sendable {
    /// Recording started while the key was held and stopped after release.
    case pushToTalk(latency: TimeInterval)
    /// Recording started but kept going after release: this is the press-once key, not hold-to-talk.
    case toggle(latency: TimeInterval)
    /// The microphone never started.
    case noResponse
    /// The microphone was already in use before the key was pressed, so the result is unknown.
    case micBusy
    case skipped(String)

    public var isPushToTalk: Bool {
        if case .pushToTalk = self { return true }
        return false
    }

    public func summary(for ime: VoiceIME) -> String {
        switch self {
        case let .pushToTalk(latency):
            return String(format: "可用：按住 %.1f 秒后开始录音，松开后结束", latency)
        case let .toggle(latency):
            return String(format: "会开始录音（%.1f 秒）", latency) + "，但松开后不停止：这是「\(ime.toggleName)」快捷键，不是「\(ime.pushToTalkName)」"
        case .noResponse:
            return "没有反应：\(ime.name)没有开始录音"
        case .micBusy:
            return "无法判断：测试前麦克风已被其它应用占用"
        case let .skipped(reason):
            return "已跳过：\(reason)"
        }
    }

    /// - Parameters:
    ///   - micBusyBefore: the input device was already running before the key went down.
    ///   - startLatency: seconds from key-down until the microphone started, or nil if it never did.
    ///   - stoppedAfterRelease: the microphone stopped within the grace period after key-up.
    public static func evaluate(micBusyBefore: Bool, startLatency: TimeInterval?, stoppedAfterRelease: Bool) -> HotkeyTestOutcome {
        if micBusyBefore { return .micBusy }
        guard let startLatency else { return .noResponse }
        return stoppedAfterRelease ? .pushToTalk(latency: startLatency) : .toggle(latency: startLatency)
    }
}
