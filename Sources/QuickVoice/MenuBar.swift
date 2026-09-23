import AppKit
import QuickVoiceCore

/// Status-bar icon and menu. The menu is rebuilt every time it opens so it always shows the
/// current permission, WeType and per-app state.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: AppSettings
    private unowned let app: AppDelegate
    private var isRecording = false
    private var menuTargetApp: NSRunningApplication?

    init(settings: AppSettings, app: AppDelegate) {
        self.settings = settings
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        refreshIcon()
    }

    func refreshIcon() {
        let symbol: String
        let tooltip: String
        if !Permissions.isAccessibilityTrusted {
            symbol = "exclamationmark.triangle"
            tooltip = "快捷语音输入：需要辅助功能权限"
        } else if isRecording {
            symbol = "mic.fill"
            tooltip = "快捷语音输入：正在听写，松开鼠标结束"
        } else if !settings.enabled {
            symbol = "mic.slash"
            tooltip = "快捷语音输入：已暂停"
        } else {
            symbol = "mic"
            tooltip = "快捷语音输入：在输入框里长按鼠标开始说话"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication
        menuTargetApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        menu.removeAllItems()
        build(menu)
    }

    private func build(_ menu: NSMenu) {
        let trusted = Permissions.isAccessibilityTrusted
        let weType = WeTypeStatus.inspect()

        menu.addItem(header("快捷语音输入"))
        let status: String
        if !trusted {
            status = "需要辅助功能权限才能工作"
        } else if !settings.enabled {
            status = "已暂停"
        } else {
            status = String(format: "在输入框里长按鼠标 %.1f 秒开始说话", settings.holdDuration)
        }
        menu.addItem(info(status))

        let toggle = item(settings.enabled ? "暂停长按语音输入" : "启用长按语音输入", #selector(toggleEnabled), key: "e")
        toggle.isEnabled = trusted
        menu.addItem(toggle)
        menu.addItem(.separator())

        if trusted {
            menu.addItem(info("辅助功能权限：已授权"))
        } else {
            menu.addItem(item("辅助功能权限：未授权，点此去授权…", #selector(requestAccessibility)))
        }
        let resolution = weType.resolution(for: settings)
        if weType.isInstalled {
            menu.addItem(info("微信输入法 \(weType.version ?? "")：按住说话 = \(weType.pushToTalkDescription)"))
            if let reason = resolution.fallbackReason {
                menu.addItem(info("⚠️ " + reason))
            } else if weType.pushToTalkMatches(resolution.hotkey) == false {
                menu.addItem(info("⚠️ 与这里选的「\(resolution.hotkey.displayName)」不一致"))
            }
        } else {
            menu.addItem(info("未检测到微信输入法"))
        }
        if !resolution.hotkey.risks.isEmpty {
            menu.addItem(info("⚠️ 当前快捷键含普通键，可能打出字符，建议改用右 Option"))
        }
        menu.addItem(.separator())

        menu.addItem(holdDurationMenu())
        menu.addItem(hotkeyMenu(resolution: resolution, weType: weType))
        let autoSwitch = item("触发前自动切到微信输入法", #selector(toggleAutoSwitch))
        autoSwitch.state = settings.autoSwitchInputSource ? .on : .off
        menu.addItem(autoSwitch)
        menu.addItem(appRuleMenu())
        menu.addItem(.separator())

        let login = item("开机自动启动", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : (LaunchAtLogin.needsApproval ? .mixed : .off)
        menu.addItem(login)
        menu.addItem(item("设置向导…", #selector(showSetup)))
        menu.addItem(item("打开日志文件夹", #selector(openLogs)))
        menu.addItem(.separator())
        menu.addItem(item("退出快捷语音输入", #selector(quit), key: "q"))
    }

    private func holdDurationMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "长按时长", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for duration in LongPressConfig.holdDurationChoices {
            let entry = item(String(format: "%.1f 秒", duration), #selector(chooseHoldDuration(_:)))
            entry.representedObject = duration
            entry.state = abs(duration - settings.holdDuration) < 0.001 ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func hotkeyMenu(resolution: HotkeyResolution, weType: WeTypeStatus) -> NSMenuItem {
        let parent = NSMenuItem(title: "语音快捷键：\(resolution.hotkey.displayName)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let following = settings.hotkeySource == .followWeType
        let followTitle = resolution.followsWeType
            ? "跟随微信输入法（当前：\(resolution.hotkey.displayName)）"
            : "跟随微信输入法（暂时用：\(resolution.hotkey.displayName)）"
        let follow = item(followTitle, #selector(followWeType))
        follow.state = following ? .on : .off
        follow.toolTip = resolution.fallbackReason
        submenu.addItem(follow)
        submenu.addItem(.separator())
        submenu.addItem(info("手动指定"))
        let manual = settings.hotkey
        for preset in HotkeyPreset.all {
            let entry = item(preset.title, #selector(chooseHotkey(_:)))
            entry.representedObject = preset.id
            entry.toolTip = preset.note
            entry.state = !following && preset.hotkey == manual ? .on : .off
            submenu.addItem(entry)
        }
        if HotkeyPreset.matching(manual) == nil {
            let custom = item("自定义：\(manual.displayName)", #selector(chooseCustomHotkey))
            custom.state = following ? .off : .on
            submenu.addItem(custom)
        }
        submenu.addItem(item("录制快捷键…", #selector(recordHotkey)))
        submenu.addItem(.separator())
        let test = item("测试语音快捷键…", #selector(runHotkeyTest))
        test.isEnabled = Permissions.isAccessibilityTrusted
        submenu.addItem(test)
        parent.submenu = submenu
        return parent
    }

    private func appRuleMenu() -> NSMenuItem {
        guard let target = menuTargetApp, let bundleID = target.bundleIdentifier else {
            let placeholder = info("当前应用：无")
            return placeholder
        }
        let name = target.localizedName ?? bundleID
        let parent = NSMenuItem(title: "在「\(name)」中", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let rule = settings.rule(for: bundleID)
        let excluded = AppRules.alwaysExcluded.contains(bundleID)
        for option in AppRule.allCases {
            let entry = item(option.title, #selector(chooseRule(_:)))
            entry.representedObject = [bundleID, option.rawValue]
            entry.state = option == rule ? .on : .off
            entry.isEnabled = !excluded
            submenu.addItem(entry)
        }
        if AppRules.builtInDefaults[bundleID] != nil {
            submenu.addItem(.separator())
            submenu.addItem(info("终端类应用默认「任意位置都触发」"))
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        app.enabledDidChange()
        refreshIcon()
    }

    @objc private func requestAccessibility() {
        Permissions.requestAccessibility()
        app.showSetup(step: .permission)
    }

    @objc private func chooseHoldDuration(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Double else { return }
        settings.holdDuration = duration
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let preset = HotkeyPreset.all.first(where: { $0.id == id }) else { return }
        settings.useManualHotkey(preset.hotkey)
    }

    @objc private func followWeType() {
        settings.hotkeySource = .followWeType
    }

    @objc private func chooseCustomHotkey() {
        settings.hotkeySource = .manual
    }

    @objc private func recordHotkey() {
        app.showSetup(step: .hotkey, startRecording: true)
    }

    @objc private func toggleAutoSwitch() {
        settings.autoSwitchInputSource.toggle()
    }

    @objc private func chooseRule(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, let rule = AppRule(rawValue: pair[1]) else { return }
        settings.setRule(rule, for: pair[0])
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    @objc private func showSetup() {
        app.showSetup(step: nil)
    }

    @objc private func runHotkeyTest() {
        app.showSetup(step: .hotkey, autoRunTest: true)
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Log.directory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = info(title)
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        return item
    }
}
