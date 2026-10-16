import Foundation

/// How long things take when a voice shortcut is tapped to start and tapped again to stop.
public struct TapToggleTiming: Equatable, Sendable {
    /// How long the key stays down for one tap.
    public var tapHold: TimeInterval
    /// The least time between the end of one tap and the start of the next, so two taps are never
    /// read as a double tap.
    public var minInterval: TimeInterval
    /// How long to wait for the microphone to start after the first tap.
    public var startConfirmTimeout: TimeInterval
    /// How long to wait for the microphone to stop after the second tap.
    public var stopConfirmTimeout: TimeInterval
    /// How long to wait for the real keyboard to be idle before the first tap (give up after that).
    public var idleWaitForStart: TimeInterval
    /// Same before the second tap. Stopping matters more than being polite, so it waits for longer,
    /// then taps anyway.
    public var idleWaitForStop: TimeInterval
    /// Idle wait and stop confirmation while the app is quitting.
    public var urgentIdleWait: TimeInterval
    public var urgentStopConfirmTimeout: TimeInterval
    public var pollInterval: TimeInterval
    /// After a first tap that was not seen to start anything, how long a late start is still
    /// attributed to it (and stopped).
    public var lateStartWindow: TimeInterval
    /// Pause after a tap before the modifier state is read back.
    public var settle: TimeInterval

    public init(
        tapHold: TimeInterval = 0.1,
        minInterval: TimeInterval = 0.8,
        startConfirmTimeout: TimeInterval = 2.0,
        stopConfirmTimeout: TimeInterval = 2.0,
        idleWaitForStart: TimeInterval = 0.5,
        idleWaitForStop: TimeInterval = 4.0,
        urgentIdleWait: TimeInterval = 0.3,
        urgentStopConfirmTimeout: TimeInterval = 1.2,
        pollInterval: TimeInterval = 0.05,
        lateStartWindow: TimeInterval = 4.0,
        settle: TimeInterval = 0.03
    ) {
        self.tapHold = Self.clampedTapHold(tapHold)
        self.minInterval = minInterval
        self.startConfirmTimeout = startConfirmTimeout
        self.stopConfirmTimeout = stopConfirmTimeout
        self.idleWaitForStart = idleWaitForStart
        self.idleWaitForStop = idleWaitForStop
        self.urgentIdleWait = urgentIdleWait
        self.urgentStopConfirmTimeout = urgentStopConfirmTimeout
        self.pollInterval = pollInterval
        self.lateStartWindow = lateStartWindow
        self.settle = settle
    }

    public static let standard = TapToggleTiming()

    /// Too short a tap may be missed by the listener; too long one may be read as a hold.
    public static func clampedTapHold(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, 0.03), 0.4)
    }
}

/// What the tap-to-toggle engine needs from the system. Everything blocks the calling thread and
/// must not wait for the main thread, so the engine can also run while the app is quitting.
public protocol TapToggleEnvironment: AnyObject {
    /// A monotonic clock, in seconds.
    var now: TimeInterval { get }
    func sleep(_ seconds: TimeInterval)
    /// Remembers which input devices are running now (they are not counted as ours later) and
    /// returns whether the default input device is already running.
    func captureMicBaseline() -> Bool
    /// Whether the default input device, or an input device that was not running at the baseline, is running.
    func micActive() -> Bool
    /// True when the real keyboard has no key or modifier held down.
    func realInputIdle() -> Bool
    /// Presses `hotkey`, keeps it down for `seconds`, then releases it.
    func tap(_ hotkey: Hotkey, holdFor seconds: TimeInterval)
    /// True when no modifier of `hotkey` (and none of its keys) is still down in the system.
    func modifiersClean(after hotkey: Hotkey) -> Bool
    /// Posts the release events of `hotkey` once more.
    func forceRelease(_ hotkey: Hotkey)
    /// Remembers across launches that a recording may be running (the first tap went out).
    func persist(active: Bool)
    func log(_ message: String)
}

