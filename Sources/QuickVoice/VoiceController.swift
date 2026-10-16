import AppKit
import CoreGraphics
import Foundation
import QuickVoiceCore

/// Drives the voice engine's shortcut for the duration of a long press, on a serial queue so the
/// event tap never waits. Hold-to-talk engines get their key held until the mouse is released; a
/// tap-to-toggle engine gets one tap when the press starts and one when it ends (see
/// `TapToggleSession`). A watchdog ends the dictation if the real mouse-up was missed.
final class VoiceController: EventTapDelegate {
    var onRecordingChanged: ((Bool) -> Void)?
    /// Called (on the voice queue) when the watchdog had to release the key by itself.
    var onWatchdogRelease: (() -> Void)?
    /// Called on the main queue when a tap-to-toggle recording stopped or started being stuck.
    var onStuckChanged: (() -> Void)?

    private let settings: AppSettings
    private let keySynth: KeySynth
    private let commitChecker: CommitChecker
    private let queue = DispatchQueue(label: "quickvoice.voice", qos: .userInteractive)

    /// Guards `generation`/`endRequested` and makes "check, then press" atomic with `releaseNow`.
    private let stateLock = NSLock()
    private var generation = 0
    private var endRequested = false
    private var notice: (text: String, at: Date)?

    private let sessionLock = NSLock()
    private var tapSessions: [String: TapToggleSession] = [:]

    // Voice-queue state.
    private var watchdog: DispatchSourceTimer?
    private var releasedPolls = 0
    private var holdStartedAt: TimeInterval = 0
    private var recordingNotified = false
    private var holdTrigger = VoiceTrigger.hold
    private var watchButtonState = true
    /// A tap-to-toggle start that was not seen to work yet: if it turns out to have started
    /// late, the recording is adopted like any other.
    private var pendingLateStart: (ime: VoiceIME, target: RecordingTarget?)?
    private let maxHoldDuration: TimeInterval = 10 * 60

    init(settings: AppSettings, keySynth: KeySynth, commitChecker: CommitChecker) {
        self.settings = settings
        self.keySynth = keySynth
        self.commitChecker = commitChecker
    }

