import AppKit
import ApplicationServices
import QuickVoiceCore

struct CommitReport {
    let ime: VoiceIME
    let bundleID: String?
    let outcome: CommitCheck.Outcome
}

/// After a recording, reads the focused text field's character count for a few seconds to tell
/// whether the input method committed text. Only counts are kept and logged, never the text.
/// Our own test fields are measured through AppKit, not Accessibility (see OwnTestFields).
final class CommitChecker {
    /// Called on the main queue.
    var onReport: ((CommitReport) -> Void)?

    private struct Session {
        let generation: Int
        let target: RecordingTarget?
        let ime: VoiceIME
        let element: AXUIElement?
        let baseline: Int?
    }

    private let queue = DispatchQueue(label: "quickvoice.commit", qos: .utility)
    private let messagingTimeout: Float = 0.25
    private let ownPID = getpid()
    // Queue state.
    private var generation = 0
    private var session: Session?

    /// Call right after the hotkey went down; the count is read before any text can arrive.
    func recordingStarted(target: RecordingTarget?, ime: VoiceIME) {
        queue.async { [self] in
            generation += 1
            let (element, baseline) = focusedField(of: target)
            session = Session(generation: generation, target: target, ime: ime, element: element, baseline: baseline)
        }
    }

    /// Call right after the hotkey was released.
    func recordingEnded() {
        queue.async { [self] in
            guard let finished = session else { return }
            session = nil
            sample(finished, index: 0, releasedAt: .now(), samples: [])
        }
    }

    private func sample(_ session: Session, index: Int, releasedAt: DispatchTime, samples: [CommitCheck.Sample]) {
        // A newer recording types into the same field; its text must not count for this one.
        guard session.generation == generation else {
            report(session, samples, note: " (stopped: a new recording started)")
            return
        }
        let delays = CommitCheck.sampleDelays
        let collected = samples + [CommitCheck.Sample(after: delays[index], length: length(in: session))]
        guard index + 1 < delays.count else {
            report(session, collected, note: "")
            return
        }
        queue.asyncAfter(deadline: releasedAt + delays[index + 1]) { [self] in
            sample(session, index: index + 1, releasedAt: releasedAt, samples: collected)
        }
    }

    private func report(_ session: Session, _ samples: [CommitCheck.Sample], note: String) {
        let outcome = CommitCheck.evaluate(baseline: session.baseline, samples: samples)
        let counts = samples.map { "\(CommitCheck.Outcome.seconds($0.after))s=\($0.length.map(String.init) ?? "?")" }.joined(separator: " ")
        Log.info("commit check \(session.target?.bundleID ?? "?") via \(session.ime.id): before=\(session.baseline.map(String.init) ?? "?") \(counts) -> \(outcome.logDescription)\(note)")
        let report = CommitReport(ime: session.ime, bundleID: session.target?.bundleID, outcome: outcome)
        DispatchQueue.main.async { [weak self] in self?.onReport?(report) }
    }

    private func focusedField(of target: RecordingTarget?) -> (AXUIElement?, Int?) {
        guard let target else { return (nil, nil) }
        if target.pid == ownPID {
            return (nil, DispatchQueue.main.sync { OwnTestFields.shared.focusedTextLength() })
        }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, nil) }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return (element, characterCount(of: element))
    }

    private func length(in session: Session) -> Int? {
        if session.target?.pid == ownPID {
            return DispatchQueue.main.sync { OwnTestFields.shared.focusedTextLength() }
        }
        return session.element.flatMap(characterCount)
    }

    private func characterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
           let count = value as? NSNumber {
            return count.intValue
        }
        // Some fields only expose their value: only its length is kept.
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String {
            return text.utf16.count
        }
        return nil
    }
}
