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

        let weType = WeTypeStatus.inspect()
        if let url = weType.appURL {
            lines.append("微信输入法：\(weType.version ?? "?")，位置 \(url.path)")
            lines.append("  已添加到输入法列表：\(weType.isEnabled ? "是" : "否")；当前输入法：\(InputSource.currentSourceID() ?? "?")")
            if let voice = weType.voice {
                if let ptt = voice.pushToTalk {
                    let state = ptt.enabled == false ? "（已关闭）" : ""
                    let synth = ptt.hotkey == nil ? "程序无法模拟" : "程序可以模拟"
                    lines.append("  按住说话：\(ptt.displayName)\(state)，键码 \(ptt.keyCodes)，\(synth)")
                } else {
                    lines.append("  按住说话：设置文件里没有记录（可能是默认的 Fn）")
                }
                if let toggle = voice.toggle {
                    lines.append("  启动语音输入：\(toggle.displayName)\(toggle.enabled == false ? "（已关闭）" : "")，键码 \(toggle.keyCodes)")
                }
            } else {
                lines.append("  语音快捷键：无法读取（\(weType.settingsError ?? "未知原因")）")
            }
        } else {
            lines.append("微信输入法：未安装")
        }

        let settings = AppSettings.shared
        lines.append("本应用：\(settings.enabled ? "已启用" : "已暂停")，长按 \(settings.holdDuration) 秒，按住「\(settings.hotkey.displayName)」，自动切换输入法：\(settings.autoSwitchInputSource ? "开" : "关")")
        switch weType.pushToTalkMatches(settings.hotkey) {
        case .some(true): lines.append("  与微信输入法的「按住说话」一致")
        case .some(false): lines.append("  ⚠️ 与微信输入法的「按住说话」不一致")
        case .none: lines.append("  无法判断是否与微信输入法一致")
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

        lines.append("键盘事件监听：" + keyboardTapSummary())
        return lines.joined(separator: "\n")
    }

    private static func keyboardTapSummary() -> String {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return "无法读取" }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return "无法读取" }
        let keyMask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let weTypeTaps = taps.prefix(Int(count)).filter { tap in
            tap.eventsOfInterest & keyMask != 0 && NSRunningApplication(processIdentifier: tap.tappingProcess)?.bundleIdentifier == InputSource.weTypeBundleID
        }
        guard let tap = weTypeTaps.first else { return "没有发现微信输入法的快捷键监听（它可能在用 NSEvent 备用模式）" }
        let point = tap.tapPoint == .cghidEventTap ? "HID 层" : "会话层"
        let mode = tap.options == .listenOnly ? "只监听" : "可拦截"
        return "微信输入法在\(point)监听按键（\(mode)，\(tap.enabled ? "已启用" : "已停用")）"
    }
}
