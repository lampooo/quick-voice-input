import Foundation

/// An input method that does the speech recognition. Everything the app knows about one input
/// method lives in its descriptor: supporting another one means adding a descriptor to `all`,
/// plus a parser in `IMEVoiceConfig.parse` if it stores its settings in a new format.
public struct VoiceIME: Identifiable, Hashable, Sendable {
    /// Stable identifier, stored in this app's settings.
    public let id: String
    public let name: String
    public let bundleID: String
    /// Input sources that take voice input; the first enabled one is selected when switching.
    public let inputSourceIDs: [String]
    /// Possible install locations; `~` is the home directory.
    public let installPaths: [String]
    /// The settings app inside the input method's bundle.
    public let settingsAppPath: String
    /// The settings file, relative to the home directory.
    public let settingsFilePath: String
    public let settingsFormat: IMESettingsFormat
    /// The input method's other bundles, such as its settings app. Long presses never trigger
    /// there: a synthesized hotkey could land in a shortcut recorder and change the shortcut.
    public let helperBundleIDs: [String]
    /// UI name of the hold-to-talk shortcut.
    public let pushToTalkName: String
    /// UI name of the press-once shortcut.
    public let toggleName: String
    /// Recommended hotkey; held when the input method's own shortcut cannot be followed.
    public let defaultHotkey: Hotkey
    /// How to set the input method's hold-to-talk shortcut to `defaultHotkey`.
    public let setupSteps: [String]
    public let downloadURL: String
    /// A warning about the installed version, if any.
    public let versionAdvice: @Sendable (String) -> String?

    public static func == (lhs: VoiceIME, rhs: VoiceIME) -> Bool { lhs.id == rhs.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var bundleIDs: [String] { [bundleID] + helperBundleIDs }

    public func owns(sourceID: String?) -> Bool {
        guard let sourceID else { return false }
        return inputSourceIDs.contains(sourceID) || sourceID == bundleID || sourceID.hasPrefix(bundleID + ".")
    }
}

extension VoiceIME {
    public static let weType = VoiceIME(
        id: "wetype",
        name: "微信输入法",
        bundleID: "com.tencent.inputmethod.wetype",
        inputSourceIDs: ["com.tencent.inputmethod.wetype.pinyin"],
        installPaths: ["/Library/Input Methods/WeType.app", "~/Library/Input Methods/WeType.app"],
        settingsAppPath: "Contents/MacOS/WeTypeSettings.app",
        settingsFilePath: WeTypeSettings.relativePath,
        settingsFormat: .weTypeMMKV,
        helperBundleIDs: ["com.tencent.WeTypeSettings"],
        pushToTalkName: "按住说话",
        toggleName: "启动语音输入",
        defaultHotkey: Hotkey(modifiers: [.rightOption]),
        setupSteps: [
            "点「打开微信输入法设置」，进入「语音」相关设置。",
            "找到「按住说话」，点它的快捷键框，然后按一下键盘右侧的 Option（⌥）键。",
            "回到这里点「重新读取」。选的是「跟随微信输入法」的话，这里会自动跟着变。",
        ],
        downloadURL: "https://z.weixin.qq.com/",
        versionAdvice: { version in
            let numbers = version.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
            if numbers.lexicographicallyPrecedes([2, 2, 1]) {
                return "当前版本还不支持自定义语音快捷键，请先升级到 2.2.1 或更新版本。"
            }
            if numbers == [2, 2, 3] {
                return "有用户反馈 2.2.3 在终端里语音上屏异常；如果遇到，可以反馈给微信输入法或换用其它版本。"
            }
            return nil
        }
    )

    public static let doubao = VoiceIME(
        id: "doubao",
        name: "豆包输入法",
        bundleID: "com.bytedance.inputmethod.doubaoime",
        inputSourceIDs: ["com.bytedance.inputmethod.doubaoime.pinyin"],
        installPaths: ["/Library/Input Methods/DoubaoIme.app", "~/Library/Input Methods/DoubaoIme.app"],
        settingsAppPath: "Contents/Applications/DoubaoImeSettings.app",
        settingsFilePath: DoubaoSettings.relativePath,
        settingsFormat: .doubaoMMKV,
        helperBundleIDs: ["com.bytedance.inputmethod.doubaoime.settings"],
        pushToTalkName: "按住说话",
        toggleName: "按一次开始说话",
        defaultHotkey: Hotkey(modifiers: [.rightCommand]),
        setupSteps: [
            "点「打开豆包输入法设置」，找到「语音快捷键设置」。",
            "在「按住说话，松手结束」这一项点快捷键框，然后按一下键盘右侧的 Command（⌘）键。",
            "回到这里点「重新读取」。选的是「跟随豆包输入法」的话，这里会自动跟着变。",
        ],
        downloadURL: "https://ime.doubao.com/",
        versionAdvice: { _ in nil }
    )

    /// Supported input methods, in the order 「自动」 falls back to.
    public static let all: [VoiceIME] = [weType, doubao]

    public static func withID(_ id: String) -> VoiceIME? {
        all.first { $0.id == id }
    }

