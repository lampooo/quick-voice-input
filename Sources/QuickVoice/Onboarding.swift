import AppKit
import Combine
import QuickVoiceCore
import SwiftUI

enum SetupStep: Int, CaseIterable, Identifiable {
    case permission, voiceIME, hotkey, tryIt
    /// A settings page next to the guide, not a numbered step.
    case blocklist

    static let guide: [SetupStep] = [.permission, .voiceIME, .hotkey, .tryIt]

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .permission: return "授权"
        case .voiceIME: return "语音输入法"
        case .hotkey: return "语音快捷键"
        case .tryIt: return "试一试"
        case .blocklist: return "屏蔽的软件"
        }
    }

    var previous: SetupStep? {
        guard let index = Self.guide.firstIndex(of: self), index > 0 else { return nil }
        return Self.guide[index - 1]
    }

    var next: SetupStep? {
        guard let index = Self.guide.firstIndex(of: self), index + 1 < Self.guide.count else { return nil }
        return Self.guide[index + 1]
    }
}

final class SetupModel: ObservableObject {
    @Published var step: SetupStep = .permission
    @Published var axTrusted = Permissions.isAccessibilityTrusted
    @Published var statuses = IMEStatus.inspectAll()
    /// The input method whose hotkey the 「语音快捷键」 step edits and tests.
    @Published var editingIME: VoiceIME
    /// Whether the last long press put text into the field.
    @Published var lastCommit: CommitReport?

    let settings: AppSettings
    let diagnostics: HotkeyDiagnostics
    let recorder = HotkeyRecorderModel()
    let testField = TestFieldHandle()
    let tryField = TestFieldHandle()
    var onFinish: (() -> Void)?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, diagnostics: HotkeyDiagnostics) {
        self.settings = settings
        self.diagnostics = diagnostics
        editingIME = VoiceTarget.select(settings: settings).ime
        diagnostics.focusTestField = { [weak testField] in testField?.focus() }
        diagnostics.clearTestField = { [weak testField] in testField?.clear() }
        recorder.onFinish = { [weak self] hotkey in
            guard let self else { return }
            self.settings.useManualHotkey(hotkey, for: self.editingIME)
        }
        settings.$voiceIME.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncEditingIME()
        }.store(in: &cancellables)
        syncEditingIME()
    }

    func status(of ime: VoiceIME) -> IMEStatus { statuses.status(of: ime) }

    func resolution(for ime: VoiceIME) -> HotkeyResolution { status(of: ime).resolution(for: settings) }

    var hotkeyIMEs: [VoiceIME] { settings.hotkeyIMEs(statuses: statuses) }

    private func syncEditingIME() {
        let choices = hotkeyIMEs
        guard !choices.contains(editingIME) else { return }
        let target = VoiceTarget.select(settings: settings).ime
        editingIME = choices.contains(target) ? target : choices[0]
    }

    func startRefreshing() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let trusted = Permissions.isAccessibilityTrusted
        if trusted != axTrusted { axTrusted = trusted }
        let latest = IMEStatus.inspectAll()
        if latest != statuses { statuses = latest }
        syncEditingIME()
    }

    func isDone(_ step: SetupStep) -> Bool {
        let usable = hotkeyIMEs.filter { status(of: $0).isUsable }
        switch step {
        case .permission: return axTrusted
        case .voiceIME: return !usable.isEmpty
        case .hotkey: return !usable.isEmpty && usable.allSatisfy(hotkeyWorks)
        case .tryIt: return settings.hasCompletedOnboarding
        case .blocklist: return false
        }
    }

    private func hotkeyWorks(_ ime: VoiceIME) -> Bool {
        let hotkey = resolution(for: ime).hotkey
        return status(of: ime).pushToTalkMatches(hotkey) == true
            || diagnostics.ime == ime && diagnostics.candidates.contains { $0.hotkey == hotkey && $0.outcome?.isPushToTalk == true }
    }

    func finish() {
        settings.hasCompletedOnboarding = true
        onFinish?()
    }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let model: SetupModel

    init(model: SetupModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SetupView.size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "快捷语音输入 · 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(model: model, settings: model.settings, diagnostics: model.diagnostics))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak window] in window?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `ime` picks the input method the hotkey step shows, when it is one of the step's choices.
    func show(step: SetupStep?, autoRunTest: Bool, startRecording: Bool = false, ime: VoiceIME? = nil) {
        model.refresh()
        if let ime, model.hotkeyIMEs.contains(ime) {
            model.editingIME = ime
        }
        if let step {
            model.step = step
        } else if !model.axTrusted {
            model.step = .permission
        }
        model.startRefreshing()
        AppActivation.bringToFront(window)
        if autoRunTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.model.diagnostics.run(for: self.model.editingIME)
            }
        } else if startRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.model.recorder.start() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRefreshing()
        model.diagnostics.cancel()
        model.recorder.stop()
        AppActivation.returnToMenuBar()
    }
}

