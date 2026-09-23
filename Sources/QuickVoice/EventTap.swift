import AppKit
import CoreGraphics
import QuickVoiceCore

/// The app a recording types into, as the probe found it.
struct RecordingTarget {
    let pid: pid_t
    let bundleID: String?
}

protocol EventTapDelegate: AnyObject {
    /// Called on the tap thread right after the synthetic mouse-up has been posted at `point`.
    func eventTapDidBeginRecording(at point: CGPoint, target: RecordingTarget?)
    /// Called on the tap thread when the real mouse-up arrived (or the press was abandoned).
    func eventTapDidEndRecording()
}

/// Active session-level event tap for the left mouse button. It only listens to mouse events
/// (never flagsChanged) so WeType's keyboard tap does not treat it as a competitor.
final class EventTap {
    weak var delegate: EventTapDelegate?
    var onTapInvalidated: (() -> Void)?

    private let settings: AppSettings
    private let probe: TextFieldProbe
    private let keySynth: KeySynth

    private var thread: Thread?
    private let runLoopLock = NSLock()
    private var _runLoop: CFRunLoop?
    private var runLoop: CFRunLoop? {
        get { runLoopLock.lock(); defer { runLoopLock.unlock() }; return _runLoop }
        set { runLoopLock.lock(); _runLoop = newValue; runLoopLock.unlock() }
    }
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: CFRunLoopTimer?
    private var checkTimer: CFRunLoopTimer?
    private var machine = LongPressMachine()

    private let verdictLock = NSLock()
    private var verdicts: [Int: ProbeVerdict] = [:]
    private var results: [Int: TextFieldProbe.Result] = [:]
    /// Tap-thread only: target window of the current mouse-down.
    private var pressWindowNumber = 0
    /// Tap-thread only: window number → owning app, so blocked apps are recognized at mouse-down.
    private var windowOwners: [Int: (bundleID: String?, time: TimeInterval)] = [:]

    init(settings: AppSettings, probe: TextFieldProbe, keySynth: KeySynth) {
        self.settings = settings
        self.probe = probe
        self.keySynth = keySynth
    }

    var isRunning: Bool { thread != nil }

