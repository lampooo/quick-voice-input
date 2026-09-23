import AppKit
import ApplicationServices
import QuickVoiceCore

/// Decides whether a long press at a screen point is inside an editable text field. Runs on its
/// own queue so Accessibility round-trips never block the event tap.
final class TextFieldProbe {
    struct Result {
        var verdict: ProbeVerdict
        var bundleID: String?
        var detail: String
        var elapsedMilliseconds = 0
        /// The app the press went to, when known.
        var pid: pid_t?
    }

    private let queue = DispatchQueue(label: "quickvoice.probe", qos: .userInteractive)
    private let settings: AppSettings
    private let messagingTimeout: Float = 0.25
    private let ownPID = getpid()
    private var accessibilityEnabledPIDs = Set<pid_t>()
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
    }

    /// Runs after `delay`; skipped when `isStillPressed` says the press already ended.
    /// `windowNumber` is the window the window server routed the mouse-down to (0 if unknown).
    func probe(at point: CGPoint, windowNumber: Int, after delay: TimeInterval, isStillPressed: @escaping () -> Bool, completion: @escaping (Result) -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard isStillPressed() else { return }
            let started = ProcessInfo.processInfo.systemUptime
            var result = evaluate(point, windowNumber: windowNumber)
            result.elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            completion(result)
        }
    }

    private var outOfTime: Bool { ProcessInfo.processInfo.systemUptime > deadline }

    private func evaluate(_ point: CGPoint, windowNumber: Int) -> Result {
        deadline = ProcessInfo.processInfo.systemUptime + budget
        let eventTarget = Self.ownerPID(ofWindow: windowNumber)
        let via = eventTarget == nil ? "window list" : "event window"
        guard let pid = eventTarget ?? Self.topWindowOwner(at: point) else {
            return Result(verdict: .skip, bundleID: nil, detail: "no app under pointer")
        }
        var result = evaluate(point, pid: pid, via: via)
        result.pid = pid
        return result
    }

    private func evaluate(_ point: CGPoint, pid: pid_t, via: String) -> Result {
        // Never query ourselves through Accessibility: see OwnTestFields.
        if pid == ownPID {
            return OwnTestFields.shared.contains(point)
                ? Result(verdict: .trigger, bundleID: Bundle.main.bundleIdentifier, detail: "own test field")
                : Result(verdict: .skip, bundleID: Bundle.main.bundleIdentifier, detail: "own window")
        }

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let rule = settings.rule(for: bundleID)
        // Blocked apps are not looked at: no Accessibility request reaches them.
        if rule == .never {
            return Result(verdict: .skip, bundleID: bundleID, detail: "blocked")
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var hit = elementAt(point, in: appElement)

        switch rule {
        case .never:
            return Result(verdict: .skip, bundleID: bundleID, detail: "blocked")
        case .anywhere:
            if let hit, string(hit, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
                return Result(verdict: .skip, bundleID: bundleID, detail: "password field")
            }
            return Result(verdict: .trigger, bundleID: bundleID, detail: "rule: anywhere")
        case .auto:
            break
        }

        if enableAccessibilityIfNeeded(pid: pid, app: app, appElement: appElement) {
            usleep(180_000)
            hit = elementAt(point, in: appElement)
        }

        var trail: [String] = []
        if let hit {
            switch classifyAncestors(of: hit, at: point, trail: &trail) {
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
        // Apps that expose nothing at all under the pointer (WeChat's content area) still show the
        // system I-beam over text inputs. Apps with an accessibility tree never take this path, because
        // browsers and editors show the I-beam over any selectable text.
        if hit == nil, isIBeamCursor() {
            return Result(verdict: .trigger, bundleID: bundleID, detail: "no accessibility, I-beam cursor, target from \(via)")
        }
        return Result(verdict: .skip, bundleID: bundleID, detail: hit == nil ? "no accessibility element, target from \(via)" : "not editable: " + trail.joined(separator: "<"))
    }

    private enum FieldKind { case editable, secure, readOnly }

    private func classifyAncestors(of element: AXUIElement, at point: CGPoint, trail: inout [String]) -> FieldKind? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 6, !outOfTime {
            if let kind = classify(node, trail: &trail) { return kind }
            let role = string(node, kAXRoleAttribute)
            if role == kAXScrollAreaRole, depth == 0, let child = editableChild(of: node, containing: point) {
                trail.append("child")
                return classify(child, trail: &trail)
            }
            if role == kAXWindowRole || role == kAXApplicationRole || role == "AXWebArea" { return nil }
            current = copyElement(node, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    /// A click in the padding of a scrolling text view hits the scroll area, not the text itself.
    private func editableChild(of scrollArea: AXUIElement, containing point: CGPoint) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        return children.prefix(8).first { child in
            guard let role = string(child, kAXRoleAttribute), Self.textRoles.contains(role) else { return false }
            return frame(of: child)?.contains(point) == true
        }
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
    /// Electron understands AXManualAccessibility; Chrome and Edge need AXEnhancedUserInterface.
    private func enableAccessibilityIfNeeded(pid: pid_t, app: NSRunningApplication?, appElement: AXUIElement) -> Bool {
        guard !accessibilityEnabledPIDs.contains(pid), isChromiumBased(app) else { return false }
        accessibilityEnabledPIDs.insert(pid)
        let name = app?.bundleIdentifier ?? "\(pid)"
        let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual == .success {
            Log.info("AXManualAccessibility on \(name)")
            return true
        }
        let enhanced = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Log.info("AXManualAccessibility on \(name) -> \(manual.rawValue), AXEnhancedUserInterface -> \(enhanced.rawValue)")
        return enhanced == .success
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

    /// NSCursor is main-thread only; the main thread never waits on this queue, so sync is safe.
    private func isIBeamCursor() -> Bool {
        DispatchQueue.main.sync {
            guard let current = NSCursor.currentSystem else { return false }
            return [NSCursor.iBeam, NSCursor.iBeamCursorForVerticalLayout].contains { Self.looksAlike(current, $0) }
        }
    }

    /// Cursors are compared by shape (aspect ratio and relative hot spot) so an enlarged
    /// accessibility pointer still matches.
    static func looksAlike(_ a: NSCursor, _ b: NSCursor) -> Bool {
        let sa = a.image.size
        let sb = b.image.size
        guard sa.width > 0, sa.height > 0, sb.width > 0, sb.height > 0 else { return false }
        let aspect = abs(sa.width / sa.height - sb.width / sb.height)
        let hotX = abs(a.hotSpot.x / sa.width - b.hotSpot.x / sb.width)
        let hotY = abs(a.hotSpot.y / sa.height - b.hotSpot.y / sb.height)
        return aspect < 0.05 && hotX < 0.08 && hotY < 0.08
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

    static func ownerPID(ofWindow windowNumber: Int) -> pid_t? {
        guard windowNumber > 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let owner = list.first?[kCGWindowOwnerPID as String] as? Int else { return nil }
        return pid_t(owner)
    }

    /// Owner of the frontmost visible window under the point (window server only, no Accessibility).
    static func topWindowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let displays = displayBounds()
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  let owner = info[kCGWindowOwnerPID as String] as? Int,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) >= 0.01 else { continue }
            // Screen-sized windows above the normal level (the Dock keeps one over the whole
            // display) let clicks through; they report alpha 1 but are not click targets.
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer > 0, displays.contains(where: { Self.covers(rect, $0) }) { continue }
            return pid_t(owner)
        }
        return nil
    }

    static func covers(_ window: CGRect, _ display: CGRect) -> Bool {
        window.insetBy(dx: -2, dy: -2).contains(display)
    }

    /// Display frames in CoreGraphics global coordinates (thread-safe, unlike NSScreen).
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }
}
