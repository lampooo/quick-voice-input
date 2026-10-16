import AppKit
import CoreGraphics
import QuickVoiceCore

/// `QuickVoice --self-check`: read-only report for troubleshooting. Posts no events, opens no windows.
enum SelfCheck {
    static func run() -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        lines.append("快捷语音输入 \(version)（\(Bundle.main.bundleIdentifier ?? "未打包")）")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let fromTerminal = getppid() != 1
        lines.append("辅助功能权限：\(Permissions.isAccessibilityTrusted ? "已授权" : "未授权")" + (fromTerminal ? "（从终端运行时，这里反映的是终端本身的权限）" : ""))
        lines.append("安全输入：\(Permissions.isSecureInputActive ? "有应用开启了安全输入（快捷键可能收不到）" : "未开启")")
        lines.append("当前输入法：\(InputSource.currentSourceID() ?? "?")")

        let statuses = IMEStatus.inspectAll()
        for status in statuses {
            lines.append(contentsOf: describe(status))
        }

        let settings = AppSettings.shared
        let selection = VoiceTarget.select(settings: settings)
        lines.append("本应用：\(settings.enabled ? "已启用" : "已暂停")，长按 \(settings.holdDuration) 秒，语音输入法：\(settings.voiceIME.title)，自动切换输入法：\(settings.autoSwitchInputSource ? "开" : "关")")
        lines.append("  现在长按会用：\(selection.ime.name)（\(selection.explanation)）")
        for ime in settings.hotkeyIMEs(statuses: statuses) {
            let status = statuses.status(of: ime)
            let setting = settings.hotkeySetting(for: ime)
            let resolution = status.resolution(for: settings)
            let source = setting.source == .followIME ? "跟随\(ime.name)" : "手动指定（\(setting.manual.displayName)）"
            lines.append("  \(ime.name)：快捷键来源 \(source)，长按时按住 \(resolution.hotkey.displayName)" + (resolution.fallbackReason.map { "（\($0)）" } ?? ""))
            switch status.shortcutMatches(resolution.hotkey) {
            case .some(true): lines.append("    与\(ime.name)的「\(ime.shortcutName)」一致")
            case .some(false): lines.append("    ⚠️ 与\(ime.name)的「\(ime.shortcutName)」不一致")
            case .none: lines.append("    无法判断是否与\(ime.name)一致")
            }
            if ime.trigger == .tapToggle {
                lines.append("    触发方式：点按一次开始、松开鼠标再点按一次结束；点按约 \(Int(settings.tapToggleTiming.tapHold * 1000)) 毫秒，两次点按至少隔 \(settings.tapToggleTiming.minInterval) 秒，前后用麦克风状态确认")
                if LiveTapToggleEnvironment.hasActiveMarker(for: ime) {
                    lines.append("    ⚠️ 上次运行留下了「录音可能还在进行」的标记；本应用下次启动（有辅助功能权限时）会确认麦克风并结束它")
                }
            }
            for risk in resolution.hotkey.risks {
                lines.append("    ⚠️ " + risk.message)
            }
            for conflict in statuses.conflicts(holding: resolution.hotkey, for: ime) {
                lines.append("    ⚠️ " + conflict.message)
            }
        }
        if !settings.appRules.isEmpty {
            lines.append("  应用规则：" + settings.appRules.map { "\($0.key)=\($0.value.title)" }.sorted().joined(separator: "，"))
        }

        if let device = MicMonitor.defaultInputDevice() {
            lines.append("默认麦克风：\(MicMonitor.name(of: device))，\(MicMonitor.isRunningSomewhere(device) ? "正在录音" : "空闲")")
        } else {
            lines.append("默认麦克风：没有")
        }
        let others = MicMonitor.inputDevices().filter { $0 != MicMonitor.defaultInputDevice() }
        if !others.isEmpty {
            lines.append("其它输入设备：" + others.map { MicMonitor.name(of: $0) + (MicMonitor.isRunningSomewhere($0) ? "（录音中）" : "") }.joined(separator: "，"))
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ status: IMEStatus) -> [String] {
        let ime = status.ime
        guard let url = status.appURL else { return ["\(ime.name)：未安装"] }
        var lines = ["\(ime.name)：\(status.version ?? "?")，位置 \(url.path)"]
        if ime.isStandalone {
            lines.append("  独立 App：没有输入源，不需要添加到输入法列表，也不会切换输入法；在任何输入法下都响应")
        } else {
            lines.append("  已添加到输入法列表：\(status.isEnabled ? "是" : "否")；是当前输入法：\(status.isCurrent ? "是" : "否")")
        }
        if let voice = status.voice {
            if ime.trigger == .hold {
                if let ptt = voice.pushToTalk {
                    let state = ptt.enabled == false ? "（已关闭）" : ""
                    let synth = ptt.hotkey == nil ? "程序无法模拟" : "程序可以模拟"
                    lines.append("  \(ime.pushToTalkName)：\(ptt.displayName)\(state)，键码 \(ptt.keyCodes)，\(synth)")
                } else {
                    lines.append("  \(ime.pushToTalkName)：设置文件里没有记录（可能是默认的 Fn）")
                }
            }
            if let toggle = voice.toggle {
                let synth = ime.trigger == .tapToggle ? (toggle.hotkey == nil ? "，程序无法模拟" : "，程序可以模拟") : ""
                lines.append("  \(ime.toggleName)：\(toggle.displayName)\(toggle.enabled == false ? "（已关闭）" : "")，键码 \(toggle.keyCodes)\(synth)")
            } else if ime.trigger == .tapToggle {
                lines.append("  \(ime.toggleName)：设置文件里没有记录（可能是默认的 Fn）")
            }
            if voice.commandSelectsCandidates == true {
                lines.append("  已开启「用左右 Command 选候选词」")
            }
            if voice.worksInOtherInputMethods == true {
                lines.append("  已开启「全局唤起语音」（在其它输入法里也响应语音快捷键）")
            }
        } else {
            lines.append("  语音快捷键：无法读取（\(status.settingsError ?? "未知原因")）")
        }
        lines.append("  键盘事件监听：" + keyboardTapSummary(for: ime))
        return lines
    }

    private static func keyboardTapSummary(for ime: VoiceIME) -> String {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return "无法读取" }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return "无法读取" }
        let keyMask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let imeTaps = taps.prefix(Int(count)).filter { tap in
            guard tap.eventsOfInterest & keyMask != 0,
                  let bundleID = NSRunningApplication(processIdentifier: tap.tappingProcess)?.bundleIdentifier else { return false }
            return ime.bundleIDs.contains(bundleID)
        }
        guard let tap = imeTaps.first else {
            return ime.isStandalone
                ? "没有发现事件监听（它可能没有在运行，或没有授予它辅助功能/输入监控权限）"
                : "没有发现事件监听（它在自己是当前输入法时，通过系统输入法接口接收按键）"
        }
        let point = tap.tapPoint == .cghidEventTap ? " HID 层" : "会话层"
        let mode = tap.options == .listenOnly ? "只监听" : "可拦截"
        return "在\(point)监听按键（\(mode)，\(tap.enabled ? "已启用" : "已停用")）"
    }
}
