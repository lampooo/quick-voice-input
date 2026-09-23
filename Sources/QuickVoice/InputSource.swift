import Carbon
import Foundation

/// Text Input Source helpers for WeType. Call from the main thread.
enum InputSource {
    static let weTypeSourceID = "com.tencent.inputmethod.wetype.pinyin"
    static let weTypeBundleID = "com.tencent.inputmethod.wetype"

    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(source, kTISPropertyInputSourceID)
    }

    static var isWeTypeCurrent: Bool { currentSourceID() == weTypeSourceID }

    static func weTypeSource(includeAllInstalled: Bool) -> TISInputSource? {
        source(withID: weTypeSourceID, includeAllInstalled: includeAllInstalled)
    }

    static var isWeTypeEnabled: Bool { weTypeSource(includeAllInstalled: false) != nil }

    /// Selects WeType if it is not already the current input source. Returns false on failure.
    @discardableResult
    static func selectWeType() -> Bool {
        if isWeTypeCurrent { return true }
        guard let source = weTypeSource(includeAllInstalled: false) else {
            Log.info("WeType input source is not enabled")
            return false
        }
        let status = TISSelectInputSource(source)
        Log.info("TISSelectInputSource(WeType) -> \(status)")
        return status == noErr
    }

    /// Adds WeType to the enabled input sources (user-initiated from the setup guide).
    @discardableResult
    static func enableWeType() -> Bool {
        guard let source = weTypeSource(includeAllInstalled: true) else { return false }
        return TISEnableInputSource(source) == noErr
    }

    @discardableResult
    static func select(sourceID: String) -> Bool {
        guard let source = source(withID: sourceID, includeAllInstalled: false) else { return false }
        return TISSelectInputSource(source) == noErr
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
