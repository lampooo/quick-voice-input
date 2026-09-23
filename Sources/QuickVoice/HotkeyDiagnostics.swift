import AppKit
import CoreAudio
import QuickVoiceCore

/// 「测试语音快捷键」: holds each candidate key in turn while our own test field is focused and
/// watches the microphone to see which one makes WeType start (and stop) recording.
final class HotkeyDiagnostics: ObservableObject {
    struct Candidate: Identifiable, Equatable {
        var id: String { hotkey.displayName }
        let title: String
        let hotkey: Hotkey
        var outcome: HotkeyTestOutcome?
        var isTesting = false
    }

    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var isRunning = false
    @Published private(set) var progress: String?
    @Published private(set) var summary: String?
    @Published private(set) var suggestion: Candidate?

    /// Focuses / clears the test field that WeType types into during the test.
    var focusTestField: (() -> Void)?
    var clearTestField: (() -> Void)?

    private let settings: AppSettings
    private let keySynth = KeySynth()
    private let queue = DispatchQueue(label: "quickvoice.diagnostics", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var cancelled = false

    private let startTimeout: TimeInterval = 2.0
    private let stopTimeout: TimeInterval = 2.5

    init(settings: AppSettings) {
        self.settings = settings
    }

    static func buildCandidates(current: Hotkey, weType: WeTypeStatus) -> [Candidate] {
        var list: [Candidate] = []
        func add(_ hotkey: Hotkey, _ title: String) {
            guard hotkey.isValid, !list.contains(where: { $0.hotkey == hotkey }) else { return }
            list.append(Candidate(title: title, hotkey: hotkey))
        }
        add(current, "当前设置：" + (HotkeyPreset.matching(current)?.title ?? current.displayName))
        if let weTypeHotkey = weType.voice?.pushToTalk?.hotkey {
            add(weTypeHotkey, "微信输入法当前的「按住说话」：\(weTypeHotkey.displayName)")
        }
        // Right Shift toggles WeType between Chinese and English, so it is only tested when chosen.
        for preset in HotkeyPreset.all where preset.id != HotkeyPreset.rightShift.id {
            add(preset.hotkey, preset.title)
        }
        return list
    }

    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
        keySynth.release()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    /// Main thread. Runs the whole test; results are published as they come in.
    func run() {
        guard !isRunning else { return }
        summary = nil
        suggestion = nil
        let weType = WeTypeStatus.inspect()
        candidates = Self.buildCandidates(current: settings.hotkey, weType: weType)

        guard Permissions.isAccessibilityTrusted else {
            summary = "需要先授予「辅助功能」权限，快捷语音输入才能替你按键。"
            return
        }
        guard weType.isInstalled else {
            summary = "没有找到微信输入法。请先安装微信输入法 Mac 版。"
            return
        }
        guard weType.isEnabled else {
            summary = "微信输入法还没有添加到输入法列表。请先在「系统设置 → 键盘 → 输入法」里添加它。"
            return
        }
        guard let device = MicMonitor.defaultInputDevice() else {
            summary = "没有找到可用的麦克风，无法判断是否开始录音。"
            return
        }

        cancelLock.lock()
        cancelled = false
        cancelLock.unlock()
        isRunning = true
        progress = "准备中…"
        let secureInput = Permissions.isSecureInputActive
        let previousSource = InputSource.currentSourceID()
        focusTestField?()
        InputSource.selectWeType()
        Log.info("hotkey test started, mic=\(MicMonitor.name(of: device)), secureInput=\(secureInput)")

        let list = candidates
        queue.async { [weak self] in
            self?.runTests(list, previousSource: previousSource, secureInput: secureInput)
        }
    }

    private func runTests(_ list: [Candidate], previousSource: String?, secureInput: Bool) {
        usleep(500_000)
        for (index, candidate) in list.enumerated() {
            if isCancelled { break }
            onMain {
                self.candidates[index].isTesting = true
                self.progress = "正在测试「\(candidate.hotkey.displayName)」（\(index + 1)/\(list.count)），请不要操作键盘和鼠标…"
                self.focusTestField?()
                InputSource.selectWeType()
            }
            usleep(300_000)
            let outcome = test(candidate.hotkey)
            Log.info("hotkey test \(candidate.hotkey.displayName): \(outcome)")
            onMain {
                self.candidates[index].outcome = outcome
                self.candidates[index].isTesting = false
                self.clearTestField?()
            }
            usleep(900_000)
        }
        keySynth.release()
        onMain {
            if let previousSource, previousSource != InputSource.weTypeSourceID {
                InputSource.select(sourceID: previousSource)
            }
            self.finish(secureInput: secureInput)
        }
    }

    private func test(_ hotkey: Hotkey) -> HotkeyTestOutcome {
        let baseline = MicMonitor.runningInputs()
        if let device = MicMonitor.defaultInputDevice(), baseline.contains(device) {
            return .micBusy
        }
        let pressedAt = ProcessInfo.processInfo.systemUptime
        keySynth.press(hotkey)
        var latency: TimeInterval?
        while ProcessInfo.processInfo.systemUptime - pressedAt < startTimeout, !isCancelled {
            if micStarted(since: baseline) {
                latency = ProcessInfo.processInfo.systemUptime - pressedAt
                break
            }
            usleep(40_000)
        }
        guard let latency else {
            keySynth.release()
            return isCancelled ? .skipped("测试已取消") : .noResponse
        }
        usleep(400_000)
        keySynth.release()
        let stopped = waitForStop(since: baseline)
        if !stopped {
            // A 「启动语音输入」 key keeps recording; press it again (then Esc) to end the session.
            keySynth.tap(hotkey)
            if !waitForStop(since: baseline) {
                keySynth.tap(Hotkey(modifiers: [], key: 53))
                _ = waitForStop(since: baseline)
            }
        }
        return HotkeyTestOutcome.evaluate(micBusyBefore: false, startLatency: latency, stoppedAfterRelease: stopped)
    }

    private func micStarted(since baseline: Set<AudioObjectID>) -> Bool {
        let running = MicMonitor.runningInputs()
        if let device = MicMonitor.defaultInputDevice(), running.contains(device) { return true }
        return !running.subtracting(baseline).isEmpty
    }

    private func waitForStop(since baseline: Set<AudioObjectID>) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + stopTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !micStarted(since: baseline) { return true }
            usleep(50_000)
        }
        return false
    }

    private func finish(secureInput: Bool) {
        isRunning = false
        progress = nil
        let current = settings.hotkey
        let working = candidates.filter { $0.outcome?.isPushToTalk == true }
        var lines: [String] = []
        if working.contains(where: { $0.hotkey == current }) {
            lines.append("✅ 当前快捷键「\(current.displayName)」可以正常触发微信输入法的「按住说话」，可以开始使用了。")
        } else if let first = working.first {
            suggestion = first
            lines.append("「\(first.hotkey.displayName)」可以触发「按住说话」，但和当前设置「\(current.displayName)」不一样。点下面的按钮改用它。")
        } else if let toggle = candidates.first(where: { if case .toggle = $0.outcome { return true } else { return false } }) {
            lines.append("「\(toggle.hotkey.displayName)」是微信输入法的「启动语音输入」快捷键（按一下开始、再按结束），不适合长按。请在微信输入法设置里把「按住说话」改成「右 Option」后重新测试。")
        } else if candidates.contains(where: { $0.outcome == .micBusy }) {
            lines.append("测试时麦克风被其它应用占用，结果不可靠。请关闭正在使用麦克风的应用（会议、录音软件等）后重新测试。")
        } else {
            lines.append("没有候选键能触发微信输入法录音。请打开微信输入法设置 → 语音 → 「按住说话」，把快捷键改成「右 Option」，再重新测试。")
        }
        if secureInput {
            lines.append("⚠️ 检测到有应用开启了「安全输入」（例如密码框，或终端的「安全键盘输入」），这会让微信输入法收不到快捷键。")
        }
        summary = lines.joined(separator: "\n")
    }

    func adoptSuggestion() {
        guard let suggestion else { return }
        settings.hotkey = suggestion.hotkey
        summary = "已改用「\(suggestion.hotkey.displayName)」。"
        self.suggestion = nil
    }

    private func onMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
