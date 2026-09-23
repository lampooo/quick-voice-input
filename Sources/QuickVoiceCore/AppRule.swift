import Foundation

/// Per-app behavior for long presses.
public enum AppRule: String, Codable, CaseIterable, Sendable {
    /// Only when the pointer is over an editable text field (detected via Accessibility).
    case auto
    /// Any long press in this app starts voice input.
    case anywhere
    /// Never trigger in this app.
    case never

    public var title: String {
        switch self {
        case .auto: return "自动识别输入框"
        case .anywhere: return "任意位置都触发"
        case .never: return "不触发"
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

    /// Bundles where a long press must never start voice input.
    public static let alwaysExcluded: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.SecurityAgent",
        "com.tencent.inputmethod.wetype",
    ]

    public static func rule(for bundleID: String?, overrides: [String: AppRule]) -> AppRule {
        guard let bundleID else { return .auto }
        if alwaysExcluded.contains(bundleID) { return .never }
        return overrides[bundleID] ?? builtInDefaults[bundleID] ?? .auto
    }
}
