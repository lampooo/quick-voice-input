import AppKit
import QuickVoiceCore

/// Reads WeType's settings file (read-only). The file is read on every call, so a changed shortcut
/// applies to the very next long press, and it is re-parsed only when its bytes changed. The
/// modification date is not used: MMKV writes through a memory map, and the system updates the
/// date only some time after the content changed. Safe on any thread.
final class WeTypeConfigCache {
    static let shared = WeTypeConfigCache()

    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(WeTypeVoiceConfig.settingsRelativePath)
    private let lock = NSLock()
    private var cachedData: Data?
    private var cached: Result<WeTypeVoiceConfig, Error>?

    func current() -> WeTypeVoiceConfig? {
        try? load().get()
    }

    func load() -> Result<WeTypeVoiceConfig, Error> {
        // A plain read, not a memory map: WeType may resize the file while we look at it.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(error)
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached, data == cachedData { return cached }
        let result = Result { WeTypeVoiceConfig.parse(try MMKVReader.parse(data)) }
        cached = result
        cachedData = data
        return result
    }
}

/// Read-only view of the local WeType installation and its voice shortcut settings.
struct WeTypeStatus: Equatable {
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
        // Read Info.plist directly: Bundle caches it, and WeType updates itself in the background.
        if let url = status.appURL,
           let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] {
            let short = info["CFBundleShortVersionString"] as? String
            let build = info["CFBundleVersion"] as? String
            status.version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined()
        }
        status.isEnabled = InputSource.isWeTypeEnabled
        status.isCurrent = InputSource.isWeTypeCurrent

        let cache = WeTypeConfigCache.shared
        if manager.isReadableFile(atPath: cache.url.path) {
            switch cache.load() {
            case let .success(config): status.voice = config
            case let .failure(error): status.settingsError = "\(error)"
            }
        } else if status.isInstalled {
            status.settingsError = "找不到设置文件"
        }
        return status
    }

    /// The hotkey this app will hold for the given settings, as the menu and setup guide show it.
    func resolution(for settings: AppSettings) -> HotkeyResolution {
        HotkeyResolver.resolve(source: settings.hotkeySource, manual: settings.hotkey, weType: voice)
    }

    func openSettingsApp() {
        guard let url = settingsAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
