import AppKit
import QuickVoiceCore

/// Read-only view of the local WeType installation and its voice shortcut settings.
struct WeTypeStatus {
    var appURL: URL?
    var version: String?
    var isEnabled = false
    var isCurrent = false
    var voice: WeTypeVoiceConfig?
    var settingsError: String?

    var isInstalled: Bool { appURL != nil }

    var settingsAppURL: URL? {
        appURL?.appendingPathComponent("Contents/MacOS/WeTypeSettings.app")
    }

    /// Short description of WeType's 「按住说话」 shortcut for menus and the setup guide.
    var pushToTalkDescription: String {
        guard isInstalled else { return "未安装" }
        guard let shortcut = voice?.pushToTalk else {
            return settingsError == nil ? "未读取到（可能仍是默认的 Fn）" : "无法读取设置"
        }
        if shortcut.enabled == false { return "\(shortcut.displayName)（已关闭）" }
        return shortcut.displayName
    }

    func pushToTalkMatches(_ hotkey: Hotkey) -> Bool? {
        guard let shortcut = voice?.pushToTalk, shortcut.tapCount <= 1 else { return nil }
        return hotkey.matches(keyCodes: shortcut.keyCodes)
    }

    /// Must be called on the main thread (Text Input Sources).
    static func inspect() -> WeTypeStatus {
        var status = WeTypeStatus()
        let manager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Library/Input Methods/WeType.app"),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/WeType.app"),
        ]
        status.appURL = candidates.first { manager.fileExists(atPath: $0.path) }
        if let url = status.appURL, let info = Bundle(url: url)?.infoDictionary {
            let short = info["CFBundleShortVersionString"] as? String
            let build = info["CFBundleVersion"] as? String
            status.version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined()
        }
        status.isEnabled = InputSource.isWeTypeEnabled
        status.isCurrent = InputSource.isWeTypeCurrent

        let settingsURL = manager.homeDirectoryForCurrentUser.appendingPathComponent(WeTypeVoiceConfig.settingsRelativePath)
        if manager.isReadableFile(atPath: settingsURL.path) {
            do {
                status.voice = try WeTypeVoiceConfig.load(fromFile: settingsURL)
            } catch {
                status.settingsError = "\(error)"
            }
        } else if status.isInstalled {
            status.settingsError = "找不到设置文件"
        }
        return status
    }

    func openSettingsApp() {
        guard let url = settingsAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