// MARK: - Test text field

/// Lets the diagnostics focus and clear an AppKit text view that lives inside SwiftUI.
final class TestFieldHandle {
    weak var textView: NSTextView?

    func focus() {
        guard let textView, let window = textView.window else { return }
        if !NSApp.isActive || !window.isKeyWindow {
            AppActivation.bringToFront(window)
        }
        window.makeFirstResponder(textView)
    }

    func clear() {
        textView?.string = ""
    }
}

/// Hosts a test text field and registers it with `OwnTestFields` while it is in a window.
final class TestFieldContainer: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            OwnTestFields.shared.unregister(self)
        } else {
            OwnTestFields.shared.register(self)
        }
    }
}

struct TestTextView: NSViewRepresentable {
    let handle: TestFieldHandle

    func makeNSView(context: Context) -> TestFieldContainer {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.font = .systemFont(ofSize: 15)
            textView.isRichText = false
            textView.allowsUndo = true
            textView.textContainerInset = NSSize(width: 6, height: 8)
            textView.setAccessibilityLabel("测试输入框")
            handle.textView = textView
        }
        return TestFieldContainer(content: scrollView)
    }

    func updateNSView(_ nsView: TestFieldContainer, context: Context) {}

    static func dismantleNSView(_ nsView: TestFieldContainer, coordinator: ()) {
        OwnTestFields.shared.unregister(nsView)
    }
}

