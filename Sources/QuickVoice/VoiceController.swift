import AppKit
import CoreGraphics
import Foundation
import QuickVoiceCore

/// Holds WeType's voice hotkey for the duration of a long press, on a serial queue so the
/// event tap never waits. A watchdog releases the key if the real mouse-up was missed.
final class VoiceController: EventTapDelegate {
    var onRecordingChanged: ((Bool) -> Void)?
    /// Called (on the voice queue) when the watchdog had to release the key by itself.
    var onWatchdogRelease: (() -> Void)?

    private let settings: AppSettings
    private let keySynth: KeySynth
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

    init(settings: AppSettings, keySynth: KeySynth) {
        self.settings = settings
        self.keySynth = keySynth
    }

    // MARK: EventTapDelegate

    func eventTapDidBeginRecording() {
        stateLock.lock()
        generation += 1
        let current = generation
        endRequested = false
        stateLock.unlock()
        queue.async { [weak self] in self?.begin(generation: current) }
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

    private func begin(generation current: Int) {
        let snapshot = settings.snapshot
        var settle: useconds_t = 60_000
        if snapshot.autoSwitchInputSource {
            let switched = DispatchQueue.main.sync { () -> Bool in
                if InputSource.isWeTypeCurrent { return false }
                return InputSource.selectWeType()
            }
            if switched {
                waitUntilWeTypeIsCurrent(timeout: 0.5)
                settle = 150_000
            }
        }
        usleep(settle)

        // The user is holding the button right now, so a "not pressed" reading means this
        // state query cannot be trusted and the watchdog must rely on the real mouse-up only.
        watchButtonState = CGEventSource.buttonState(.hidSystemState, button: .left)
        if !watchButtonState {
            Log.info("HID button state reads 'up' while holding; watchdog uses max duration only")
        }

        stateLock.lock()
        let abort = endRequested || current != generation
        if !abort { keySynth.press(snapshot.hotkey) }
        stateLock.unlock()
        guard !abort else {
            Log.info("released before the hotkey was pressed")
            return
        }

        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        holdStartedAt = ProcessInfo.processInfo.systemUptime
        Log.info("holding \(snapshot.hotkey.displayName)")
        startWatchdog()
        recordingNotified = true
        notify(true)
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
        notify(false)
    }

    private func waitUntilWeTypeIsCurrent(timeout: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if DispatchQueue.main.sync(execute: { InputSource.isWeTypeCurrent }) { return }
            usleep(20_000)
        }
        Log.info("WeType did not become current within \(timeout)s")
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
