import CoreGraphics
import Foundation
import QuickVoiceCore

protocol EventTapDelegate: AnyObject {
    /// Called on the tap thread right after the synthetic mouse-up has been posted.
    func eventTapDidBeginRecording()
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

    /// NSEventTypePressure: Force Touch pressure changes that follow a trackpad click.
    private static let pressureEventType: UInt32 = 34

    private func installTap() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(1) << Self.pressureEventType) { $0 | (CGEventMask(1) << $1.rawValue) }
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
            // Pressing harder on a Force Touch trackpad while talking must not trigger Look Up.
            if type.rawValue == Self.pressureEventType, machine.state == .recording { return nil }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeySynth.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let output: MachineOutput
        switch type {
        case .leftMouseDown:
            let snapshot = settings.snapshot
            machine.config.holdDuration = snapshot.holdDuration
            output = machine.mouseDown(
                at: event.location,
                time: now,
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                modifierFlags: event.flags.rawValue,
                enabled: snapshot.enabled
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

    private func apply(_ effects: [MachineEffect]) {
        for effect in effects {
            switch effect {
            case let .startProbe(id, point):
                setVerdict(.pending, for: id)
                probe.probe(at: point) { [weak self] result in
                    self?.setVerdict(result.verdict, for: id)
                }
            case let .scheduleCheck(id, time):
                scheduleCheck(id: id, at: time)
            case .cancelCheck:
                cancelCheck()
            case let .beginRecording(point):
                cancelCheck()
                keySynth.postMouseUp(at: point)
                Log.info("long press triggered")
                delegate?.eventTapDidBeginRecording()
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
        apply(output.effects)
    }

    private func setVerdict(_ verdict: ProbeVerdict, for id: Int) {
        verdictLock.lock()
        verdicts[id] = verdict
        verdicts = verdicts.filter { $0.key > id - 8 }
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
