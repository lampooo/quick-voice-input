import Carbon
import Foundation
import QuickVoiceCore

/// Text Input Source helpers. Call from the main thread.
enum InputSource {
    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(source, kTISPropertyInputSourceID)
    }

    static func isCurrent(_ ime: VoiceIME) -> Bool {
        ime.owns(sourceID: currentSourceID())
    }

    static func isEnabled(_ ime: VoiceIME) -> Bool {
        enabledSource(of: ime) != nil
    }

    /// Selects the input method's first enabled voice input source. Returns false on failure.
    @discardableResult
    static func select(_ ime: VoiceIME) -> Bool {
        if isCurrent(ime) { return true }
        guard let source = enabledSource(of: ime) else {
            Log.info("\(ime.id) input source is not enabled")
            return false
        }
        let status = TISSelectInputSource(source)
        Log.info("TISSelectInputSource(\(ime.id)) -> \(status)")
        return status == noErr
    }

    /// Adds the input method to the enabled input sources (user-initiated from the setup guide).
    @discardableResult
    static func enable(_ ime: VoiceIME) -> Bool {
        guard let id = ime.inputSourceIDs.first, let source = source(withID: id, includeAllInstalled: true) else { return false }
        return TISEnableInputSource(source) == noErr
    }

    @discardableResult
    static func select(sourceID: String) -> Bool {
        guard let source = source(withID: sourceID, includeAllInstalled: false) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func enabledSource(of ime: VoiceIME) -> TISInputSource? {
        for id in ime.inputSourceIDs {
            if let source = source(withID: id, includeAllInstalled: false) { return source }
        }
        return nil
    }

    private static func source(withID id: String, includeAllInstalled: Bool) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
