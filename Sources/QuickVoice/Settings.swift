import Combine
import Foundation
import QuickVoiceCore

/// User preferences, persisted in UserDefaults. UI code uses the published properties on the
/// main thread; the event-tap and probe threads read `snapshot`, which is lock protected.
final class AppSettings: ObservableObject {
    struct Snapshot {
        var enabled: Bool
        var holdDuration: TimeInterval
        var hotkey: Hotkey
        var autoSwitchInputSource: Bool
        var appRules: [String: AppRule]
    }

    static let shared = AppSettings()

    private enum Key {
        static let enabled = "enabled"
        static let holdDuration = "holdDuration"
        static let hotkey = "hotkey"
        static let autoSwitchInputSource = "autoSwitchInputSource"
        static let appRules = "appRules"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedSnapshot: Snapshot

    @Published var enabled: Bool { didSet { persist(Key.enabled, enabled) } }
    @Published var holdDuration: TimeInterval { didSet { persist(Key.holdDuration, holdDuration) } }
    @Published var hotkey: Hotkey { didSet { persistJSON(Key.hotkey, hotkey) } }
    @Published var autoSwitchInputSource: Bool { didSet { persist(Key.autoSwitchInputSource, autoSwitchInputSource) } }
    @Published var appRules: [String: AppRule] { didSet { persistJSON(Key.appRules, appRules) } }
    @Published var hasCompletedOnboarding: Bool { didSet { persist(Key.hasCompletedOnboarding, hasCompletedOnboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        let storedDuration = defaults.object(forKey: Key.holdDuration) as? Double ?? 0.5
        let holdDuration = LongPressConfig.holdDurationChoices.contains(storedDuration) ? storedDuration : 0.5
        let hotkey = Self.decode(Hotkey.self, defaults.data(forKey: Key.hotkey)).flatMap { $0.isValid ? $0 : nil }
            ?? HotkeyPreset.recommended.hotkey
        let autoSwitch = defaults.object(forKey: Key.autoSwitchInputSource) as? Bool ?? true
        let rules = Self.decode([String: AppRule].self, defaults.data(forKey: Key.appRules)) ?? [:]

        self.enabled = enabled
        self.holdDuration = holdDuration
        self.hotkey = hotkey
        self.autoSwitchInputSource = autoSwitch
        self.appRules = rules
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        cachedSnapshot = Snapshot(enabled: enabled, holdDuration: holdDuration, hotkey: hotkey, autoSwitchInputSource: autoSwitch, appRules: rules)
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return cachedSnapshot
    }

    func rule(for bundleID: String?) -> AppRule {
        AppRules.rule(for: bundleID, overrides: snapshot.appRules)
    }

    func setRule(_ rule: AppRule, for bundleID: String) {
        var rules = appRules
        if rule == AppRules.rule(for: bundleID, overrides: [:]) {
            rules.removeValue(forKey: bundleID)
        } else {
            rules[bundleID] = rule
        }
        appRules = rules
    }

    private func refreshSnapshot() {
        lock.lock()
        cachedSnapshot = Snapshot(enabled: enabled, holdDuration: holdDuration, hotkey: hotkey, autoSwitchInputSource: autoSwitchInputSource, appRules: appRules)
        lock.unlock()
    }

    private func persist(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
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