// MARK: - Views

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var diagnostics: HotkeyDiagnostics

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            Divider()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .padding(28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: diagnostics.isRunning) { running in
                        withAnimation { proxy.scrollTo(HotkeyTestSection.anchorID, anchor: running ? .top : .bottom) }
                    }
                }
                Divider()
                footer
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: SetupView.size.width, height: SetupView.size.height)
    }

    static let size = CGSize(width: 760, height: 620)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                Text("快捷语音输入")
                    .font(.headline)
            }
            .padding(.bottom, 18)
            ForEach(SetupStep.guide) { step in
                Button {
                    model.step = step
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(model.step == step ? Color.accentColor : Color.secondary.opacity(0.18))
                                .frame(width: 24, height: 24)
                            if model.isDone(step) && model.step != step {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.green)
                            } else {
                                Text("\(step.rawValue + 1)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(model.step == step ? Color.white : Color.primary)
                            }
                        }
                        Text(step.title)
                            .fontWeight(model.step == step ? .semibold : .regular)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(model.step == step ? Color.accentColor.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 8)
            blocklistRow
            Spacer()
            Text("长按输入框说话，松开上屏")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private var blocklistRow: some View {
        let selected = model.step == .blocklist
        let count = settings.blockedBundleIDs.count
        return Button {
            model.step = .blocklist
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(SetupStep.blocklist.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .fixedSize()
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .permission: PermissionStep(model: model)
        case .voiceIME: VoiceIMEStep(model: model, settings: settings)
        case .hotkey: HotkeyStep(model: model, settings: settings, diagnostics: diagnostics)
        case .tryIt: TryItStep(model: model, settings: settings)
        case .blocklist: BlocklistPage(settings: settings)
        }
    }

    private var footer: some View {
        HStack {
            if let previous = model.step.previous {
                Button("上一步") { model.step = previous }
            }
            Spacer()
            if model.step == .blocklist {
                Button("回到设置向导") { model.step = settings.hasCompletedOnboarding ? .tryIt : .permission }
            } else if let next = model.step.next {
                Button("下一步") { model.step = next }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("完成") { model.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

private struct StatusRow: View {
    let ok: Bool?
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch ok {
            case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            case .some(false): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
            case .none: Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Numbered: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionStep: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "授予「辅助功能」权限",
                subtitle: "快捷语音输入需要它来识别鼠标长按、判断指针下是不是输入框，并替你按住语音快捷键。它不会读取、保存或上传你输入的内容。"
            )
            StatusRow(ok: model.axTrusted, text: model.axTrusted ? "已授权，可以继续下一步。" : "尚未授权")
            if !model.axTrusted {
                Button("去授权") { Permissions.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                VStack(alignment: .leading, spacing: 8) {
                    Numbered(index: 1, text: "点「去授权」，系统会打开「系统设置 → 隐私与安全性 → 辅助功能」。")
                    Numbered(index: 2, text: "打开「快捷语音输入」右侧的开关，按提示输入密码或用触控 ID 确认。")
                    Numbered(index: 3, text: "回到这里，状态会自动变成「已授权」。")
                }
                Text("如果列表里已经有「快捷语音输入」但开关无效（比如重新安装过），先选中它点「−」删除，再点「去授权」重新添加。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VoiceIMEStep: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "选择语音输入法",
                subtitle: "语音识别由输入法完成，目前支持\(VoiceIME.all.map(\.name).joined(separator: "和"))。快捷语音输入只负责在你长按鼠标时，替你按住它的语音快捷键。"
            )
            Picker("语音输入法", selection: $settings.voiceIME) {
                ForEach(VoiceIMEChoice.all, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(choiceExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.statuses) { status in
                IMEStatusCard(model: model, status: status)
            }
            Button("重新检测") { model.refresh() }
        }
    }

    private var choiceExplanation: String {
        let names = VoiceIME.all.map(\.name).joined(separator: "或")
        switch settings.voiceIME {
        case .automatic:
            let selection = VoiceTarget.select(settings: settings)
            let switching = settings.autoSwitchInputSource ? "，开始前会自动切过去" : ""
            return "当前输入法是\(names)时就用它；是其它输入法（比如 ABC）时，用最近用过的那个\(switching)。现在长按会用：\(selection.ime.name)（\(selection.explanation)）。"
        case let .fixed(ime):
            return settings.autoSwitchInputSource
                ? "总是用\(ime.name)。当前是别的输入法时，开始前会自动切到\(ime.name)。"
                : "总是用\(ime.name)。「触发前自动切换输入法」已关闭，需要先手动切到\(ime.name)。"
        }
    }
}

private struct IMEStatusCard: View {
    @ObservedObject var model: SetupModel
    let status: IMEStatus

    private var ime: VoiceIME { status.ime }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(ime.name).font(.headline)
                    if let version = status.version {
                        Text(version).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if status.isCurrent {
                        Text("当前输入法")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                if status.isInstalled {
                    StatusRow(ok: status.isEnabled, text: status.isEnabled ? "已安装，已添加到输入法列表" : "已安装，但还没有添加到输入法列表")
                    if !status.isEnabled {
                        Button("添加到输入法列表") {
                            InputSource.enable(ime)
                            model.refresh()
                        }
                    }
                    StatusRow(ok: nil, text: "「\(ime.pushToTalkName)」快捷键：\(status.pushToTalkDescription)")
                    if let advice = status.versionAdvice {
                        StatusRow(ok: false, text: advice)
                    }
                    Button("打开\(ime.name)设置") { status.openSettingsApp() }
                } else {
                    StatusRow(ok: nil, text: "没有安装")
                    if let url = URL(string: ime.downloadURL) {
                        Link("前往\(ime.name)官网下载 Mac 版", destination: url)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HotkeyStep: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var diagnostics: HotkeyDiagnostics

    private var ime: VoiceIME { model.editingIME }
    private var status: IMEStatus { model.status(of: ime) }
    private var setting: IMEHotkeySetting { settings.hotkeySetting(for: ime) }

    private var sourceBinding: Binding<HotkeySource> {
        Binding(
            get: { settings.hotkeySetting(for: ime).source },
            set: { settings.setHotkeySource($0, for: ime) }
        )
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { HotkeyPreset.matching(settings.hotkeySetting(for: ime).manual)?.id ?? "custom" },
            set: { id in
                if let preset = HotkeyPreset.all.first(where: { $0.id == id }) { settings.useManualHotkey(preset.hotkey, for: ime) }
            }
        )
    }

    var body: some View {
        let resolution = model.resolution(for: ime)
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "设置语音快捷键",
                subtitle: "长按时，快捷语音输入会替你按住\(ime.name)「\(ime.pushToTalkName)」的快捷键。默认直接跟随\(ime.name)里的设置，不需要额外改动。"
            )
            if model.hotkeyIMEs.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("输入法", selection: $model.editingIME) {
                        ForEach(model.hotkeyIMEs) { ime in
                            Text(ime.name).tag(ime)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Text("「语音输入法」选的是自动，每个输入法的快捷键分别设置、分别测试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("快捷键来源", selection: sourceBinding) {
                Text("跟随\(ime.name)（推荐）").tag(HotkeySource.followIME)
                Text("手动指定").tag(HotkeySource.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            if setting.source == .followIME {
                followSection(resolution)
            } else {
                manualSection
            }
            HotkeyRiskNotes(hotkey: resolution.hotkey, conflicts: model.statuses.conflicts(holding: resolution.hotkey, for: ime).map(\.message))
            if let title = guideTitle(resolution) {
                imeGuide(title: title)
            }

            Divider()
            HotkeyTestSection(diagnostics: diagnostics, testField: model.testField, ime: ime)
        }
    }

    @ViewBuilder
    private func followSection(_ resolution: HotkeyResolution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if resolution.followsIME {
                StatusRow(ok: true, text: "\(ime.name)的「\(ime.pushToTalkName)」是「\(status.pushToTalkDescription)」，长按时会按住同样的键。以后在\(ime.name)里改键，下一次长按就会跟着变，不用重启。")
            } else {
                StatusRow(ok: false, text: resolution.fallbackReason ?? "没能跟随\(ime.name)的设置。")
            }
            HStack(spacing: 12) {
                Button("重新读取\(ime.name)设置") { model.refresh() }
                Text("想用别的组合？").font(.callout).foregroundStyle(.secondary)
                HotkeyRecorderButton(model: model.recorder)
            }
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("快捷语音输入替你按住：", selection: presetBinding) {
                ForEach(HotkeyPreset.all) { preset in
                    Text(preset.title(for: ime)).tag(preset.id)
                }
                if HotkeyPreset.matching(setting.manual) == nil {
                    Text("自定义：\(setting.manual.displayName)").tag("custom")
                }
            }
            .frame(maxWidth: 420)
            if let preset = HotkeyPreset.matching(setting.manual) {
                Text(preset.note).font(.caption).foregroundStyle(.secondary)
            }
            HotkeyRecorderButton(model: model.recorder)
            Text("录制时直接按下想用的组合，例如先按住左 Option 再按空格。如果按的正好是\(ime.name)当前的语音快捷键，它可能会被\(ime.name)拦截，这时直接选「跟随\(ime.name)」就行。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            matchRow
        }
    }

    @ViewBuilder
    private var matchRow: some View {
        switch status.pushToTalkMatches(setting.manual) {
        case .some(true):
            StatusRow(ok: true, text: "与\(ime.name)的「\(ime.pushToTalkName)」（\(status.pushToTalkDescription)）一致")
        case .some(false):
            VStack(alignment: .leading, spacing: 6) {
                StatusRow(ok: false, text: "\(ime.name)的「\(ime.pushToTalkName)」目前是「\(status.pushToTalkDescription)」，和这里选的不一致")
                Button("改为跟随\(ime.name)") { settings.setHotkeySource(.followIME, for: ime) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        case .none:
            StatusRow(ok: nil, text: "没能读取\(ime.name)的快捷键设置，可以直接用下面的测试确认。")
        }
    }

    private func guideTitle(_ resolution: HotkeyResolution) -> String? {
        guard status.isInstalled else { return nil }
        if setting.source == .followIME, !resolution.followsIME {
            return "需要在\(ime.name)里换一个键"
        }
        if !resolution.hotkey.risks.isEmpty {
            return "更稳妥的做法（可选）：把\(ime.name)的「\(ime.pushToTalkName)」改成\(ime.defaultHotkey.displayName)"
        }
        return nil
    }

    private func imeGuide(title: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(Array(ime.setupSteps.enumerated()), id: \.offset) { index, text in
                    Numbered(index: index + 1, text: text)
                }
                HStack {
                    Button("打开\(ime.name)设置") { status.openSettingsApp() }
                    Button("重新读取") { model.refresh() }
                }
                .padding(.top, 4)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HotkeyTestSection: View {
    static let anchorID = "hotkeyTest"

    @ObservedObject var diagnostics: HotkeyDiagnostics
    let testField: TestFieldHandle
    let ime: VoiceIME

    /// Results belong to the input method they were measured with.
    private var showsResults: Bool { diagnostics.ime == ime }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(diagnostics.isRunning ? "正在测试…" : "开始测试\(ime.name)的语音快捷键") { diagnostics.run(for: ime) }
                    .buttonStyle(.borderedProminent)
                    .disabled(diagnostics.isRunning)
                if diagnostics.isRunning {
                    ProgressView().controlSize(.small)
                    Button("停止") { diagnostics.cancel() }
                }
            }
            Text("测试会切到\(ime.name)，依次按住每个候选键约 2 秒，通过麦克风有没有开始工作来判断哪个键可用。全程约 20 秒，期间不用说话，也请不要操作键盘和鼠标。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("测试输入框（测试时会自动聚焦）").font(.caption).foregroundStyle(.secondary)
                TestTextView(handle: testField).frame(height: 44)
            }
            if showsResults {
                results
            } else if let other = diagnostics.ime, diagnostics.isRunning {
                Text("正在测试\(other.name)…").font(.callout)
            }
        }
        .id(Self.anchorID)
    }

    @ViewBuilder
    private var results: some View {
        if let progress = diagnostics.progress {
            Text(progress).font(.callout)
        }
        ForEach(diagnostics.candidates) { candidate in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon(for: candidate).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                    if let outcome = candidate.outcome {
                        Text(outcome.summary(for: ime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if let summary = diagnostics.summary {
            Text(summary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        }
        if let suggestion = diagnostics.suggestion {
            Button("改用「\(suggestion.hotkey.displayName)」") { diagnostics.adoptSuggestion() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func icon(for candidate: HotkeyDiagnostics.Candidate) -> some View {
        if candidate.isTesting {
            ProgressView().controlSize(.mini)
        } else {
            switch candidate.outcome {
            case .none: Image(systemName: "circle").foregroundStyle(.secondary)
            case .some(.pushToTalk): Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            case .some(.toggle): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
            case .some(.micBusy), .some(.skipped): Image(systemName: "questionmark.circle").foregroundStyle(Color.orange)
            case .some(.noResponse): Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

private struct TryItStep: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "试一试",
                subtitle: String(format: "在下面的输入框里按住鼠标左键不动，大约 %.1f 秒后开始说话；说完松开鼠标，文字就会出现在输入框里。", settings.holdDuration)
            )
            if !model.axTrusted {
                StatusRow(ok: false, text: "还没有授予辅助功能权限，长按不会生效。请先完成第 1 步。")
            } else if !settings.enabled {
                StatusRow(ok: false, text: "长按语音输入已暂停，可以在菜单栏图标里重新启用。")
            }
            TestTextView(handle: model.tryField).frame(height: 160)
            if let report = model.lastCommit {
                StatusRow(ok: commitOK(report.outcome), text: "上一次长按（\(report.ime.name)）：\(report.outcome.summary)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("松开后 5 秒内会比较输入框的字数，判断文字有没有上屏（只看字数，不读取内容），结果也写在日志里。", systemImage: "checkmark.circle")
                Label("按住期间可以移动鼠标，不会选中文字。", systemImage: "cursorarrow.motionlines")
                Label("快速点击、双击、拖选都和平时一样，不会触发。", systemImage: "hand.tap")
                Label("用触控板时，开始录音的瞬间会轻震一下。", systemImage: "waveform")
                Label("某个应用识别不准时，可以在菜单栏图标里给它设置「任意位置都触发」或「不触发」。", systemImage: "slider.horizontal.3")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func commitOK(_ outcome: CommitCheck.Outcome) -> Bool? {
        switch outcome {
        case .committed: return true
        case .unchanged: return false
        case .changed, .unavailable: return nil
        }
    }
}
