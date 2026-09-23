import AppKit

/// This app's test text fields, so the probe can decide about clicks on our own windows
/// without querying ourselves through the Accessibility API: for the calling process itself,
/// AX requests run AppKit/SwiftUI accessibility code on the calling thread, which races with
/// the main thread and breaks click handling in the setup window.
final class OwnTestFields {
    static let shared = OwnTestFields()

    /// Main thread only.
    private let views = NSHashTable<NSView>.weakObjects()

    func register(_ view: NSView) {
        views.add(view)
    }

    func unregister(_ view: NSView) {
        views.remove(view)
    }

    /// Whether a visible test field covers the point (CoreGraphics global coordinates, top-left
    /// origin). Called from the probe queue; the main thread never waits on that queue.
    func contains(_ point: CGPoint) -> Bool {
        if Thread.isMainThread { return visibleRects().contains { $0.contains(point) } }
        return DispatchQueue.main.sync { visibleRects().contains { $0.contains(point) } }
    }

    private func visibleRects() -> [CGRect] {
        views.allObjects.compactMap { view in
            guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return nil }
            let visible = view.visibleRect
            guard !visible.isEmpty else { return nil }
            return Self.globalRect(fromScreenRect: window.convertToScreen(view.convert(visible, to: nil)))
        }
    }

    /// Converts an AppKit screen rect (bottom-left origin) to CoreGraphics global coordinates.
    static func globalRect(fromScreenRect rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Brings the setup window forward. Menu-bar (accessory) apps are not reliably activated by
/// `activate(ignoringOtherApps:)` on macOS 14+, so the app turns into a regular app while a
/// window is open and goes back to menu-bar-only when it closes.
enum AppActivation {
    static func bringToFront(_ window: NSWindow?) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    static func returnToMenuBar() {
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !visible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
