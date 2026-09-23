import AppKit
import ApplicationServices
import QuickVoiceCore

/// Decides, via the Accessibility API, whether a long press at a screen point is inside an
/// editable text field. Runs on its own queue so AX round-trips never block the event tap.
final class TextFieldProbe {
    struct Result {
        var verdict: ProbeVerdict
        var bundleID: String?
        var detail: String
    }

    private let queue = DispatchQueue(label: "quickvoice.probe", qos: .userInteractive)
    private let systemWide = AXUIElementCreateSystemWide()
    private let settings: AppSettings
    private let messagingTimeout: Float = 0.25
    private var manualAccessibilityPIDs = Set<pid_t>()
    private var chromiumBundleCache: [String: Bool] = [:]
    private var deadline: TimeInterval = 0
    private let budget: TimeInterval = 0.7

    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
        "com.operasoftware.Opera", "com.bot.pc.doubao.browser",
    ]

    init(settings: AppSettings) {
        self.settings = settings
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    }

    func probe(at point: CGPoint, completion: @escaping (Result) -> Void) {
        queue.async { [self] in
            let started = ProcessInfo.processInfo.systemUptime
            let result = evaluate(point)
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            Log.info("probe \(result.bundleID ?? "?") -> \(result.verdict) (\(result.detail)) \(elapsed)ms")
            completion(result)
        }
    }

    private var outOfTime: Bool { ProcessInfo.processInfo.systemUptime > deadline }

    private func evaluate(_ point: CGPoint) -> Result {
        deadline = ProcessInfo.processInfo.systemUptime + budget
        var hit = elementAt(point, in: systemWide)
        var pid: pid_t = 0
        if let hit { AXUIElementGetPid(hit, &pid) }
        if pid == 0 { pid = Self.windowOwner(at: point) ?? 0 }
        guard pid != 0 else { return Result(verdict: .skip, bundleID: nil, detail: "no app under pointer") }

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        switch settings.rule(for: bundleID) {
        case .never:
            return Result(verdict: .skip, bundleID: bundleID, detail: "rule: never")
        case .anywhere:
            if let hit, string(hit, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
                return Result(verdict: .skip, bundleID: bundleID, detail: "password field")
            }
            return Result(verdict: .trigger, bundleID: bundleID, detail: "rule: anywhere")
        case .auto:
            break
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        if enableManualAccessibilityIfNeeded(pid: pid, app: app, appElement: appElement) {
            usleep(180_000)
            hit = elementAt(point, in: appElement)
        }

        var trail: [String] = []
        if let hit {
            switch classifyAncestors(of: hit, trail: &trail) {
            case .editable: return Result(verdict: .trigger, bundleID: bundleID, detail: trail.joined(separator: "<"))
            case .secure: return Result(verdict: .skip, bundleID: bundleID, detail: "password field")
            case .readOnly, .none: break
            }
        }
        if outOfTime {
            return Result(verdict: .skip, bundleID: bundleID, detail: "timeout: " + trail.joined(separator: "<"))
        }
        if let focused = copyElement(appElement, kAXFocusedUIElementAttribute) {
            var focusedTrail: [String] = []
            if classify(focused, trail: &focusedTrail) == .editable, frame(of: focused).map({ Self.contains($0, point) }) == true {
                return Result(verdict: .trigger, bundleID: bundleID, detail: "focused " + focusedTrail.joined())
            }
        }
        return Result(verdict: .skip, bundleID: bundleID, detail: "not editable: " + trail.joined(separator: "<"))
    }

    private enum FieldKind { case editable, secure, readOnly }

    private func classifyAncestors(of element: AXUIElement, trail: inout [String]) -> FieldKind? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 6, !outOfTime {
            if let kind = classify(node, trail: &trail) { return kind }
            let role = string(node, kAXRoleAttribute)
            if role == kAXWindowRole || role == kAXApplicationRole || role == "AXWebArea" { return nil }
            current = copyElement(node, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    private func classify(_ element: AXUIElement, trail: inout [String]) -> FieldKind? {
        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute)
        trail.append(subrole.map { "\(role)/\($0)" } ?? role)
        if subrole == kAXSecureTextFieldSubrole { return .secure }
        if Self.textRoles.contains(role) {
            if isSettable(element, kAXValueAttribute) || copyElement(element, "AXEditableAncestor") != nil {
                return .editable
            }
            return .readOnly
        }
        if copyElement(element, "AXEditableAncestor") != nil { return .editable }
        return nil
    }

    /// Chromium and Electron only build their accessibility tree when an assistive app asks.
    private func enableManualAccessibilityIfNeeded(pid: pid_t, app: NSRunningApplication?, appElement: AXUIElement) -> Bool {
        guard !manualAccessibilityPIDs.contains(pid), isChromiumBased(app) else { return false }
        manualAccessibilityPIDs.insert(pid)
        let status = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Log.info("AXManualAccessibility on \(app?.bundleIdentifier ?? "\(pid)") -> \(status.rawValue)")
        return status == .success
    }

    private func isChromiumBased(_ app: NSRunningApplication?) -> Bool {
        guard let app, let bundleID = app.bundleIdentifier else { return false }
        if Self.chromiumBrowsers.contains(bundleID) { return true }
        if let cached = chromiumBundleCache[bundleID] { return cached }
        var result = false
        if let url = app.bundleURL {
            let frameworks = url.appendingPathComponent("Contents/Frameworks")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
            result = names.contains { $0 == "Electron Framework.framework" || $0.hasSuffix("Framework.framework") && $0.contains("Chrom") }
        }
        chromiumBundleCache[bundleID] = result
        return result
    }

    private func elementAt(_ point: CGPoint, in root: AXUIElement) -> AXUIElement? {
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element)
        return status == .success ? element : nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Code editors such as VS Code keep focus in a tiny hidden text area placed at the caret,
    /// so small focused elements get a larger margin.
    static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        let tiny = frame.width < 16 || frame.height < 16
        return frame.insetBy(dx: tiny ? -32 : -8, dy: tiny ? -32 : -8).contains(point)
    }

    static func windowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  let pid = info[kCGWindowOwnerPID as String] as? Int else { continue }
            return pid_t(pid)
        }
        return nil
    }
}
