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
        for ime in model.hotkeyIMEs {
            model.editingIME = ime
            save(hosting, to: outputDirectory.appendingPathComponent("setup-3-\(ime.id).png"))
        }
        settings.setHotkeySource(.manual, for: model.editingIME)
        save(hosting, to: outputDirectory.appendingPathComponent("setup-3-manual.png"))
        settings.setHotkeySource(.followIME, for: model.editingIME)

        model.step = .blocklist
        for bundleID in ["com.tencent.xinWeChat", "com.apple.Terminal", "com.example.removed-app"] {
            settings.block(bundleID)
        }
        save(hosting, to: outputDirectory.appendingPathComponent("setup-5-list.png"))
        settings.appRules = [:]

        diagnostics.loadPreviewResults(status: model.status(of: model.editingIME))
        let results = NSHostingView(rootView:
            HotkeyTestSection(diagnostics: diagnostics, testField: TestFieldHandle(), ime: model.editingIME)
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
