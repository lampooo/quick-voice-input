import Combine
import Foundation
import QuickVoiceCore

/// User preferences, persisted in UserDefaults. UI code uses the published properties on the
/// main thread; the event-tap and probe threads read `snapshot`, which is lock protected.
final class AppSettings: ObservableObject {
    struct Snapshot {
        var enabled: Bool
        var holdDuration: TimeInterval
        var voiceIME: VoiceIMEChoice
        var imeHotkeys: [String: IMEHotkeySetting]
        var lastVoiceIMEID: String?
        var autoSwitchInputSource: Bool
        var appRules: [String: AppRule]

        func hotkeySetting(for ime: VoiceIME) -> IMEHotkeySetting {
            imeHotkeys[ime.id] ?? .standard(for: ime)
        }
    }

    static let shared = AppSettings()

    private enum Key {
        static let enabled = "enabled"
        static let holdDuration = "holdDuration"
        static let voiceIME = "voiceIME"
        static let imeHotkeys = "imeHotkeys"
        static let lastVoiceIME = "lastVoiceIME"
        static let autoSwitchInputSource = "autoSwitchInputSource"
        static let appRules = "appRules"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let tapHoldMs = "tapHoldMs"
        /// Written before the input method could be chosen; they describe WeType's hotkey.
        static let legacyHotkeySource = "hotkeySource"
        static let legacyHotkey = "hotkey"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedSnapshot: Snapshot

    @Published var enabled: Bool { didSet { persist(Key.enabled, enabled) } }
    @Published var holdDuration: TimeInterval { didSet { persist(Key.holdDuration, holdDuration) } }
    /// 「语音输入法」: which input method does the recognition.
    @Published var voiceIME: VoiceIMEChoice { didSet { persist(Key.voiceIME, voiceIME.storedValue) } }
    /// Per input method; missing entries mean 「跟随」 with the input method's recommended key.
    @Published private(set) var imeHotkeys: [String: IMEHotkeySetting] { didSet { persistJSON(Key.imeHotkeys, imeHotkeys) } }
    /// The supported input method that was selected most recently, for 「自动」.
    @Published private(set) var lastVoiceIMEID: String? { didSet { persist(Key.lastVoiceIME, lastVoiceIMEID) } }
    @Published var autoSwitchInputSource: Bool { didSet { persist(Key.autoSwitchInputSource, autoSwitchInputSource) } }
    @Published var appRules: [String: AppRule] { didSet { persistJSON(Key.appRules, appRules) } }
    @Published var hasCompletedOnboarding: Bool { didSet { persist(Key.hasCompletedOnboarding, hasCompletedOnboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        let storedDuration = defaults.object(forKey: Key.holdDuration) as? Double ?? 0.5
        let holdDuration = LongPressConfig.holdDurationChoices.contains(storedDuration) ? storedDuration : 0.5
        let voiceIME = VoiceIMEChoice(storedValue: defaults.string(forKey: Key.voiceIME))
        var hotkeys = (Self.decode([String: IMEHotkeySetting].self, defaults.data(forKey: Key.imeHotkeys)) ?? [:])
            .filter { $0.value.manual.isValid }
        if defaults.object(forKey: Key.imeHotkeys) == nil,
           let legacy = IMEHotkeySetting.migrated(
               legacySource: defaults.string(forKey: Key.legacyHotkeySource),
               legacyHotkey: Self.decode(Hotkey.self, defaults.data(forKey: Key.legacyHotkey))
           ) {
            hotkeys[VoiceIME.weType.id] = legacy
            if let data = try? JSONEncoder().encode(hotkeys) {
                defaults.set(data, forKey: Key.imeHotkeys)
            }
        }
        let lastUsed = defaults.string(forKey: Key.lastVoiceIME).flatMap(VoiceIME.withID)?.id
        let autoSwitch = defaults.object(forKey: Key.autoSwitchInputSource) as? Bool ?? true
        let rules = Self.decode([String: AppRule].self, defaults.data(forKey: Key.appRules)) ?? [:]

        self.enabled = enabled
        self.holdDuration = holdDuration
        self.voiceIME = voiceIME
        self.imeHotkeys = hotkeys
        self.lastVoiceIMEID = lastUsed
        self.autoSwitchInputSource = autoSwitch
        self.appRules = rules
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        cachedSnapshot = Snapshot(enabled: enabled, holdDuration: holdDuration, voiceIME: voiceIME, imeHotkeys: hotkeys,
                                  lastVoiceIMEID: lastUsed, autoSwitchInputSource: autoSwitch, appRules: rules)
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return cachedSnapshot
    }

    func hotkeySetting(for ime: VoiceIME) -> IMEHotkeySetting {
        snapshot.hotkeySetting(for: ime)
    }

    /// Timing of a tap to start and a tap to stop. Only `tapHoldMs` can be changed, without a UI:
    /// `defaults write com.quickvoiceinput.app tapHoldMs -int 150`.
    var tapToggleTiming: TapToggleTiming {
        let milliseconds = defaults.object(forKey: Key.tapHoldMs) as? Int
        return milliseconds.map { TapToggleTiming(tapHold: Double($0) / 1000) } ?? .standard
    }

    /// The hotkey to hold right now for `ime`; reads the input method's settings file. Safe on any thread.
    func resolvedHotkey(for ime: VoiceIME) -> HotkeyResolution {
        HotkeyResolver.resolve(hotkeySetting(for: ime), ime: ime, config: IMEConfigCache.shared.config(for: ime))
    }

    func setHotkeySource(_ source: HotkeySource, for ime: VoiceIME) {
        var setting = hotkeySetting(for: ime)
        setting.source = source
        imeHotkeys[ime.id] = setting
    }

    /// Switches `ime` to a manually chosen hotkey.
    func useManualHotkey(_ hotkey: Hotkey, for ime: VoiceIME) {
        imeHotkeys[ime.id] = IMEHotkeySetting(source: .manual, manual: hotkey)
    }

    /// Remembers the input method the user is typing with, for 「自动」. Main thread.
    func noteSelectedInputSource(_ sourceID: String?) {
        guard let ime = VoiceIME.owning(sourceID: sourceID), ime.id != lastVoiceIMEID else { return }
        lastVoiceIMEID = ime.id
    }

    func rule(for bundleID: String?) -> AppRule {
        AppRules.rule(for: bundleID, overrides: snapshot.appRules)
    }

    func setRule(_ rule: AppRule, for bundleID: String) {
        appRules = AppRules.setting(rule, for: bundleID, in: appRules)
    }

    // Blocking is the 「不触发」 rule in `appRules`; there is no second list to keep in sync.

    func isBlocked(_ bundleID: String) -> Bool {
        AppRules.isBlocked(bundleID, overrides: appRules)
    }

    func block(_ bundleID: String) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        appRules = AppRules.blocking(bundleID, in: appRules)
    }

    func unblock(_ bundleID: String) {
        appRules = AppRules.unblocking(bundleID, in: appRules)
    }

    var blockedBundleIDs: [String] {
        AppRules.blockedBundleIDs(in: appRules)
    }

    private func refreshSnapshot() {
        lock.lock()
        cachedSnapshot = Snapshot(enabled: enabled, holdDuration: holdDuration, voiceIME: voiceIME, imeHotkeys: imeHotkeys,
                                  lastVoiceIMEID: lastVoiceIMEID, autoSwitchInputSource: autoSwitchInputSource, appRules: appRules)
        lock.unlock()
    }

    private func persist(_ key: String, _ value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        refreshSnapshot()
    }

    private func persistJSON<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
        refreshSnapshot()
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
