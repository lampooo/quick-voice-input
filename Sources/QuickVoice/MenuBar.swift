import AppKit
import QuickVoiceCore

/// Status-bar icon and menu. The menu is rebuilt every time it opens so it always shows the
/// current permission, input method and per-app state.
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
        let statuses = IMEStatus.inspectAll()
        let selection = VoiceTarget.select(settings: settings)

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
        if let blockItem = blockToggleItem() {
            menu.addItem(blockItem)
        }
        menu.addItem(.separator())

        if trusted {
            menu.addItem(info("辅助功能权限：已授权"))
        } else {
            menu.addItem(item("辅助功能权限：未授权，点此去授权…", #selector(requestAccessibility)))
        }
        menu.addItem(voiceIMEMenu(selection: selection, statuses: statuses))
        let installed = statuses.filter(\.isInstalled)
        for status in installed {
            let current = status.isCurrent ? "（当前输入法）" : ""
            menu.addItem(info("\(status.ime.name) \(status.version ?? "")：\(status.ime.pushToTalkName) = \(status.pushToTalkDescription)\(current)"))
            for warning in warnings(for: status, statuses: statuses) {
                menu.addItem(info("    ⚠️ " + warning))
            }
        }
        if installed.isEmpty {
            menu.addItem(info("未检测到" + VoiceIME.all.map(\.name).joined(separator: "或")))
        }
        menu.addItem(.separator())

        menu.addItem(holdDurationMenu())
        menu.addItem(hotkeyMenu(statuses: statuses, selection: selection))
        let autoSwitch = item("触发前自动切换输入法", #selector(toggleAutoSwitch))
        autoSwitch.toolTip = "当前输入法不是要用的语音输入法时，开始前先切过去"
        autoSwitch.state = settings.autoSwitchInputSource ? .on : .off
        menu.addItem(autoSwitch)
        menu.addItem(appRuleMenu())
        let blockedCount = settings.blockedBundleIDs.count
        menu.addItem(item(blockedCount > 0 ? "管理屏蔽的软件（\(blockedCount) 个）…" : "管理屏蔽的软件…", #selector(showBlocklist)))
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

    /// Problems with the hotkey this app would hold for an input method, short enough for menu items.
    private func warnings(for status: IMEStatus, statuses: [IMEStatus]) -> [String] {
        let resolution = status.resolution(for: settings)
        var result: [String] = []
        if let reason = resolution.fallbackReason {
            result.append(reason)
        } else if status.pushToTalkMatches(resolution.hotkey) == false {
            result.append("与这里选的「\(resolution.hotkey.displayName)」不一致")
        }
        if !resolution.hotkey.risks.isEmpty {
            result.append("快捷键含普通键，可能打出字符，建议改用\(status.ime.defaultHotkey.displayName)")
        }
        result += statuses.conflicts(holding: resolution.hotkey, for: status.ime).map(\.summary)
        return result
    }

    private func voiceIMEMenu(selection: VoiceIMESelection, statuses: [IMEStatus]) -> NSMenuItem {
        let title: String
        switch settings.voiceIME {
        case .automatic: title = "语音输入法：自动（现在用\(selection.ime.name)）"
        case let .fixed(ime): title = "语音输入法：\(ime.name)"
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for choice in VoiceIMEChoice.all {
            var label = choice.title
            if case let .fixed(ime) = choice, !statuses.status(of: ime).isInstalled {
                label += "（未安装）"
            }
            let entry = item(label, #selector(chooseVoiceIME(_:)))
            entry.representedObject = choice.storedValue
            entry.state = choice == settings.voiceIME ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func hotkeyMenu(statuses: [IMEStatus], selection: VoiceIMESelection) -> NSMenuItem {
        let current = settings.resolvedHotkey(for: selection.ime)
        let parent = NSMenuItem(title: "语音快捷键：\(current.hotkey.displayName)（\(selection.ime.name)）", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for ime in settings.hotkeyIMEs(statuses: statuses) {
            let status = statuses.status(of: ime)
            let resolution = status.resolution(for: settings)
            let entry = NSMenuItem(title: "\(ime.name)：\(resolution.hotkey.displayName)", action: nil, keyEquivalent: "")
            entry.submenu = imeHotkeyMenu(ime: ime, resolution: resolution)
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let test = item("测试\(selection.ime.name)的语音快捷键…", #selector(runHotkeyTest(_:)))
        test.representedObject = selection.ime.id
        test.isEnabled = Permissions.isAccessibilityTrusted
        submenu.addItem(test)
        parent.submenu = submenu
        return parent
    }

    private func imeHotkeyMenu(ime: VoiceIME, resolution: HotkeyResolution) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let setting = settings.hotkeySetting(for: ime)
        let following = setting.source == .followIME
        let followTitle = resolution.followsIME
            ? "跟随\(ime.name)（当前：\(resolution.hotkey.displayName)）"
            : "跟随\(ime.name)（暂时用：\(resolution.hotkey.displayName)）"
        let follow = item(followTitle, #selector(followIME(_:)))
        follow.representedObject = ime.id
        follow.state = following ? .on : .off
        follow.toolTip = resolution.fallbackReason
        menu.addItem(follow)
        menu.addItem(.separator())
        menu.addItem(info("手动指定"))
        for preset in HotkeyPreset.all {
            let entry = item(preset.title(for: ime), #selector(chooseHotkey(_:)))
            entry.representedObject = [ime.id, preset.id]
            entry.toolTip = preset.note
            entry.state = !following && preset.hotkey == setting.manual ? .on : .off
            menu.addItem(entry)
        }
        if HotkeyPreset.matching(setting.manual) == nil {
            let custom = item("自定义：\(setting.manual.displayName)", #selector(chooseCustomHotkey(_:)))
            custom.representedObject = ime.id
            custom.state = following ? .off : .on
            menu.addItem(custom)
        }
        let record = item("录制快捷键…", #selector(recordHotkey(_:)))
        record.representedObject = ime.id
        menu.addItem(record)
        return menu
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

    /// 「在〈当前软件〉中屏蔽」: the same `.never` rule as 「不触发（屏蔽）」 in the submenu above.
    private func blockToggleItem() -> NSMenuItem? {
        guard let target = menuTargetApp, let bundleID = target.bundleIdentifier else { return nil }
        let name = target.localizedName ?? bundleID
        guard AppRules.canChangeRule(for: bundleID) else {
            return info("「\(name)」中始终不触发")
        }
        let blocked = settings.isBlocked(bundleID)
        let entry = item(blocked ? "在「\(name)」中取消屏蔽" : "在「\(name)」中屏蔽", #selector(toggleBlockCurrentApp(_:)))
        entry.representedObject = bundleID
        entry.image = target.icon.map { Self.menuIcon($0) }
        return entry
    }

    static func menuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    // MARK: Actions

    @objc private func toggleBlockCurrentApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if settings.isBlocked(bundleID) {
            settings.unblock(bundleID)
        } else {
            settings.block(bundleID)
        }
        Log.info("\(settings.isBlocked(bundleID) ? "blocked" : "unblocked") \(bundleID)")
    }

    @objc private func showBlocklist() {
        app.showSetup(step: .blocklist)
    }

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

    @objc private func chooseVoiceIME(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        settings.voiceIME = VoiceIMEChoice(storedValue: value)
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let ime = VoiceIME.withID(pair[0]),
              let preset = HotkeyPreset.all.first(where: { $0.id == pair[1] }) else { return }
        settings.useManualHotkey(preset.hotkey, for: ime)
    }

    @objc private func followIME(_ sender: NSMenuItem) {
        guard let ime = (sender.representedObject as? String).flatMap(VoiceIME.withID) else { return }
        settings.setHotkeySource(.followIME, for: ime)
    }

    @objc private func chooseCustomHotkey(_ sender: NSMenuItem) {
        guard let ime = (sender.representedObject as? String).flatMap(VoiceIME.withID) else { return }
        settings.setHotkeySource(.manual, for: ime)
    }

    @objc private func recordHotkey(_ sender: NSMenuItem) {
        let ime = (sender.representedObject as? String).flatMap(VoiceIME.withID)
        app.showSetup(step: .hotkey, startRecording: true, ime: ime)
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

    @objc private func runHotkeyTest(_ sender: NSMenuItem) {
        let ime = (sender.representedObject as? String).flatMap(VoiceIME.withID)
        app.showSetup(step: .hotkey, autoRunTest: true, ime: ime)
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