    /// Creates the tap on a dedicated thread. Fails when Accessibility access is missing.
    @discardableResult
    func start() -> Bool {
        if thread != nil { return true }
        let ready = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            box.ok = self.installTap()
            ready.signal()
            guard box.ok else { return }
            CFRunLoopRun()
            self.teardown()
        }
        thread.name = "QuickVoice.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 3)
        if box.ok {
            self.thread = thread
            Log.info("event tap started")
        } else {
            Log.info("event tap creation failed (accessibility not granted?)")
        }
        return box.ok
    }

    func stop() {
        guard thread != nil else { return }
        perform { [weak self] in
            guard let self else { return }
            self.apply(self.machine.reset().effects)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil
    }

    /// Drops any press in progress; releases the hotkey if it was held.
    func resetPress() {
        perform { [weak self] in
            guard let self else { return }
            self.apply(self.machine.reset().effects)
        }
    }

    // MARK: - Tap thread

    private final class ResultBox { var ok = false }

    private func installTap() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = source
        self.runLoop = loop

        let health = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3, 3, 0, 0) { [weak self] _ in
            self?.checkHealth()
        }
        CFRunLoopAddTimer(loop, health, .commonModes)
        healthTimer = health
        return true
    }

    private func teardown() {
        if let healthTimer { CFRunLoopTimerInvalidate(healthTimer) }
        if let checkTimer { CFRunLoopTimerInvalidate(checkTimer) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        healthTimer = nil
        checkTimer = nil
        port = nil
        runLoopSource = nil
        runLoop = nil
        Log.info("event tap stopped")
    }

    private func checkHealth() {
        guard let port else { return }
        if !CFMachPortIsValid(port) {
            Log.info("event tap port invalidated")
            apply(machine.reset().effects)
            DispatchQueue.main.async { [weak self] in self?.onTapInvalidated?() }
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }
        if !CGEvent.tapIsEnabled(tap: port) {
            Log.info("event tap found disabled, re-enabling")
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.info("event tap disabled by system (\(type.rawValue)), re-enabling")
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            apply(machine.reset().effects)
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeySynth.syntheticMarker {
            // Our own mouse-downs only re-sync the HID button state and must never reach an app.
            return type == .leftMouseDown ? nil : Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let output: MachineOutput
        switch type {
        case .leftMouseDown:
            let snapshot = settings.snapshot
            machine.config.holdDuration = snapshot.holdDuration
            pressWindowNumber = Self.targetWindowNumber(of: event)
            // In a blocked app the press is not tracked at all: no probe, no timer, no events.
            let allowed = AppRules.allowsLongPress(bundleID: bundleID(forWindow: pressWindowNumber, now: now), overrides: snapshot.appRules)
            output = machine.mouseDown(
                at: event.location,
                time: now,
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                modifierFlags: event.flags.rawValue,
                enabled: snapshot.enabled && allowed
            )
        case .leftMouseDragged:
            output = machine.mouseDragged(to: event.location, time: now)
        default:
            output = machine.mouseUp(at: event.location, time: now)
        }
        apply(output.effects)

        switch output.disposition {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .convertToMove:
            event.type = .mouseMoved
            event.setIntegerValueField(.mouseEventClickState, value: 0)
            event.setDoubleValueField(.mouseEventPressure, value: 0)
            return Unmanaged.passUnretained(event)
        }
    }

    /// The window that can handle this mouse event (kCGMouseEventWindowUnderMousePointer-
    /// ThatCanHandleThisEvent), or 0. The plain "window under the pointer" field is not used: it
    /// can name click-through overlays such as the Dock's full-screen window.
    private static func targetWindowNumber(of event: CGEvent) -> Int {
        guard let field = CGEventField(rawValue: 92) else { return 0 }
        return max(0, Int(event.getIntegerValueField(field)))
    }

    private func bundleID(forWindow number: Int, now: TimeInterval) -> String? {
        guard number > 0 else { return nil }
        if let cached = windowOwners[number], now - cached.time < 30 { return cached.bundleID }
        let bundleID = TextFieldProbe.ownerPID(ofWindow: number).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        if windowOwners.count > 256 { windowOwners.removeAll() }
        windowOwners[number] = (bundleID, now)
        return bundleID
    }

    private func apply(_ effects: [MachineEffect]) {
        for effect in effects {
            switch effect {
            case let .startProbe(id, point, delay):
                setVerdict(.pending, for: id)
                probe.probe(at: point, windowNumber: pressWindowNumber, after: delay, isStillPressed: { [weak self] in
                    self?.verdict(for: id) == .pending
                }) { [weak self] result in
                    self?.setResult(result, for: id)
                }
            case let .scheduleCheck(id, time):
                scheduleCheck(id: id, at: time)
            case .cancelCheck:
                cancelCheck()
                cancelProbe(for: machine.pressID)
            case let .beginRecording(point):
                cancelCheck()
                keySynth.postMouseUp(at: point)
                delegate?.eventTapDidBeginRecording(at: point, target: recordingTarget(for: machine.pressID))
            case .endRecording:
                delegate?.eventTapDidEndRecording()
            }
        }
    }

    private func scheduleCheck(id: Int, at time: TimeInterval) {
        cancelCheck()
        let delay = max(0, time - ProcessInfo.processInfo.systemUptime)
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { [weak self] _ in
            self?.fireCheck(id: id)
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        checkTimer = timer
    }

    private func cancelCheck() {
        if let checkTimer { CFRunLoopTimerInvalidate(checkTimer) }
        checkTimer = nil
    }

    private func fireCheck(id: Int) {
        checkTimer = nil
        let output = machine.checkDue(pressID: id, time: ProcessInfo.processInfo.systemUptime, verdict: verdict(for: id))
        if output.effects.contains(where: { if case .beginRecording = $0 { return true } else { return false } }) {
            Log.info("long press in \(describeResult(for: id)) -> trigger")
        } else if machine.state == .idle {
            Log.info("long press in \(describeResult(for: id)) -> skip")
        }
        apply(output.effects)
    }

    private func recordingTarget(for id: Int) -> RecordingTarget? {
        verdictLock.lock()
        defer { verdictLock.unlock() }
        guard let result = results[id], let pid = result.pid else { return nil }
        return RecordingTarget(pid: pid, bundleID: result.bundleID)
    }

    private func describeResult(for id: Int) -> String {
        verdictLock.lock()
        defer { verdictLock.unlock() }
        guard let result = results[id] else { return "? (probe did not finish in time)" }
        return "\(result.bundleID ?? "?") (\(result.detail), \(result.elapsedMilliseconds)ms)"
    }

    private func setVerdict(_ verdict: ProbeVerdict, for id: Int) {
        verdictLock.lock()
        verdicts[id] = verdict
        verdicts = verdicts.filter { $0.key > id - 8 }
        results = results.filter { $0.key > id - 8 }
        verdictLock.unlock()
    }

    private func setResult(_ result: TextFieldProbe.Result, for id: Int) {
        verdictLock.lock()
        if verdicts[id] == .pending {
            verdicts[id] = result.verdict
            results[id] = result
        }
        verdictLock.unlock()
    }

    /// A released or dragged press does not need its probe any more.
    private func cancelProbe(for id: Int) {
        verdictLock.lock()
        if verdicts[id] == .pending { verdicts[id] = .skip }
        verdictLock.unlock()
    }

    private func verdict(for id: Int) -> ProbeVerdict {
        verdictLock.lock()
        defer { verdictLock.unlock() }
        return verdicts[id] ?? .pending
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