    /// The last thing that went wrong with a tap-to-toggle start or stop, for the menu; it is
    /// forgotten after a few minutes.
    var recentNotice: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let notice, Date().timeIntervalSince(notice.at) < 600 else { return nil }
        return notice.text
    }

    /// The engine whose recording could not be ended by tapping, while it is still recording.
    var stuckIME: VoiceIME? {
        let stuck = currentTapSessions().filter { $0.session.state == .stuck }
        guard let first = stuck.first, MicMonitor.defaultInputDevice().map(MicMonitor.isRunningSomewhere) == true else { return nil }
        return first.ime
    }

    // MARK: EventTapDelegate

    func eventTapDidBeginRecording(at point: CGPoint, target: RecordingTarget?) {
        stateLock.lock()
        generation += 1
        let current = generation
        endRequested = false
        stateLock.unlock()
        queue.async { [weak self] in self?.begin(generation: current, at: point, target: target) }
    }

    func eventTapDidEndRecording() {
        stateLock.lock()
        endRequested = true
        stateLock.unlock()
        queue.async { [weak self] in self?.end(reason: "mouse up") }
    }

    /// Releases the hotkey right away from any thread (pause, settings changes, signals). A
    /// tap-to-toggle recording is stopped on the voice queue.
    func releaseNow(reason: String) {
        stateLock.lock()
        endRequested = true
        stateLock.unlock()
        keySynth.release()
        queue.async { [weak self] in self?.end(reason: reason) }
    }

    /// Ends everything before the app exits, blocking until a tap-to-toggle recording has stopped
    /// (or the engine gave up on it). Never wait on the main thread from the voice queue.
    func shutdown(reason: String) {
        releaseNow(reason: reason)
        for (ime, session) in currentTapSessions() where session.needsStop {
            let outcome = session.stop(reason: reason, urgent: true)
            Log.info("shutdown stop for \(ime.id) (\(reason)) -> \(outcome)")
        }
        Log.flush()
    }

    /// Call once after launch: a recording that a previous run left behind (crash, kill) is ended.
    func recoverLeftoverRecordings() {
        queue.async { [weak self] in
            guard let self else { return }
            for ime in VoiceIME.all where ime.trigger == .tapToggle && LiveTapToggleEnvironment.hasActiveMarker(for: ime) {
                guard Permissions.isAccessibilityTrusted else {
                    Log.info("leftover \(ime.id) recording marker found, but there is no accessibility permission to end it")
                    continue
                }
                let hotkey = self.settings.resolvedHotkey(for: ime).hotkey
                let outcome = self.tapSession(for: ime).recoverLeftoverRecording(with: hotkey)
                Log.info("leftover \(ime.id) recording from a previous run -> \(outcome)")
                if outcome == .stuck { self.noteStuck(ime) }
            }
        }
    }

    // MARK: Voice queue

    private func begin(generation current: Int, at point: CGPoint, target: RecordingTarget?) {
        let snapshot = settings.snapshot
        watchButtonState = ensureButtonStillDown(at: point, generation: current)
        let selection = DispatchQueue.main.sync { VoiceTarget.select(settings: settings) }
        let ime = selection.ime
        var settle: useconds_t = 60_000
        if snapshot.autoSwitchInputSource, !ime.isStandalone {
            let switched = DispatchQueue.main.sync { () -> Bool in
                if InputSource.isCurrent(ime) { return false }
                return InputSource.select(ime)
            }
            if switched {
                waitUntilCurrent(ime, timeout: 0.5)
                settle = 150_000
            }
        }
        usleep(settle)

        let resolution = settings.resolvedHotkey(for: ime)
        let choice = selection.reason == .chosen ? "" : "，自动：\(selection.explanation)"
        if ime.trigger == .tapToggle {
            beginTapToggle(generation: current, ime: ime, resolution: resolution, choice: choice, target: target)
            return
        }

        stateLock.lock()
        let abort = endRequested || current != generation
        if !abort { keySynth.press(resolution.hotkey) }
        stateLock.unlock()
        guard !abort else {
            Log.info("released before the hotkey was pressed")
            return
        }

        holdTrigger = .hold
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        holdStartedAt = ProcessInfo.processInfo.systemUptime
        Log.info("holding hotkey \(resolution.hotkey.displayName) for \(ime.name) (\(resolution.origin)\(choice))")
        commitChecker.recordingStarted(target: target, ime: ime)
        startWatchdog()
        recordingNotified = true
        notify(true)
    }

    /// One tap to start. The mouse-up that ends the long-press gesture was already posted, so the
    /// target app is not in the middle of a click while the key goes down.
    private func beginTapToggle(generation current: Int, ime: VoiceIME, resolution: HotkeyResolution, choice: String, target: RecordingTarget?) {
        let hotkey = resolution.hotkey
        let session = tapSession(for: ime)
        pendingLateStart = nil
        let outcome = session.start(hotkey, shouldAbort: { [weak self] in self?.shouldAbort(current) ?? true })
        Log.info("tap start \(hotkey.displayName) for \(ime.name) (\(resolution.origin)\(choice)) -> \(outcome)")
        switch outcome {
        case let .started(latency):
            holdTrigger = .tapToggle
            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            holdStartedAt = ProcessInfo.processInfo.systemUptime - latency
            commitChecker.recordingStarted(target: target, ime: ime)
            startWatchdog()
            recordingNotified = true
            notify(true)
        case .notStarted:
            holdTrigger = .tapToggle
            pendingLateStart = (ime, target)
            setNotice("点按了「\(hotkey.displayName)」，但\(ime.name)没有开始录音（麦克风没有响应）。请确认\(ime.name)正在运行，并且它的语音输入快捷键就是「\(hotkey.displayName)」。")
            startWatchdog()
            let delay = session.lateStartWindow
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.settleUnconfirmedStart(of: ime, session: session) }
        case .micBusy:
            setNotice("麦克风正被其它应用占用，没有触发\(ime.name)。")
        case .realKeysHeld:
            setNotice("键盘上有按键没有松开，没有触发\(ime.name)。")
        case .aborted, .alreadyActive:
            break
        }
    }

    /// The user is holding the button while this runs. If the synthetic mouse-up cleared the
    /// HID button state, the real release would be dropped, so the state is restored first.
    /// Returns whether the watchdog can trust the HID button state.
    private func ensureButtonStillDown(at point: CGPoint, generation current: Int) -> Bool {
        usleep(30_000)
        if CGEventSource.buttonState(.hidSystemState, button: .left) { return true }
        guard !shouldAbort(current) else { return false }
        keySynth.restoreButtonDown(at: point)
        usleep(30_000)
        let restored = CGEventSource.buttonState(.hidSystemState, button: .left)
        Log.info("HID button state was cleared by the synthetic mouse-up; restore \(restored ? "succeeded" : "failed")")
        return restored
    }

    private func shouldAbort(_ current: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return endRequested || current != generation
    }

    private func end(reason: String) {
        stopWatchdog()
        if keySynth.heldHotkey != nil {
            keySynth.release()
        }
        endTapToggleSessions(reason: reason)
        pendingLateStart = nil
        guard recordingNotified else { return }
        recordingNotified = false
        let held = ProcessInfo.processInfo.systemUptime - holdStartedAt
        let what = holdTrigger == .hold ? "released hotkey" : "ended recording"
        Log.info(String(format: "%@ after %.2fs (%@)", what, held, reason))
        commitChecker.recordingEnded()
        notify(false)
    }

    /// Sends the stop tap of every tap-to-toggle recording that is still running.
    private func endTapToggleSessions(reason: String) {
        for (ime, session) in currentTapSessions() where session.needsStop {
            let outcome = session.stop(reason: reason)
            if outcome != .notRecording {
                Log.info("tap stop for \(ime.name) (\(reason)) -> \(outcome)")
            }
            switch outcome {
            case .stuck: noteStuck(ime)
            case .stopped, .endedByItself: notifyStuckChanged()
            case .notRecording: break
            }
        }
    }

    /// The late-start window of an unconfirmed tap start is over.
    private func settleUnconfirmedStart(of ime: VoiceIME, session: TapToggleSession) {
        guard session.state == .startUnconfirmed else { return }
        let outcome = session.settleUnconfirmedStart()
        Log.info("tap start for \(ime.name) never confirmed -> \(outcome)")
        if outcome == .stuck { noteStuck(ime) }
    }

    /// While the button is held: an unconfirmed start may have started after all.
    private func adoptLateStart() {
        guard let pending = pendingLateStart, tapSession(for: pending.ime).pollLateStart() else { return }
        pendingLateStart = nil
        Log.info("\(pending.ime.name) started recording late; keeping it until the mouse is released")
        holdStartedAt = ProcessInfo.processInfo.systemUptime
        commitChecker.recordingStarted(target: pending.target, ime: pending.ime)
        recordingNotified = true
        notify(true)
    }

    private func waitUntilCurrent(_ ime: VoiceIME, timeout: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if DispatchQueue.main.sync(execute: { InputSource.isCurrent(ime) }) { return }
            usleep(20_000)
        }
        Log.info("\(ime.id) did not become current within \(timeout)s")
    }

    private func startWatchdog() {
        stopWatchdog()
        releasedPolls = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private var isHolding: Bool {
        keySynth.heldHotkey != nil || currentTapSessions().contains { $0.session.needsStop }
    }

    /// The HID system state reflects the physical button, not the synthetic mouse-up we posted.
    private func watchdogTick() {
        adoptLateStart()
        guard isHolding else {
            end(reason: "hotkey already released")
            return
        }
        let physicallyDown = !watchButtonState || CGEventSource.buttonState(.hidSystemState, button: .left)
        releasedPolls = physicallyDown ? 0 : releasedPolls + 1
        let tooLong = ProcessInfo.processInfo.systemUptime - holdStartedAt > maxHoldDuration
        if releasedPolls >= 3 || tooLong {
            end(reason: tooLong ? "watchdog: max duration" : "watchdog: button is up")
            onWatchdogRelease?()
        }
    }

    private func notify(_ recording: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onRecordingChanged?(recording) }
    }

    // MARK: Tap-to-toggle sessions

    private func tapSession(for ime: VoiceIME) -> TapToggleSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let timing = settings.tapToggleTiming
        if let existing = tapSessions[ime.id], existing.needsStop || existing.timing == timing {
            return existing
        }
        let session = TapToggleSession(environment: LiveTapToggleEnvironment(ime: ime, keySynth: keySynth), timing: timing)
        tapSessions[ime.id] = session
        return session
    }

    private func currentTapSessions() -> [(ime: VoiceIME, session: TapToggleSession)] {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return tapSessions.compactMap { id, session in VoiceIME.withID(id).map { (ime: $0, session: session) } }
    }

    private func setNotice(_ text: String) {
        stateLock.lock()
        notice = (text, Date())
        stateLock.unlock()
    }

    private func noteStuck(_ ime: VoiceIME) {
        setNotice("\(ime.name)的录音没能自动结束，请在\(ime.name)里手动结束它（点按一次它的语音快捷键）。")
        DispatchQueue.main.async { [weak self] in
            NSSound.beep()
            self?.onStuckChanged?()
        }
    }

    private func notifyStuckChanged() {
        DispatchQueue.main.async { [weak self] in self?.onStuckChanged?() }
    }
}
