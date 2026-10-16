import AppKit
import CoreAudio
import QuickVoiceCore

/// 「测试语音快捷键」: holds each candidate key in turn while our own test field is focused and
/// watches the microphone to see which one makes the input method start (and stop) recording.
final class HotkeyDiagnostics: ObservableObject {
    struct Candidate: Identifiable, Equatable {
        var id: String { hotkey.displayName }
        let title: String
        let hotkey: Hotkey
        var outcome: HotkeyTestOutcome?
        var isTesting = false
        /// The outcome came from running the test, not from ruling the key out beforehand.
        var wasTried = false
    }

    /// The input method the candidates were tested with.
    @Published private(set) var ime: VoiceIME?
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var isRunning = false
    @Published private(set) var progress: String?
    @Published private(set) var summary: String?
    @Published private(set) var suggestion: Candidate?

    /// Focuses / clears the test field that the input method types into during the test.
    var focusTestField: (() -> Void)?
    var clearTestField: (() -> Void)?

    private let settings: AppSettings
    private let keySynth = KeySynth()
    private let queue = DispatchQueue(label: "quickvoice.diagnostics", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var cancelled = false

    private let startTimeout: TimeInterval = 2.0
    private let stopTimeout: TimeInterval = 2.5
    /// How long a tap-to-toggle engine is left recording during its test.
    private let tapRecordingTime: TimeInterval = 1.5

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// For a hold-to-talk engine the input method's press-once key is not tested: it would start a
    /// recording that only ends with another press, and the settings already say what it does.
    /// A tap-to-toggle engine only reacts to its own shortcut, so the candidates are that one and
    /// the key the app uses now. A chord with an ordinary key is only tapped when the engine is
    /// bound to it: otherwise nothing swallows the key, and it would land in the test field or
    /// trigger a shortcut.
    static func buildCandidates(current resolution: HotkeyResolution, status: IMEStatus) -> [Candidate] {
        let ime = status.ime
        var list: [Candidate] = []
        func add(_ hotkey: Hotkey, _ title: String) {
            guard hotkey.isValid, !list.contains(where: { $0.hotkey == hotkey }) else { return }
            var candidate = Candidate(title: title, hotkey: hotkey)
            if ime.trigger == .hold, let toggle = status.voice?.toggle, toggle.enabled != false, toggle.hotkey == hotkey {
                candidate.outcome = .skipped("这是\(ime.name)「\(ime.toggleName)」的快捷键")
            }
            if ime.wouldLeakKey(of: hotkey, bound: status.shortcut?.hotkey), let key = hotkey.key {
                candidate.outcome = .skipped("\(ime.name)没有用这个键，没人拦截里面的「\(KeyNames.name(for: Int(key)))」，点按可能把它打进输入框")
            }
            list.append(candidate)
        }
        let current = resolution.hotkey
        let origin = resolution.followsIME ? "（跟随\(ime.name)）" : ""
        add(current, "当前生效：" + (HotkeyPreset.matching(current)?.title(for: ime) ?? current.displayName) + origin)
        if let own = status.shortcut?.hotkey {
            add(own, "\(ime.name)当前的「\(ime.shortcutName)」：\(own.displayName)")
        }
        if ime.trigger == .tapToggle {
            return list
        }
        // Right Shift switches input methods between Chinese and English, so it is only tested when chosen.
        for preset in HotkeyPreset.presets(for: ime) where preset.id != HotkeyPreset.rightShift.id {
            add(preset.hotkey, preset.title(for: ime))
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

    /// Main thread. Runs the whole test for `ime`; results are published as they come in.
    func run(for ime: VoiceIME) {
        guard !isRunning else { return }
        summary = nil
        suggestion = nil
        self.ime = ime
        let status = IMEStatus.inspect(ime)
        candidates = Self.buildCandidates(current: status.resolution(for: settings), status: status)

        guard Permissions.isAccessibilityTrusted else {
            summary = "需要先授予「辅助功能」权限，快捷语音输入才能替你按键。"
            return
        }
        guard status.isInstalled else {
            summary = "没有找到\(ime.name)。请先安装\(ime.name) Mac 版。"
            return
        }
        guard !ime.isStandalone || ime.isAppRunning else {
            summary = "\(ime.name)没有在运行。请先打开\(ime.name)并登录，再开始测试。"
            return
        }
        guard status.isEnabled || ime.isStandalone else {
            summary = "\(ime.name)还没有添加到输入法列表。请先在「系统设置 → 键盘 → 输入法」里添加它。"
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
        InputSource.select(ime)
        Log.info("hotkey test started for \(ime.id), mic=\(MicMonitor.name(of: device)), secureInput=\(secureInput)")

        let list = candidates
        queue.async { [weak self] in
            self?.runTests(list, ime: ime, previousSource: previousSource, secureInput: secureInput)
        }
    }

    private func runTests(_ list: [Candidate], ime: VoiceIME, previousSource: String?, secureInput: Bool) {
        usleep(500_000)
        for (index, candidate) in list.enumerated() where candidate.outcome == nil {
            if isCancelled { break }
            onMain {
                self.candidates[index].isTesting = true
                self.progress = "正在测试「\(candidate.hotkey.displayName)」（\(index + 1)/\(list.count)），请不要操作键盘和鼠标…"
                self.focusTestField?()
                InputSource.select(ime)
            }
            usleep(300_000)
            let outcome = ime.trigger == .tapToggle ? testTap(candidate.hotkey, ime: ime) : test(candidate.hotkey)
            Log.info("hotkey test \(ime.id) \(candidate.hotkey.displayName): \(outcome)")
            onMain {
                self.candidates[index].outcome = outcome
                self.candidates[index].wasTried = true
                self.candidates[index].isTesting = false
                self.clearTestField?()
            }
            usleep(900_000)
        }
        keySynth.release()
        onMain {
            if let previousSource, !ime.isStandalone, !ime.owns(sourceID: previousSource) {
                InputSource.select(sourceID: previousSource)
            }
            self.finish(ime: ime, secureInput: secureInput)
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
            // A press-once key keeps recording; press it again (then Esc) to end the session.
            keySynth.tap(hotkey)
            if !waitForStop(since: baseline) {
                keySynth.tap(Hotkey(modifiers: [], key: 53))
                _ = waitForStop(since: baseline)
            }
        }
        return HotkeyTestOutcome.evaluate(micBusyBefore: false, startLatency: latency, stoppedAfterRelease: stopped)
    }

    /// Taps `hotkey` to start, lets the engine record for a moment, then taps it to stop: the same
    /// safe sequence a long press uses. Skipped when the microphone is busy or a real key is down.
    private func testTap(_ hotkey: Hotkey, ime: VoiceIME) -> HotkeyTestOutcome {
        guard !ime.isStandalone || ime.isAppRunning else { return .skipped("\(ime.name)没有在运行") }
        let environment = LiveTapToggleEnvironment(ime: ime, keySynth: keySynth)
        let session = TapToggleSession(environment: environment, timing: settings.tapToggleTiming)
        let start = session.start(hotkey, shouldAbort: { [weak self] in self?.isCancelled ?? true })
        guard case .started = start else {
            return HotkeyTestOutcome.evaluate(start: start, stop: nil, stopLatency: 0)
        }
        let listenUntil = ProcessInfo.processInfo.systemUptime + tapRecordingTime
        while ProcessInfo.processInfo.systemUptime < listenUntil, !isCancelled {
            usleep(50_000)
        }
        let stopRequestedAt = ProcessInfo.processInfo.systemUptime
        let stop = session.stop(reason: isCancelled ? "test cancelled" : "hotkey test")
        let stopLatency = ProcessInfo.processInfo.systemUptime - stopRequestedAt
        return HotkeyTestOutcome.evaluate(start: start, stop: stop, stopLatency: stopLatency)
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

    private func finish(ime: VoiceIME, secureInput: Bool) {
        isRunning = false
        progress = nil
        let current = settings.resolvedHotkey(for: ime).hotkey
        let working = candidates.filter { $0.outcome?.isWorking == true }
        let recommended = ime.defaultHotkey.displayName
        let shortcutName = ime.shortcutName
        var lines: [String] = []
        if working.contains(where: { $0.hotkey == current }) {
            let how = ime.trigger == .hold ? "按住它" : "点按它一次开始、再点按一次结束"
            lines.append("✅ 当前快捷键「\(current.displayName)」可以正常触发\(ime.name)的「\(shortcutName)」（\(how)），可以开始使用了。")
        } else if let first = working.first {
            suggestion = first
            lines.append("「\(first.hotkey.displayName)」可以触发「\(shortcutName)」，但和当前设置「\(current.displayName)」不一样。点下面的按钮改用它。")
        } else if let stuck = candidates.first(where: { if case .tapStuck = $0.outcome { return true } else { return false } }) {
            lines.append("「\(stuck.hotkey.displayName)」能让\(ime.name)开始录音，但再点按一次没能结束它（已经补发过一次）。请先在\(ime.name)里手动结束这次录音，再检查它的「\(shortcutName)」是不是按一次开始、再按一次结束。")
        } else if let toggle = candidates.first(where: { if case .toggle = $0.outcome { return true } else { return false } }) {
            lines.append("「\(toggle.hotkey.displayName)」是\(ime.name)的「\(ime.toggleName)」快捷键（按一下开始、再按结束），不适合长按。请在\(ime.name)设置里把「\(ime.pushToTalkName)」改成「\(recommended)」后重新测试。")
        } else if candidates.contains(where: { $0.outcome == .micBusy }) {
            lines.append("测试时麦克风被其它应用占用，结果不可靠。请关闭正在使用麦克风的应用（会议、录音软件等）后重新测试。")
        } else if candidates.first(where: { $0.hotkey == current })?.wasTried == true,
                  let noResult = HotkeyTestOutcome.noResultSummary(candidates.filter(\.wasTried).compactMap(\.outcome)) {
            lines.append(noResult)
        } else if ime.isStandalone {
            lines.append("没有候选键能触发\(ime.name)录音。请确认\(ime.name)正在运行、已经登录并授权，再打开它的设置，把「\(shortcutName)」的快捷键改成「\(recommended)」，然后重新测试。")
        } else {
            lines.append("没有候选键能触发\(ime.name)录音。请打开\(ime.name)设置，把「\(ime.pushToTalkName)」的快捷键改成「\(recommended)」，再重新测试。")
        }
        if secureInput {
            lines.append("⚠️ 检测到有应用开启了「安全输入」（例如密码框，或终端的「安全键盘输入」），这会让输入法收不到快捷键。")
        }
        summary = lines.joined(separator: "\n")
    }

    func adoptSuggestion() {
        guard let suggestion, let ime else { return }
        if IMEConfigCache.shared.config(for: ime)?.shortcut(for: ime.trigger)?.hotkey == suggestion.hotkey {
            settings.setHotkeySource(.followIME, for: ime)
        } else {
            settings.useManualHotkey(suggestion.hotkey, for: ime)
        }
        summary = "已改用「\(suggestion.hotkey.displayName)」。"
        self.suggestion = nil
    }

    private func onMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    #if DEBUG
    /// Fills in sample results so layout can be checked without running the test.
    func loadPreviewResults(status: IMEStatus) {
        ime = status.ime
        candidates = Self.buildCandidates(current: status.resolution(for: settings), status: status)
        let outcomes: [HotkeyTestOutcome] = [.noResponse, .pushToTalk(latency: 0.42), .noResponse, .toggle(latency: 0.3), .micBusy]
        for index in candidates.indices where candidates[index].outcome == nil {
            candidates[index].outcome = outcomes[index % outcomes.count]
        }
        finish(ime: status.ime, secureInput: true)
    }
    #endif
}