    public static func owning(sourceID: String?) -> VoiceIME? {
        all.first { $0.owns(sourceID: sourceID) }
    }
}

/// The 「语音输入法」 setting.
public enum VoiceIMEChoice: Hashable, Sendable {
    /// The current input method if it is supported; otherwise the most recently used one.
    case automatic
    case fixed(VoiceIME)

    public static let all: [VoiceIMEChoice] = [.automatic] + VoiceIME.all.map { .fixed($0) }

    public init(storedValue: String?) {
        self = storedValue.flatMap(VoiceIME.withID).map { .fixed($0) } ?? .automatic
    }

    public var storedValue: String {
        switch self {
        case .automatic: return "auto"
        case let .fixed(ime): return ime.id
        }
    }

    public var title: String {
        switch self {
        case .automatic: return "自动（跟随当前输入法）"
        case let .fixed(ime): return ime.name
        }
    }
}

public struct VoiceIMESelection: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case chosen, current, lastUsed, enabled, installed, fallback
    }

    public var ime: VoiceIME
    public var reason: Reason

    public init(ime: VoiceIME, reason: Reason) {
        self.ime = ime
        self.reason = reason
    }

    public var explanation: String {
        switch reason {
        case .chosen: return "你选定的"
        case .current: return "当前输入法"
        case .lastUsed: return "最近用过"
        case .enabled: return "已添加到输入法列表"
        case .installed: return "已安装"
        case .fallback: return "默认"
        }
    }
}

public enum VoiceIMESelector {
    public struct Environment: Equatable, Sendable {
        public var currentSourceID: String?
        public var enabledIDs: Set<String>
        public var installedIDs: Set<String>
        public var lastUsedID: String?

        public init(currentSourceID: String?, enabledIDs: Set<String>, installedIDs: Set<String>, lastUsedID: String?) {
            self.currentSourceID = currentSourceID
            self.enabledIDs = enabledIDs
            self.installedIDs = installedIDs
            self.lastUsedID = lastUsedID
        }
    }

    public static func select(_ choice: VoiceIMEChoice, in environment: Environment, from candidates: [VoiceIME] = VoiceIME.all) -> VoiceIMESelection {
        if case let .fixed(ime) = choice {
            return VoiceIMESelection(ime: ime, reason: .chosen)
        }
        if let current = candidates.first(where: { $0.owns(sourceID: environment.currentSourceID) }) {
            return VoiceIMESelection(ime: current, reason: .current)
        }
        if let last = candidates.first(where: { $0.id == environment.lastUsedID }), environment.enabledIDs.contains(last.id) {
            return VoiceIMESelection(ime: last, reason: .lastUsed)
        }
        if let enabled = candidates.first(where: { environment.enabledIDs.contains($0.id) }) {
            return VoiceIMESelection(ime: enabled, reason: .enabled)
        }
        if let installed = candidates.first(where: { environment.installedIDs.contains($0.id) }) {
            return VoiceIMESelection(ime: installed, reason: .installed)
        }
        return VoiceIMESelection(ime: candidates.first ?? .weType, reason: .fallback)
    }
}

/// A reason why holding a hotkey may not start hold-to-talk, judged from the input methods' settings.
public struct IMEConflict: Equatable, Sendable {
    /// Short enough for a menu item.
    public var summary: String
    public var detail: String

    public init(summary: String, detail: String) {
        self.summary = summary
        self.detail = detail
    }

    public var message: String { summary + "：" + detail }
}

public enum IMEConflicts {
    public static func find(hotkey: Hotkey, ime: VoiceIME, configs: [VoiceIME: IMEVoiceConfig]) -> [IMEConflict] {
        var result: [IMEConflict] = []
        let config = configs[ime]
        if let toggle = config?.toggle, toggle.enabled != false, toggle.hotkey == hotkey {
            result.append(IMEConflict(
                summary: "「\(hotkey.displayName)」也是\(ime.name)「\(ime.toggleName)」的快捷键",
                detail: "按住它会变成按一次开始、再按一次才结束"
            ))
        }
        if config?.commandSelectsCandidates == true, hotkey.modifiers.contains(where: { $0 == .leftCommand || $0 == .rightCommand }) {
            result.append(IMEConflict(
                summary: "\(ime.name)开启了「用左右 Command 选候选词」",
                detail: "屏幕上有候选词时，按 Command 会选词而不是开始说话"
            ))
        }
        for other in VoiceIME.all where other != ime {
            guard let otherConfig = configs[other], otherConfig.worksInOtherInputMethods == true else { continue }
            let shortcuts = [otherConfig.pushToTalk, otherConfig.toggle].compactMap { $0 }.filter { $0.enabled != false }
            if shortcuts.contains(where: { $0.hotkey == hotkey }) {
                result.append(IMEConflict(
                    summary: "\(other.name)开启了「全局唤起语音」，也在用「\(hotkey.displayName)」",
                    detail: "在\(ime.name)里按住它时，可能同时唤起\(other.name)"
                ))
            }
        }
        return result
    }
}
