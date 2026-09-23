import AppKit
import Combine
import QuickVoiceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    private let keySynth = KeySynth()
    private lazy var probe = TextFieldProbe(settings: settings)
    private lazy var voice = VoiceController(settings: settings, keySynth: keySynth)
    private lazy var tap = EventTap(settings: settings, probe: probe, keySynth: keySynth)
    private lazy var diagnostics = HotkeyDiagnostics(settings: settings)
    private var menuBar: MenuBarController?
    private var setupWindow: SetupWindowController?
    private var permissionTimer: Timer?
    private var lastTrusted = false
    private var nextTapAttempt: TimeInterval = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launch \(Bundle.main.bundleIdentifier ?? "?") \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        NSApp.mainMenu = Self.makeMainMenu()
        menuBar = MenuBarController(settings: settings, app: self)

        tap.delegate = voice
        tap.onTapInvalidated = { [weak self] in self?.restartTap() }
        voice.onRecordingChanged = { [weak self] recording in self?.menuBar?.setRecording(recording) }
        voice.onWatchdogRelease = { [weak self] in self?.tap.resetPress() }

        settings.$hotkey.dropFirst().sink { [weak self] _ in
            self?.voice.releaseNow(reason: "hotkey changed")
        }.store(in: &cancellables)

        installSignalHandlers()
        lastTrusted = Permissions.isAccessibilityTrusted
        if lastTrusted {
            startTap()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkPermission()
        }

        if !settings.hasCompletedOnboarding || !lastTrusted {
            showSetup(step: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup(step: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown(reason: "quit")
    }

    func showSetup(step: SetupStep?, autoRunTest: Bool = false) {
        if setupWindow == nil {
            setupWindow = SetupWindowController(model: SetupModel(settings: settings, diagnostics: diagnostics))
        }
        setupWindow?.show(step: step, autoRunTest: autoRunTest)
    }

    func enabledDidChange() {
        if !settings.enabled {
            tap.resetPress()
            voice.releaseNow(reason: "paused")
        }
    }

    private func startTap() {
        if !tap.start() {
            nextTapAttempt = ProcessInfo.processInfo.systemUptime + 10
            Log.info("could not start event tap; will retry")
        }
        menuBar?.refreshIcon()
    }

    private func restartTap() {
        tap.stop()
        voice.releaseNow(reason: "tap restarted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, Permissions.isAccessibilityTrusted else { return }
            self.startTap()
        }
    }

    private func checkPermission() {
        let trusted = Permissions.isAccessibilityTrusted
        if trusted != lastTrusted {
            Log.info("accessibility trusted: \(trusted)")
            lastTrusted = trusted
            if trusted {
                startTap()
            } else {
                tap.stop()
                voice.releaseNow(reason: "permission revoked")
            }
            menuBar?.refreshIcon()
        } else if trusted, !tap.isRunning, ProcessInfo.processInfo.systemUptime >= nextTapAttempt {
            startTap()
        }
    }

    private func shutdown(reason: String) {
        diagnostics.cancel()
        voice.releaseNow(reason: reason)
        keySynth.release()
        tap.stop()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown(reason: "signal \(sig)")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Accessory apps have no visible menu bar, but the Edit menu still provides ⌘C/⌘V/⌘A in text fields.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出快捷语音输入", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}
