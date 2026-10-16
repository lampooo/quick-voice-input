import Foundation

/// Result of trying one candidate key during the 「测试语音快捷键」 diagnostic.
public enum HotkeyTestOutcome: Equatable, Sendable {
    /// Recording started while the key was held and stopped after release.
    case pushToTalk(latency: TimeInterval)
    /// Recording started but kept going after release: this is the press-once key, not hold-to-talk.
    case toggle(latency: TimeInterval)
    /// One tap started the recording and a second tap ended it (the tap-to-toggle test).
    case tapToggle(startLatency: TimeInterval, stopLatency: TimeInterval)
    /// One tap started the recording but the second one (and the compensating one) did not end it.
    case tapStuck(startLatency: TimeInterval)
    /// The microphone never started.
    case noResponse
    /// The microphone was already in use before the key was pressed, so the result is unknown.
    case micBusy
    case skipped(String)

    public var isPushToTalk: Bool {
        if case .pushToTalk = self { return true }
        return false
    }

    /// The key does what the input method's trigger mode needs: hold-to-talk, or tap to start and tap to stop.
    public var isWorking: Bool {
        switch self {
        case .pushToTalk, .tapToggle: return true
        default: return false
        }
    }

    public func summary(for ime: VoiceIME) -> String {
        switch self {
        case let .pushToTalk(latency):
            return String(format: "可用：按住 %.1f 秒后开始录音，松开后结束", latency)
        case let .toggle(latency):
            return String(format: "会开始录音（%.1f 秒）", latency) + "，但松开后不停止：这是「\(ime.toggleName)」快捷键，不是「\(ime.pushToTalkName)」"
        case let .tapToggle(startLatency, stopLatency):
            return String(format: "可用：点按一次约 %.1f 秒后开始录音，再点按一次约 %.1f 秒后结束", startLatency, stopLatency)
        case let .tapStuck(startLatency):
            return String(format: "点按一次能开始录音（%.1f 秒），但再点按没能结束：请手动在\(ime.name)里结束这次录音", startLatency)
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

    /// The outcome of a tap-to-start, tap-to-stop test, from what the tap engine reported.
    public static func evaluate(start: TapToggleStartOutcome, stop: TapToggleStopOutcome?, stopLatency: TimeInterval) -> HotkeyTestOutcome {
        switch start {
        case .micBusy, .alreadyActive:
            return .micBusy
        case .notStarted:
            return .noResponse
        case .realKeysHeld:
            return .skipped("测试时键盘上有按键没有松开")
        case .aborted:
            return .skipped("测试已取消")
        case let .started(startLatency):
            switch stop {
            case .some(.stopped):
                return .tapToggle(startLatency: startLatency, stopLatency: stopLatency)
            case .some(.endedByItself):
                return .skipped("录音在第二次点按之前自己结束了，无法确认点按能否结束录音")
            default:
                return .tapStuck(startLatency: startLatency)
            }
        }
    }
}
