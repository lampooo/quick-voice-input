import Foundation

/// Per-app behavior for long presses. Blocking an app ("屏蔽") is the `.never` rule; there is
/// no separate block list, so the two can never disagree.
public enum AppRule: String, Codable, CaseIterable, Sendable {
    /// Only when the pointer is over an editable text field (detected via Accessibility).
    case auto
    /// Any long press in this app starts voice input.
    case anywhere
    /// Never trigger in this app, and do not look at it at all.
    case never

    public var title: String {
        switch self {
        case .auto: return "自动识别输入框"
        case .anywhere: return "任意位置都触发"
        case .never: return "不触发（屏蔽）"
        }
    }
}

public enum AppRules {
    /// Terminals rarely expose an editable text element through Accessibility, so a long
    /// press anywhere in them is treated as "in the input field" unless the user overrides it.
    public static let builtInDefaults: [String: AppRule] = [
        "com.apple.Terminal": .anywhere,
        "com.googlecode.iterm2": .anywhere,
        "dev.warp.Warp-Stable": .anywhere,
        "net.kovidgoyal.kitty": .anywhere,
        "com.mitchellh.ghostty": .anywhere,
        "org.alacritty": .anywhere,
        "io.alacritty": .anywhere,
        "co.zeit.hyper": .anywhere,
        "com.github.wez.wezterm": .anywhere,
    ]

    /// Bundles where a long press must never start voice input; the user cannot change these.
    public static let alwaysExcluded: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.SecurityAgent",
        "com.tencent.inputmethod.wetype",
    ]

    /// `overrides` holds only what the user changed, keyed by bundle ID.
    public static func rule(for bundleID: String?, overrides: [String: AppRule]) -> AppRule {
        guard let bundleID else { return .auto }
        if alwaysExcluded.contains(bundleID) { return .never }
        return overrides[bundleID] ?? defaultRule(for: bundleID)
    }

    public static func defaultRule(for bundleID: String) -> AppRule {
        if alwaysExcluded.contains(bundleID) { return .never }
        return builtInDefaults[bundleID] ?? .auto
    }

    public static func canChangeRule(for bundleID: String) -> Bool {
        !alwaysExcluded.contains(bundleID)
    }

    /// Applies `rule`, storing nothing when it equals the app's default.
    public static func setting(_ rule: AppRule, for bundleID: String, in overrides: [String: AppRule]) -> [String: AppRule] {
        guard canChangeRule(for: bundleID) else { return overrides }
        var result = overrides
        if rule == defaultRule(for: bundleID) {
            result.removeValue(forKey: bundleID)
        } else {
            result[bundleID] = rule
        }
        return result
    }

    public static func isBlocked(_ bundleID: String?, overrides: [String: AppRule]) -> Bool {
        rule(for: bundleID, overrides: overrides) == .never
    }

    public static func blocking(_ bundleID: String, in overrides: [String: AppRule]) -> [String: AppRule] {
        setting(.never, for: bundleID, in: overrides)
    }

    /// Unblocking returns the app to its default rule (terminals go back to 「任意位置都触发」).
    public static func unblocking(_ bundleID: String, in overrides: [String: AppRule]) -> [String: AppRule] {
        guard overrides[bundleID] == .never else { return overrides }
        return setting(defaultRule(for: bundleID), for: bundleID, in: overrides)
    }

    /// Apps the user blocked, sorted for display.
    public static func blockedBundleIDs(in overrides: [String: AppRule]) -> [String] {
        overrides.filter { $0.value == .never }.keys.sorted()
    }

    /// Whether the event tap may track a press in this app at all. Unknown apps are allowed;
    /// the probe decides once it knows the target.
    public static func allowsLongPress(bundleID: String?, overrides: [String: AppRule]) -> Bool {
        !isBlocked(bundleID, overrides: overrides)
    }
}
