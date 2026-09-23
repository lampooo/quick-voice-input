import Foundation

/// Whether dictated text reached the text field, judged only from the field's character count
/// before the hotkey went down and at a few moments after it was released.
public enum CommitCheck {
    /// Seconds after the release at which the count is read. Input methods finish recognition and
    /// may polish the text after the key is released, so this goes on for a few seconds.
    public static let sampleDelays: [TimeInterval] = [0, 0.3, 1, 2, 3.5, 5]

    public struct Sample: Equatable, Sendable {
        public var after: TimeInterval
        /// nil when the field could not be read at that moment.
        public var length: Int?

        public init(after: TimeInterval, length: Int?) {
            self.after = after
            self.length = length
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The count grew; `after` is when it first reached its final value.
        case committed(added: Int, after: TimeInterval)
        /// The count changed without growing, e.g. dictation replaced a selection.
        case changed(delta: Int, after: TimeInterval)
        case unchanged(waited: TimeInterval)
        case unavailable(String)

        public var summary: String {
            switch self {
            case let .committed(added, after) where after == 0:
                return "已上屏 \(added) 个字符（松开时已出现）"
            case let .committed(added, after):
                return "已上屏 \(added) 个字符（松开后 \(Self.seconds(after)) 秒）"
            case let .changed(delta, after):
                return "输入框字数变化 \(delta)（松开后 \(Self.seconds(after)) 秒），可能替换了选中的文字"
            case let .unchanged(waited):
                return "松开后 \(Self.seconds(waited)) 秒内输入框里没有新文字"
            case let .unavailable(reason):
                return "无法判断是否上屏：\(reason)"
            }
        }

        public var logDescription: String {
            switch self {
            case let .committed(added, after) where after == 0: return "committed +\(added) chars, already there at release"
            case let .committed(added, after): return "committed +\(added) chars, \(Self.seconds(after))s after release"
            case let .changed(delta, after): return "changed by \(delta) chars, \(Self.seconds(after))s after release"
            case let .unchanged(waited): return "no new text within \(Self.seconds(waited))s"
            case let .unavailable(reason): return "unknown (\(reason))"
            }
        }

        public static func seconds(_ value: TimeInterval) -> String {
            String(format: value == value.rounded() ? "%.0f" : "%.1f", value)
        }
    }

    public static func evaluate(baseline: Int?, samples: [Sample]) -> Outcome {
        guard let baseline else { return .unavailable("开始时读不到输入框的字数") }
        let readable = samples.compactMap { sample in sample.length.map { (after: sample.after, length: $0) } }
        guard let final = readable.last else { return .unavailable("松开后读不到输入框的字数") }
        guard final.length != baseline else { return .unchanged(waited: samples.last?.after ?? final.after) }
        var reachedAt = final.after
        for sample in readable.reversed() {
            guard sample.length == final.length else { break }
            reachedAt = sample.after
        }
        let delta = final.length - baseline
        return delta > 0 ? .committed(added: delta, after: reachedAt) : .changed(delta: delta, after: reachedAt)
    }
}
