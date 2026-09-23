import AppKit
import QuickVoiceCore
import SwiftUI

enum SetupStep: Int, CaseIterable, Identifiable {
    case permission, weType, hotkey, tryIt

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .permission: return "授权"
        case .weType: return "微信输入法"
        case .hotkey: return "语音快捷键"
        case .tryIt: return "试一试"
        }
    }
}

final class SetupModel: ObservableObject {
    @Published var step: SetupStep = .permission
    @Published var axTrusted = Permissions.isAccessibilityTrusted
    @Published var weType = WeTypeStatus.inspect()

    let settings: AppSettings
    let diagnostics: HotkeyDiagnostics
    let recorder = HotkeyRecorderModel()
    let testField = TestFieldHandle()
    let tryField = TestFieldHandle()
    var onFinish: (() -> Void)?
    private var timer: Timer?

    init(settings: AppSettings, diagnostics: HotkeyDiagnostics) {
        self.settings = settings
        self.diagnostics = diagnostics
        diagnostics.focusTestField = { [weak testField] in testField?.focus() }
        diagnostics.clearTestField = { [weak testField] in testField?.clear() }
        recorder.onFinish = { [weak settings] hotkey in settings?.useManualHotkey(hotkey) }
    }

    var resolution: HotkeyResolution { weType.resolution(for: settings) }

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
        let status = WeTypeStatus.inspect()
        if status != weType { weType = status }
    }

    func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .permission: return axTrusted
        case .weType: return weType.isInstalled && weType.isEnabled
        case .hotkey:
            let hotkey = resolution.hotkey
            return weType.pushToTalkMatches(hotkey) == true
                || diagnostics.candidates.contains { $0.hotkey == hotkey && $0.outcome?.isPushToTalk == true }
        case .tryIt: return settings.hasCompletedOnboarding
        }
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
        window.title = "快捷语音输入 · 设置向导"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(model: model, settings: model.settings, diagnostics: model.diagnostics))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak window] in window?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(step: SetupStep?, autoRunTest: Bool, startRecording: Bool = false) {
        model.refresh()
        if let step {
            model.step = step
        } else if !model.axTrusted {
            model.step = .permission
        }
        model.startRefreshing()
        AppActivation.bringToFront(window)
        if autoRunTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.model.diagnostics.run() }
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
            ForEach(SetupStep.allCases) { step in
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
            Spacer()
            Text("长按输入框说话，松开上屏")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .permission: PermissionStep(model: model)
        case .weType: WeTypeStep(model: model)
        case .hotkey: HotkeyStep(model: model, settings: settings, diagnostics: diagnostics)
        case .tryIt: TryItStep(model: model, settings: settings)
        }
    }

    private var footer: some View {
        HStack {
            if let previous = SetupStep(rawValue: model.step.rawValue - 1) {
                Button("上一步") { model.step = previous }
            }
            Spacer()
            if let next = SetupStep(rawValue: model.step.rawValue + 1) {
                Button("下一步") { model.step = next }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("完成") { model.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct StepHeader: View {
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

private struct WeTypeStep: View {
    @ObservedObject var model: SetupModel

    private var status: WeTypeStatus { model.weType }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "检查微信输入法",
                subtitle: "语音识别由微信输入法完成。快捷语音输入只负责在你长按鼠标时，替你按住它的语音快捷键。"
            )
            StatusRow(ok: status.isInstalled, text: status.isInstalled ? "已安装微信输入法 \(status.version ?? "")" : "没有找到微信输入法")
            if !status.isInstalled, let url = URL(string: "https://z.weixin.qq.com/") {
                Link("前往微信输入法官网下载 Mac 版", destination: url)
            }
            if status.isInstalled {
                StatusRow(ok: status.isEnabled, text: status.isEnabled ? "已添加到输入法列表" : "还没有添加到输入法列表")
                if !status.isEnabled {
                    Button("添加到输入法列表") {
                        InputSource.enableWeType()
                        model.refresh()
                    }
                }
                StatusRow(ok: nil, text: "微信输入法当前的「按住说话」快捷键：\(status.pushToTalkDescription)")
                if let note = versionNote {
                    StatusRow(ok: false, text: note)
                }
                HStack {
                    Button("打开微信输入法设置") { status.openSettingsApp() }
                    Button("重新检测") { model.refresh() }
                }
            }
        }
    }

    private var versionNote: String? {
        guard let version = status.version else { return nil }
        let numbers = version.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
        if numbers.lexicographicallyPrecedes([2, 2, 1]) {
            return "当前版本还不支持自定义语音快捷键，请先升级到 2.2.1 或更新版本。"
        }
        if numbers == [2, 2, 3] {
            return "有用户反馈 2.2.3 在终端里语音上屏异常；如果遇到，可以反馈给微信输入法或换用其它版本。"
        }
        return nil
    }
}

private struct HotkeyStep: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var diagnostics: HotkeyDiagnostics

    private var presetBinding: Binding<String> {
        Binding(
            get: { HotkeyPreset.matching(settings.hotkey)?.id ?? "custom" },
            set: { id in
                if let preset = HotkeyPreset.all.first(where: { $0.id == id }) { settings.useManualHotkey(preset.hotkey) }
            }
        )
    }

    var body: some View {
        let resolution = model.weType.resolution(for: settings)
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: "设置语音快捷键",
                subtitle: "长按时，快捷语音输入会替你按住微信输入法「按住说话」的快捷键。默认直接跟随微信输入法里的设置，不需要额外改动。"
            )
            Picker("快捷键来源", selection: $settings.hotkeySource) {
                Text("跟随微信输入法（推荐）").tag(HotkeySource.followWeType)
                Text("手动指定").tag(HotkeySource.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            if settings.hotkeySource == .followWeType {
                followSection(resolution)
            } else {
                manualSection
            }
            HotkeyRiskNotes(hotkey: resolution.hotkey)
            if let title = weTypeGuideTitle(resolution) {
                weTypeGuide(title: title)
            }

            Divider()
            HotkeyTestSection(diagnostics: diagnostics, testField: model.testField)
        }
    }

    @ViewBuilder
    private func followSection(_ resolution: HotkeyResolution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if resolution.followsWeType {
                StatusRow(ok: true, text: "微信输入法的「按住说话」是「\(model.weType.pushToTalkDescription)」，长按时会按住同样的键。以后在微信输入法里改键，这里会自动跟着变。")
            } else {
                StatusRow(ok: false, text: resolution.fallbackReason ?? "没能跟随微信输入法的设置。")
            }
            HStack(spacing: 12) {
                Button("重新读取微信输入法设置") { model.refresh() }
                Text("想用别的组合？").font(.callout).foregroundStyle(.secondary)
                HotkeyRecorderButton(model: model.recorder)
            }
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("快捷语音输入替你按住：", selection: presetBinding) {
                ForEach(HotkeyPreset.all) { preset in
                    Text(preset.title).tag(preset.id)
                }
                if HotkeyPreset.matching(settings.hotkey) == nil {
                    Text("自定义：\(settings.hotkey.displayName)").tag("custom")
                }
            }
            .frame(maxWidth: 420)
            if let preset = HotkeyPreset.matching(settings.hotkey) {
                Text(preset.note).font(.caption).foregroundStyle(.secondary)
            }
            HotkeyRecorderButton(model: model.recorder)
            Text("录制时直接按下想用的组合，例如先按住左 Option 再按空格。如果按的正好是微信输入法当前的语音快捷键，它可能会被微信输入法拦截，这时直接选「跟随微信输入法」就行。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            matchRow
        }
    }

    @ViewBuilder
    private var matchRow: some View {
        let weType = model.weType
        switch weType.pushToTalkMatches(settings.hotkey) {
        case .some(true):
            StatusRow(ok: true, text: "与微信输入法的「按住说话」（\(weType.pushToTalkDescription)）一致")
        case .some(false):
            VStack(alignment: .leading, spacing: 6) {
                StatusRow(ok: false, text: "微信输入法的「按住说话」目前是「\(weType.pushToTalkDescription)」，和这里选的不一致")
                Button("改为跟随微信输入法") { settings.hotkeySource = .followWeType }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        case .none:
            StatusRow(ok: nil, text: "没能读取微信输入法的快捷键设置，可以直接用下面的测试确认。")
        }
    }

    private func weTypeGuideTitle(_ resolution: HotkeyResolution) -> String? {
        guard model.weType.isInstalled else { return nil }
        if settings.hotkeySource == .followWeType, !resolution.followsWeType {
            return "需要在微信输入法里换一个键"
        }
        if !resolution.hotkey.risks.isEmpty {
            return "更稳妥的做法（可选）：把微信输入法的「按住说话」改成右 Option"
        }
        return nil
    }

    private func weTypeGuide(title: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Numbered(index: 1, text: "点「打开微信输入法设置」，进入「语音」相关设置。")
                Numbered(index: 2, text: "找到「按住说话」，点它的快捷键框，然后按一下键盘右侧的 Option（⌥）键。")
                Numbered(index: 3, text: "回到这里点「重新读取」。选的是「跟随微信输入法」的话，这里会自动跟着变。")
                HStack {
                    Button("打开微信输入法设置") { model.weType.openSettingsApp() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(diagnostics.isRunning ? "正在测试…" : "开始测试语音快捷键") { diagnostics.run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(diagnostics.isRunning)
                if diagnostics.isRunning {
                    ProgressView().controlSize(.small)
                    Button("停止") { diagnostics.cancel() }
                }
            }
            Text("测试会切到微信输入法，依次按住每个候选键约 2 秒，通过麦克风有没有开始工作来判断哪个键可用。全程约 20 秒，期间不用说话，也请不要操作键盘和鼠标。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("测试输入框（测试时会自动聚焦）").font(.caption).foregroundStyle(.secondary)
                TestTextView(handle: testField).frame(height: 44)
            }
            if let progress = diagnostics.progress {
                Text(progress).font(.callout)
            }
            ForEach(diagnostics.candidates) { candidate in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(for: candidate).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title)
                        if let outcome = candidate.outcome {
                            Text(outcome.summary)
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
        .id(Self.anchorID)
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
            VStack(alignment: .leading, spacing: 6) {
                Label("按住期间可以移动鼠标，不会选中文字。", systemImage: "cursorarrow.motionlines")
                Label("快速点击、双击、拖选都和平时一样，不会触发。", systemImage: "hand.tap")
                Label("用触控板时，开始录音的瞬间会轻震一下。", systemImage: "waveform")
                Label("某个应用识别不准时，可以在菜单栏图标里给它设置「任意位置都触发」或「不触发」。", systemImage: "slider.horizontal.3")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