public enum TapToggleStartOutcome: Equatable, Sendable {
    /// The microphone started this long after the tap.
    case started(latency: TimeInterval)
    /// The default input was already running, so nothing was tapped: a tap might have stopped a
    /// recording that is not ours.
    case micBusy
    /// The real keyboard had a key held for too long, so nothing was tapped.
    case realKeysHeld
    /// The user let go before the tap, so nothing was tapped.
    case aborted
    /// The tap went out but the microphone did not start. No second tap will be sent for it, and a
    /// late start is still looked for.
    case notStarted
    /// A recording of ours is already running; nothing was tapped.
    case alreadyActive
}

public enum TapToggleStopOutcome: Equatable, Sendable {
    /// The microphone stopped after the stop tap; `retried` when a second one was needed.
    case stopped(retried: Bool)
    /// Nothing of ours to stop.
    case notRecording
    /// The microphone had already stopped before the stop tap, so no tap was sent.
    case endedByItself
    /// Still recording after the stop tap and the one compensating tap. Nothing more is sent.
    case stuck
}

/// Starts and stops a dictation that its engine toggles with one shortcut, safely: it taps only
/// when the real keyboard is idle, never taps twice within `minInterval`, sends the second tap
/// only after seeing the microphone start, checks that the microphone stopped, and sends at most
/// one compensating tap. Each tap is a complete press and release, followed by a check that no
/// modifier was left down.
public final class TapToggleSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// A recording is running (the microphone was seen to start).
        case recording
        /// The tap went out but no microphone start was seen (yet).
        case startUnconfirmed
        /// Still recording after the stop tap and the compensating one.
        case stuck
    }

    private let environment: TapToggleEnvironment
    public let timing: TapToggleTiming
    /// Serializes start/stop/recover, which block for seconds.
    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private var currentState = State.idle
    private var activeHotkey: Hotkey?
    private var lastTapEnd: TimeInterval?

    public init(environment: TapToggleEnvironment, timing: TapToggleTiming = .standard) {
        self.environment = environment
        self.timing = timing
    }

    public var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    /// True while a stop tap may still be owed.
    public var needsStop: Bool {
        switch state {
        case .recording, .stuck, .startUnconfirmed: return true
        case .idle: return false
        }
    }

    public var lateStartWindow: TimeInterval { timing.lateStartWindow }

    // MARK: Start

    /// Taps `hotkey` once and waits for the microphone to start. Blocks the calling thread.
    public func start(_ hotkey: Hotkey, shouldAbort: () -> Bool = { false }) -> TapToggleStartOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        if state != .idle {
            if environment.micActive() {
                if state == .startUnconfirmed { setState(.recording) }
                environment.log("tap start skipped: a recording is already running (\(state))")
                return .alreadyActive
            }
            setState(.idle)
        }

        guard waitForIdle(timeout: timing.idleWaitForStart, shouldAbort: shouldAbort) else {
            if shouldAbort() { return .aborted }
            environment.log("tap start skipped: a real key is held down")
            return .realKeysHeld
        }
        waitForMinInterval(shouldAbort: shouldAbort)
        if shouldAbort() { return .aborted }

        if environment.captureMicBaseline() {
            environment.log("tap start skipped: the default input device is already running")
            return .micBusy
        }

        activeHotkey = hotkey
        environment.persist(active: true)
        let tappedAt = environment.now
        sendTap(hotkey)
        let deadline = tappedAt + timing.startConfirmTimeout
        repeat {
            if environment.micActive() {
                setState(.recording)
                return .started(latency: environment.now - tappedAt)
            }
            environment.sleep(timing.pollInterval)
        } while environment.now < deadline
        setState(.startUnconfirmed)
        environment.log("tap start: the microphone did not start within \(timing.startConfirmTimeout)s; no stop tap will be sent for it")
        return .notStarted
    }

    /// While waiting on an unconfirmed start: whether the recording turned out to have started.
    @discardableResult
    public func pollLateStart() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard state == .startUnconfirmed, environment.micActive() else { return false }
        environment.log("tap start: the microphone started late")
        setState(.recording)
        return true
    }

    /// Called once the late-start window of an unconfirmed start has passed. A recording that
    /// started late is stopped; otherwise the start is forgotten.
    @discardableResult
    public func settleUnconfirmedStart() -> TapToggleStopOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard state == .startUnconfirmed else { return .notRecording }
        guard environment.micActive(), let hotkey = activeHotkey else {
            setState(.idle)
            return .notRecording
        }
        environment.log("tap start: the microphone started late; stopping it")
        setState(.recording)
        return performStop(hotkey, urgent: false)
    }

    // MARK: Stop

    /// Taps once more to end the recording, if there is one running. Blocks the calling thread.
    @discardableResult
    public func stop(reason: String, urgent: Bool = false) -> TapToggleStopOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        switch state {
        case .idle:
            return .notRecording
        case .startUnconfirmed:
            guard environment.micActive() else { return .notRecording }
            environment.log("tap stop (\(reason)): the microphone started late")
            setState(.recording)
        case .recording, .stuck:
            break
        }
        guard let hotkey = activeHotkey else {
            setState(.idle)
            return .notRecording
        }
        guard environment.micActive() else {
            environment.log("tap stop (\(reason)): the microphone had already stopped")
            setState(.idle)
            return .endedByItself
        }
        environment.log("tap stop (\(reason))")
        return performStop(hotkey, urgent: urgent)
    }

    /// A recording left behind by a previous run that was cut off before its stop tap.
    @discardableResult
    public func recoverLeftoverRecording(with hotkey: Hotkey) -> TapToggleStopOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard state == .idle else { return .notRecording }
        guard environment.captureMicBaseline() else {
            environment.persist(active: false)
            return .notRecording
        }
        environment.log("tap recover: the microphone is still running after the previous run; stopping it")
        activeHotkey = hotkey
        setState(.recording)
        return performStop(hotkey, urgent: false)
    }

    // MARK: Taps

    private func performStop(_ hotkey: Hotkey, urgent: Bool) -> TapToggleStopOutcome {
        let idleWait = urgent ? timing.urgentIdleWait : timing.idleWaitForStop
        let confirm = urgent ? timing.urgentStopConfirmTimeout : timing.stopConfirmTimeout
        if !waitForIdle(timeout: idleWait) {
            environment.log("tap stop: a real key is still held down; tapping anyway so the recording does not run on")
        }
        waitForMinInterval()
        guard environment.micActive() else {
            setState(.idle)
            return .endedByItself
        }
        sendTap(hotkey)
        if waitForMicStop(timeout: confirm) {
            setState(.idle)
            return .stopped(retried: false)
        }

        environment.log("tap stop: still recording \(confirm)s after the stop tap; sending one compensating tap")
        waitForMinInterval()
        guard environment.micActive() else {
            setState(.idle)
            return .stopped(retried: false)
        }
        sendTap(hotkey)
        if waitForMicStop(timeout: confirm) {
            setState(.idle)
            return .stopped(retried: true)
        }
        environment.log("tap stop: still recording after the compensating tap; giving up")
        setState(.stuck)
        return .stuck
    }

    private func sendTap(_ hotkey: Hotkey) {
        environment.tap(hotkey, holdFor: timing.tapHold)
        environment.sleep(timing.settle)
        if !environment.modifiersClean(after: hotkey) {
            environment.log("a modifier was still down after the tap; releasing it")
            environment.forceRelease(hotkey)
            environment.sleep(timing.settle)
            if !environment.modifiersClean(after: hotkey) {
                environment.log("a modifier is still down after releasing it again")
            }
        }
        lastTapEnd = environment.now
    }

    private func waitForIdle(timeout: TimeInterval, shouldAbort: () -> Bool = { false }) -> Bool {
        let deadline = environment.now + timeout
        while true {
            if environment.realInputIdle() { return true }
            if shouldAbort() || environment.now >= deadline { return false }
            environment.sleep(timing.pollInterval)
        }
    }

    private func waitForMinInterval(shouldAbort: () -> Bool = { false }) {
        guard let lastTapEnd else { return }
        while !shouldAbort() {
            let remaining = lastTapEnd + timing.minInterval - environment.now
            if remaining <= 0 { return }
            environment.sleep(min(remaining, timing.pollInterval))
        }
    }

    private func waitForMicStop(timeout: TimeInterval) -> Bool {
        let deadline = environment.now + timeout
        repeat {
            if !environment.micActive() { return true }
            environment.sleep(timing.pollInterval)
        } while environment.now < deadline
        return false
    }

    private func setState(_ new: State) {
        stateLock.lock()
        currentState = new
        stateLock.unlock()
        if new == .idle {
            environment.persist(active: false)
        }
    }
}
