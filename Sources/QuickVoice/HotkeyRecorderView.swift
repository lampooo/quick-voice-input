import AppKit
import QuickVoiceCore
import SwiftUI

/// Captures one key combination while the setup window is key. Events are swallowed during
/// recording so Space or Return do not also press a button.
final class HotkeyRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var prompt: String?
    @Published private(set) var error: String?

    var onFinish: ((Hotkey) -> Void)?

    private var recorder = HotkeyRecorder()
    private var monitor: Any?

    func start() {
        stop()
        recorder = HotkeyRecorder()
        error = nil
        prompt = "请按下快捷键（Esc 取消）"
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        prompt = nil
    }

    private func handle(_ event: NSEvent) {
        let step: HotkeyRecorder.Step
        switch event.type {
        case .flagsChanged:
            step = recorder.flagsChanged(keyCode: Int(event.keyCode), flags: UInt64(event.modifierFlags.rawValue))
        case .keyDown:
            step = recorder.keyDown(keyCode: Int(event.keyCode), isRepeat: event.isARepeat)
        default:
            return
        }
        switch step {
        case .waiting:
            break
        case let .holding(modifiers):
            prompt = modifiers.isEmpty ? "请按下快捷键（Esc 取消）" : modifiers.map(\.displayName).joined(separator: " + ") + " + …"
        case let .finished(hotkey):
            stop()
            onFinish?(hotkey)
        case let .rejected(message):
            stop()
            error = message
        case .cancelled:
            stop()
        }
    }
}

struct HotkeyRecorderButton: View {
    @ObservedObject var model: HotkeyRecorderModel

    var body: some View {
        HStack(spacing: 10) {
            Button(model.isRecording ? "取消录制" : "录制快捷键…") {
                model.isRecording ? model.stop() : model.start()
            }
            if let prompt = model.prompt {
                Text(prompt)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 1))
            } else if let error = model.error {
                Text(error).font(.callout).foregroundStyle(Color.orange)
            }
        }
    }
}

/// Warnings for a hotkey that could type characters, trigger other shortcuts, or clash with the
/// input methods' own settings.
struct HotkeyRiskNotes: View {
    let hotkey: Hotkey
    var conflicts: [String] = []

    private var messages: [String] { hotkey.risks.map(\.message) + conflicts }

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
