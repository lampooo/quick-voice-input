import CoreGraphics
import Foundation
import QuickVoiceCore

/// Reads the HID key state once a second from launch, so a key stuck "down" has already aged out
/// by the time a long press asks whether the keyboard is idle.
final class HeldKeyMonitor {
    static let shared = HeldKeyMonitor()

    private let lock = NSLock()
    private var tracker = HeldKeyTracker()
    private var reportedStale = Set<Int>()
    private var timer: DispatchSourceTimer?

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in _ = self?.heldKeys() }
        self.timer = timer
        timer.resume()
    }

    /// Keys that are down now and have not been down long enough to be stale.
    func heldKeys() -> Set<Int> {
        let down = Self.keysDown()
        lock.lock()
        let reading = tracker.update(down: down, now: ProcessInfo.processInfo.systemUptime)
        let newlyStale = reading.stale.subtracting(reportedStale)
        reportedStale = reading.stale
        let staleAfter = Int(tracker.staleAfter)
        lock.unlock()
        if !newlyStale.isEmpty {
            let codes = newlyStale.sorted().map(String.init).joined(separator: ", ")
            Log.info("ignoring key code \(codes): the system has reported it down for over \(staleAfter)s without a key-up")
        }
        return reading.held
    }

    private static func keysDown() -> Set<Int> {
        var down = Set<Int>()
        // Caps Lock is a lock, not a key being held.
        for code in 0..<128 where code != Int(KeyCode.capsLock) {
            if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) {
                down.insert(code)
            }
        }
        return down
    }
}
