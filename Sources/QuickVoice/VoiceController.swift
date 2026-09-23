import AppKit
import CoreGraphics
import Foundation
import QuickVoiceCore

/// Holds the voice input method's hotkey for the duration of a long press, on a serial queue so
/// the event tap never waits. A watchdog releases the key if the real mouse-up was missed.
final class VoiceController: EventTapDelegate {
    var onRecordingChanged: ((Bool) -> Void)?
    /// Called (on the voice queue) when the watchdog had to release the key by itself.
    var onWatchdogRelease: (() -> Void)?

    private let settings: AppSettings
    private let keySynth: KeySynth
    private let commitChecker: CommitChecker
    private let queue = DispatchQueue(label: "quickvoice.voice", qos: .userInteractive)

    /// Guards `generation`/`endRequested` and makes "check, then press" atomic with `releaseNow`.
    private let stateLock = NSLock()
    private var generation = 0
    private var endRequested = false

    // Voice-queue state.
    private var watchdog: DispatchSourceTimer?
    private var releasedPolls = 0
    private var holdStartedAt: TimeInterval = 0
    private var recordingNotified = false
    private var watchButtonState = true
    private let maxHoldDuration: TimeInterval = 10 * 60

    init(settings: AppSettings, keySynth: KeySynth, commitChecker: CommitChecker) {
        self.settings = settings
        self.keySynth = keySynth
        self.commitChecker = commitChecker
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

    /// Releases the hotkey right away from any thread (quit, pause, signals).
    func releaseNow(reason: String) {
        stateLock.lock()
        endRequested = true
        stateLock.unlock()
        keySynth.release()
        queue.async { [weak self] in self?.end(reason: reason) }
    }

    // MARK: Voice queue

    private func begin(generation current: Int, at point: CGPoint, target: RecordingTarget?) {
        let snapshot = settings.snapshot
        watchButtonState = ensureButtonStillDown(at: point, generation: current)
        let selection = DispatchQueue.main.sync { VoiceTarget.select(settings: settings) }
        let ime = selection.ime
        var settle: useconds_t = 60_000
        if snapshot.autoSwitchInputSource {
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
        stateLock.lock()
        let abort = endRequested || current != generation
        if !abort { keySynth.press(resolution.hotkey) }
        stateLock.unlock()
        guard !abort else {
            Log.info("released before the hotkey was pressed")
            return
        }

        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        holdStartedAt = ProcessInfo.processInfo.systemUptime
        let choice = selection.reason == .chosen ? "" : "，自动：\(selection.explanation)"
        Log.info("holding hotkey \(resolution.hotkey.displayName) for \(ime.name) (\(resolution.origin)\(choice))")
        commitChecker.recordingStarted(target: target, ime: ime)
        startWatchdog()
        recordingNotified = true
        notify(true)
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
        guard recordingNotified else { return }
        recordingNotified = false
        let held = ProcessInfo.processInfo.systemUptime - holdStartedAt
        Log.info(String(format: "released hotkey after %.2fs (%@)", held, reason))
        commitChecker.recordingEnded()
        notify(false)
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

    /// The HID system state reflects the physical button, not the synthetic mouse-up we posted.
    private func watchdogTick() {
        guard keySynth.heldHotkey != nil else {
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
}
