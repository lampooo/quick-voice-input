import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import QuickVoiceCore

/// The real keyboard, microphone and clock behind a `TapToggleSession`. Nothing in here waits for
/// the main thread, so a session can run while the app is quitting.
final class LiveTapToggleEnvironment: TapToggleEnvironment {
    /// UserDefaults key that says a recording may be running for the engine, so a launch after a
    /// crash or kill can end it.
    static func activeMarkerKey(for ime: VoiceIME) -> String { "tapToggleActive.\(ime.id)" }

    private let ime: VoiceIME
    private let keySynth: KeySynth
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var baseline = Set<AudioObjectID>()

    init(ime: VoiceIME, keySynth: KeySynth, defaults: UserDefaults = .standard) {
        self.ime = ime
        self.keySynth = keySynth
        self.defaults = defaults
    }

    static func hasActiveMarker(for ime: VoiceIME, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: activeMarkerKey(for: ime))
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(_ seconds: TimeInterval) {
        usleep(useconds_t(max(0, seconds) * 1_000_000))
    }

    func captureMicBaseline() -> Bool {
        let running = MicMonitor.runningInputs()
        lock.lock()
        baseline = running
        lock.unlock()
        guard let device = MicMonitor.defaultInputDevice() else { return false }
        return running.contains(device)
    }

    func micActive() -> Bool {
        let running = MicMonitor.runningInputs()
        if let device = MicMonitor.defaultInputDevice(), running.contains(device) { return true }
        lock.lock()
        let known = baseline
        lock.unlock()
        return !running.subtracting(known).isEmpty
    }

    /// The HID state holds the physical keyboard (and what this app posted at the HID level), so a
    /// key that is down for real shows up here. A key it has reported down for longer than
    /// `HeldKeyTracker.defaultStaleAfter` is a stale entry and does not count.
    func realInputIdle() -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let busy: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        if !flags.intersection(busy).isEmpty { return false }
        return HeldKeyMonitor.shared.heldKeys().isEmpty
    }

    func tap(_ hotkey: Hotkey, holdFor seconds: TimeInterval) {
        keySynth.tap(hotkey, holdFor: seconds)
    }

    func modifiersClean(after hotkey: Hotkey) -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let ours = hotkey.modifiers.reduce(CGEventFlags()) { $0.union(CGEventFlags(rawValue: $1.genericFlag)) }
        if !flags.intersection(ours).isEmpty { return false }
        return !hotkey.keyCodes.contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
    }

    func forceRelease(_ hotkey: Hotkey) {
        keySynth.forceRelease(hotkey)
    }

    func persist(active: Bool) {
        defaults.set(active, forKey: Self.activeMarkerKey(for: ime))
    }

    func log(_ message: String) {
        Log.info("[\(ime.id)] \(message)")
    }
}

extension VoiceIME {
    /// A standalone app swallows the ordinary key in its own shortcut. When it is not running
    /// nobody does, and a tap would reach the focused app, so nothing is tapped.
    var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
