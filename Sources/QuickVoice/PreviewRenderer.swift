#if DEBUG
import AppKit
import SwiftUI

/// `QuickVoice --render-setup <dir>` (debug builds only): renders every setup step into PNG
/// files from an off-screen window. Nothing is shown on screen and the app never activates.
enum PreviewRenderer {
    static func run(outputDirectory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "QuickVoicePreview") ?? .standard)
        let diagnostics = HotkeyDiagnostics(settings: settings)
        let model = SetupModel(settings: settings, diagnostics: diagnostics)

        let window = offscreenWindow(size: SetupView.size)
        let hosting = NSHostingView(rootView: SetupView(model: model, settings: settings, diagnostics: diagnostics))
        hosting.frame = NSRect(origin: .zero, size: SetupView.size)
        window.contentView = hosting

        for step in SetupStep.allCases {
            model.step = step
            save(hosting, to: outputDirectory.appendingPathComponent("setup-\(step.rawValue + 1).png"))
        }
        model.step = .hotkey
        settings.hotkeySource = .manual
        save(hosting, to: outputDirectory.appendingPathComponent("setup-3-manual.png"))
        settings.hotkeySource = .followWeType

        diagnostics.loadPreviewResults(weType: model.weType)
        let results = NSHostingView(rootView:
            HotkeyTestSection(diagnostics: diagnostics, testField: TestFieldHandle())
                .padding(20)
                .frame(width: 580, alignment: .topLeading)
        )
        let resultsSize = CGSize(width: 580, height: max(200, results.fittingSize.height))
        results.frame = NSRect(origin: .zero, size: resultsSize)
        let resultsWindow = offscreenWindow(size: resultsSize)
        resultsWindow.contentView = results
        save(results, to: outputDirectory.appendingPathComponent("hotkey-test-results.png"))
        print("rendered to \(outputDirectory.path)")
    }

    private static func offscreenWindow(size: CGSize) -> NSWindow {
        NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private static func save(_ view: NSView, to url: URL) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
