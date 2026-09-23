import CoreGraphics
import Foundation

public struct LongPressConfig: Equatable, Sendable {
    /// How long the left button must stay down before voice input starts.
    public var holdDuration: TimeInterval
    /// Movement (in points) allowed while waiting; more than this means the user is dragging.
    public var moveTolerance: Double
    /// Extra time to wait for the text-field probe after the hold duration has elapsed.
    public var maxProbeWait: TimeInterval
    /// Interval between re-checks while the probe is still running.
    public var probeRecheckInterval: TimeInterval

    public init(
        holdDuration: TimeInterval = 0.5,
        moveTolerance: Double = 5,
        maxProbeWait: TimeInterval = 0.4,
        probeRecheckInterval: TimeInterval = 0.05
    ) {
        self.holdDuration = holdDuration
        self.moveTolerance = moveTolerance
        self.maxProbeWait = maxProbeWait
        self.probeRecheckInterval = probeRecheckInterval
    }

    public static let holdDurationChoices: [TimeInterval] = [0.3, 0.5, 0.8, 1.2]
}

public enum PressState: Equatable, Sendable {
    case idle
    /// Timing a press; moving past the tolerance or releasing cancels it.
    case pressing(origin: CGPoint, startedAt: TimeInterval)
    /// The voice hotkey is held; waiting for the real mouse-up.
    case recording
}

/// What the event tap should do with the event it just received.
public enum EventDisposition: Equatable, Sendable {
    case pass
    case swallow
    case convertToMove
}

public enum MachineEffect: Equatable, Sendable {
    /// Ask the text-field probe whether a long press at this point may start voice input.
    case startProbe(pressID: Int, at: CGPoint)
    /// Call `checkDue(pressID:time:verdict:)` at the given time.
    case scheduleCheck(pressID: Int, at: TimeInterval)
    case cancelCheck
    /// Post a synthetic mouse-up at this point, then hold the voice hotkey.
    case beginRecording(at: CGPoint)
    /// Release the voice hotkey.
    case endRecording
}

public struct MachineOutput: Equatable, Sendable {
    public var disposition: EventDisposition
    public var effects: [MachineEffect]

    public init(disposition: EventDisposition = .pass, effects: [MachineEffect] = []) {
        self.disposition = disposition
        self.effects = effects
    }
}

public enum ProbeVerdict: Equatable, Sendable {
    case pending
    case trigger
    case skip
}

/// Pure long-press state machine. Time is injected so it can be unit tested; the event tap
/// feeds it mouse events and executes the returned effects.
public struct LongPressMachine: Sendable {
    public private(set) var state: PressState = .idle
    public private(set) var pressID = 0
    public var config: LongPressConfig
    private var lastPoint: CGPoint = .zero

    public init(config: LongPressConfig = LongPressConfig()) {
        self.config = config
    }

    public mutating func mouseDown(
        at point: CGPoint,
        time: TimeInterval,
        clickCount: Int,
        modifierFlags: UInt64,
        enabled: Bool
    ) -> MachineOutput {
        var effects = abandonCurrent()
        guard enabled, clickCount == 1, modifierFlags & EventFlagBits.userModifiers == 0 else {
            return MachineOutput(disposition: .pass, effects: effects)
        }
        pressID &+= 1
        state = .pressing(origin: point, startedAt: time)
        lastPoint = point
        effects.append(.startProbe(pressID: pressID, at: point))
        effects.append(.scheduleCheck(pressID: pressID, at: time + config.holdDuration))
        return MachineOutput(disposition: .pass, effects: effects)
    }

    public mutating func mouseDragged(to point: CGPoint, time: TimeInterval) -> MachineOutput {
        switch state {
        case .idle:
            return MachineOutput()
        case let .pressing(origin, _):
            lastPoint = point
            if Self.distance(origin, point) > config.moveTolerance {
                state = .idle
                return MachineOutput(disposition: .pass, effects: [.cancelCheck])
            }
            return MachineOutput()
        case .recording:
            lastPoint = point
            return MachineOutput(disposition: .convertToMove)
        }
    }

    public mutating func mouseUp(at point: CGPoint, time: TimeInterval) -> MachineOutput {
        switch state {
        case .idle:
            return MachineOutput()
        case .pressing:
            state = .idle
            return MachineOutput(disposition: .pass, effects: [.cancelCheck])
        case .recording:
            state = .idle
            return MachineOutput(disposition: .swallow, effects: [.endRecording])
        }
    }

    /// Called when a scheduled check fires. `verdict` is the probe result for this press.
    public mutating func checkDue(pressID id: Int, time: TimeInterval, verdict: ProbeVerdict) -> MachineOutput {
        guard id == pressID, case let .pressing(_, startedAt) = state else { return MachineOutput() }
        let dueAt = startedAt + config.holdDuration
        if time + 0.001 < dueAt {
            return MachineOutput(effects: [.scheduleCheck(pressID: id, at: dueAt)])
        }
        switch verdict {
        case .trigger:
            state = .recording
            return MachineOutput(effects: [.beginRecording(at: lastPoint)])
        case .skip:
            state = .idle
            return MachineOutput()
        case .pending:
            let deadline = dueAt + config.maxProbeWait
            if time + 0.001 >= deadline {
                state = .idle
                return MachineOutput()
            }
            let next = min(time + config.probeRecheckInterval, deadline)
            return MachineOutput(effects: [.scheduleCheck(pressID: id, at: next)])
        }
    }

    /// Drops any press in progress (feature disabled, tap re-enabled, watchdog).
    public mutating func reset() -> MachineOutput {
        MachineOutput(effects: abandonCurrent())
    }

    private mutating func abandonCurrent() -> [MachineEffect] {
        defer { state = .idle }
        switch state {
        case .idle: return []
        case .pressing: return [.cancelCheck]
        case .recording: return [.endRecording]
        }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
