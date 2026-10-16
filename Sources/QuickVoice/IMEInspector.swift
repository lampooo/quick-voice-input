import AppKit
import QuickVoiceCore

/// Reads input methods' settings files (read-only). A file is read on every call, so a changed
/// shortcut applies to the very next long press, and it is re-parsed only when its bytes changed.
/// The modification date is not used: MMKV writes through a memory map, and the system updates
/// the date only some time after the content changed. Safe on any thread.
final class IMEConfigCache {
    static let shared = IMEConfigCache()

    private struct Entry {
        var data: Data
        var result: Result<IMEVoiceConfig, Error>
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func url(for ime: VoiceIME) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(ime.settingsFilePath)
    }

    func config(for ime: VoiceIME) -> IMEVoiceConfig? {
        try? load(ime).get()
    }

    func load(_ ime: VoiceIME) -> Result<IMEVoiceConfig, Error> {
        var result = loadOnce(ime)
        // A JSON store is rewritten in one go; a read that lands in the middle of it is cut off.
        // Reading again a moment later gets the finished file.
        if case .failure = result, ime.settingsFormat == .bageshuoJSON {
            for _ in 0..<2 {
                guard case let .failure(error) = result, (error as? CocoaError)?.code != .fileReadNoSuchFile else { break }
                usleep(40_000)
                result = loadOnce(ime)
            }
        }
        return result
    }

    private func loadOnce(_ ime: VoiceIME) -> Result<IMEVoiceConfig, Error> {
        // A plain read, not a memory map: the input method may resize the file while we look at it.
        let data: Data
        do {
            data = try Data(contentsOf: url(for: ime))
        } catch {
            return .failure(error)
        }
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[ime.id], entry.data == data { return entry.result }
        let result = Result { try IMEVoiceConfig.parse(data, format: ime.settingsFormat) }
        entries[ime.id] = Entry(data: data, result: result)
        return result
    }
}

/// Read-only view of one input method's installation and voice shortcut settings.
struct IMEStatus: Equatable, Identifiable {
    let ime: VoiceIME
    var appURL: URL?
    var version: String?
    var isEnabled = false
    var isCurrent = false
    var voice: IMEVoiceConfig?
    var settingsError: String?

    var id: String { ime.id }
    var isInstalled: Bool { appURL != nil }
    var isUsable: Bool { isInstalled && isEnabled }

    /// The app that has the voice shortcut settings: the input method's settings app, or the
    /// standalone app itself.
    var settingsAppURL: URL? {
        guard let appURL else { return nil }
        return ime.settingsAppPath.map { appURL.appendingPathComponent($0) } ?? appURL
    }

    /// The shortcut this app drives for the engine: its hold-to-talk or its single tap-to-toggle one.
    var shortcut: VoiceShortcut? { voice?.shortcut(for: ime.trigger) }

    /// Short description of the shortcut this app drives, for menus and the setup guide.
    var shortcutDescription: String {
        guard isInstalled else { return "未安装" }
        guard let shortcut else {
            return settingsError == nil ? "未读取到（可能仍是默认的 Fn）" : "无法读取设置"
        }
        if shortcut.enabled == false { return "\(shortcut.displayName)（已关闭）" }
        return shortcut.displayName
    }

    func shortcutMatches(_ hotkey: Hotkey) -> Bool? {
        guard let shortcut, shortcut.tapCount <= 1, shortcut.unsynthesizableName == nil else { return nil }
        return hotkey.matches(keyCodes: shortcut.keyCodes)
    }

    var versionAdvice: String? {
        version.flatMap(ime.versionAdvice)
    }

    static func appURL(of ime: VoiceIME) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ime.installPaths
            .map { URL(fileURLWithPath: $0.hasPrefix("~/") ? home + $0.dropFirst() : $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Must be called on the main thread (Text Input Sources).
    static func inspect(_ ime: VoiceIME) -> IMEStatus {
        var status = IMEStatus(ime: ime)
        status.appURL = appURL(of: ime)
        // Read Info.plist directly: Bundle caches it, and input methods update themselves in the background.
        if let url = status.appURL,
           let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] {
            let short = info["CFBundleShortVersionString"] as? String
            let build = info["CFBundleVersion"] as? String
            status.version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined()
        }
        // A standalone app has no input source to add or switch to: installed is all it takes.
        status.isEnabled = ime.isStandalone ? status.isInstalled : InputSource.isEnabled(ime)
        status.isCurrent = InputSource.isCurrent(ime)
        switch IMEConfigCache.shared.load(ime) {
        case let .success(config):
            status.voice = config
        case let .failure(error):
            if status.isInstalled {
                status.settingsError = Self.describe(error)
            }
        }
        return status
    }

    private static func describe(_ error: Error) -> String {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return "找不到设置文件" }
        switch error as? BageshuoSettings.ReadError {
        case .notJSONObject: return "设置文件格式不对"
        case .noSettings: return "设置文件里没有快捷键设置"
        case nil: return "\(error)"
        }
    }

    static func inspectAll() -> [IMEStatus] {
        VoiceIME.all.map(inspect)
    }

    /// The hotkey this app will hold for this input method, as the menu and setup guide show it.
    func resolution(for settings: AppSettings) -> HotkeyResolution {
        HotkeyResolver.resolve(settings.hotkeySetting(for: ime), ime: ime, config: voice)
    }

    func openSettingsApp() {
        guard let url = settingsAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension Array where Element == IMEStatus {
    func status(of ime: VoiceIME) -> IMEStatus {
        first { $0.ime == ime } ?? IMEStatus(ime: ime)
    }

    var configs: [VoiceIME: IMEVoiceConfig] {
        var result: [VoiceIME: IMEVoiceConfig] = [:]
        for status in self {
            result[status.ime] = status.voice
        }
        return result
    }

    /// Why using `hotkey` for `ime` may not start its voice input.
    func conflicts(holding hotkey: Hotkey, for ime: VoiceIME) -> [IMEConflict] {
        IMEConflicts.find(hotkey: hotkey, ime: ime, configs: configs)
    }
}

extension AppSettings {
    /// The input methods whose hotkey the user sets up: the chosen one, or with 「自动」 every
    /// installed one (WeType when none is installed).
    func hotkeyIMEs(statuses: [IMEStatus]) -> [VoiceIME] {
        switch voiceIME {
        case let .fixed(ime):
            return [ime]
        case .automatic:
            let installed = statuses.filter(\.isInstalled).map(\.ime)
            return installed.isEmpty ? [VoiceIME.all[0]] : installed
        }
    }
}

/// Picks the input method for a recording from the 「语音输入法」 setting and the current input source.
enum VoiceTarget {
    /// Main thread (Text Input Sources).
    static func select(settings: AppSettings) -> VoiceIMESelection {
        let snapshot = settings.snapshot
        let environment = VoiceIMESelector.Environment(
            currentSourceID: InputSource.currentSourceID(),
            enabledIDs: Set(VoiceIME.all.filter { $0.isStandalone ? IMEStatus.appURL(of: $0) != nil : InputSource.isEnabled($0) }.map(\.id)),
            installedIDs: Set(VoiceIME.all.filter { IMEStatus.appURL(of: $0) != nil }.map(\.id)),
            lastUsedID: snapshot.lastVoiceIMEID
        )
        return VoiceIMESelector.select(snapshot.voiceIME, in: environment)
    }
}
