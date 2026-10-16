import AppKit
import Carbon
import CoreGraphics
import QuickVoiceCore

/// Posts synthetic keyboard events at the HID tap, so event taps installed by the input method
/// (WeType uses an active HID-level tap) see them like hardware input.
final class KeySynth {
    /// Written into `eventSourceUserData` so our own event tap can recognize what we posted.
    static let syntheticMarker: Int64 = 0x5156_4F49

    private let source: CGEventSource?
    private let lock = NSLock()
    private var held: Hotkey?
    private let strokeGap: useconds_t = 8_000
    private let repeatQueue = DispatchQueue(label: "quickvoice.keyrepeat", qos: .userInteractive)
    private var repeatTimer: DispatchSourceTimer?
    private let repeatDelay: TimeInterval
    private let repeatInterval: TimeInterval

    init() {
        source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        source?.userData = Self.syntheticMarker
        repeatDelay = max(0.15, NSEvent.keyRepeatDelay)
        repeatInterval = min(max(0.03, NSEvent.keyRepeatInterval), 0.2)
    }

    var heldHotkey: Hotkey? {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// Presses and keeps holding the hotkey. Releases any previously held hotkey first.
    func press(_ hotkey: Hotkey) {
        lock.lock()
        defer { lock.unlock() }
        stopRepeating()
        if let previous = held {
            post(previous.releaseSequence)
        }
        post(hotkey.pressSequence)
        held = hotkey
        if let key = hotkey.key {
            startRepeating(key: key, flags: hotkey.pressSequence.last?.flags ?? 0)
        }
    }

    /// Releases the held hotkey. Safe to call when nothing is held.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        stopRepeating()
        guard let hotkey = held else { return }
        post(hotkey.releaseSequence)
        held = nil
    }

    func tap(_ hotkey: Hotkey, holdFor seconds: TimeInterval = 0.08) {
        press(hotkey)
        usleep(useconds_t(seconds * 1_000_000))
        release()
    }

    /// Posts the release events of `hotkey` again, without touching what this object thinks is held.
    func forceRelease(_ hotkey: Hotkey) {
        lock.lock()
        defer { lock.unlock() }
        post(hotkey.releaseSequence)
    }

    /// Ends the target app's mouse-tracking loop without the user releasing the button. Posted at
    /// the session level: a HID-level mouse-up would also mark the button as released in the
    /// HID state, and the window server would then drop the real mouse-up.
    func postMouseUp(at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.flags = []
        event.post(tap: .cgSessionEventTap)
    }

    /// Marks the left button as pressed again in the HID state after a synthetic mouse-up
    /// cleared it, so the real release produces a mouse-up. Our own event tap swallows it.
    func restoreButtonDown(at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    /// A physically held ordinary key auto-repeats; input methods may treat a key that never
    /// repeats as stale, so chords such as ⌥ + Space repeat like hardware does.
    private func startRepeating(key: UInt16, flags: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: repeatQueue)
        timer.schedule(deadline: .now() + repeatDelay, repeating: repeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.held?.key == key else { return }
            self.post([KeyStroke(.keyDown, keyCode: key, flags: flags)], autorepeat: true)
        }
        repeatTimer = timer
        timer.resume()
    }

    private func stopRepeating() {
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    private func post(_ strokes: [KeyStroke], autorepeat: Bool = false) {
        let keyboardType = Int64(LMGetKbdType())
        for stroke in strokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: stroke.kind != .keyUp) else { continue }
            if stroke.kind == .flagsChanged {
                event.type = .flagsChanged
            }
            event.flags = CGEventFlags(rawValue: stroke.flags)
            event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
            if !autorepeat { usleep(strokeGap) }
        }
    }
}
