import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

enum Permissions {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds this app to the Accessibility list, then opens the
    /// pane. Only called when the user clicks 「去授权」.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Another app (a password field, Terminal's 「安全键盘输入」…) is blocking keyboard taps.
    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("launch at login \(enabled) failed: \(error)")
        }
        if enabled, needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
