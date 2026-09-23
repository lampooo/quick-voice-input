import Carbon
import CoreGraphics
import Foundation
import QuickVoiceCore

/// Posts synthetic keyboard and mouse events at the HID tap, so event taps installed by the
/// input method (WeType uses an active HID-level tap) see them like hardware input.
final class KeySynth {
    /// Written into `eventSourceUserData` so our own event tap can recognize what we posted.
    static let syntheticMarker: Int64 = 0x5156_4F49

    private let source: CGEventSource?
    private let lock = NSLock()
    private var held: Hotkey?
    private let strokeGap: useconds_t = 8_000

    init() {
        source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        source?.userData = Self.syntheticMarker
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
        if let previous = held {
            post(previous.releaseSequence)
        }
        post(hotkey.pressSequence)
        held = hotkey
    }

    /// Releases the held hotkey. Safe to call when nothing is held.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let hotkey = held else { return }
        post(hotkey.releaseSequence)
        held = nil
    }

    func tap(_ hotkey: Hotkey, holdFor seconds: TimeInterval = 0.08) {
        press(hotkey)
        usleep(useconds_t(seconds * 1_000_000))
        release()
    }

    /// Ends the target app's mouse-tracking loop without the user releasing the button.
    func postMouseUp(at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func post(_ strokes: [KeyStroke]) {
        let keyboardType = Int64(LMGetKbdType())
        for stroke in strokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: stroke.kind != .keyUp) else { continue }
            if stroke.kind == .flagsChanged {
                event.type = .flagsChanged
            }
            event.flags = CGEventFlags(rawValue: stroke.flags)
            event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
            usleep(strokeGap)
        }
    }
}
