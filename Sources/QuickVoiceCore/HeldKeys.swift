import Foundation

/// Which keys the system reports as down, and for how long. A key that has stayed down past
/// `staleAfter` counts as stale rather than held: a key-up that never arrives (seen with a
/// Bluetooth keyboard) leaves the key "down" in the HID state for good, and pressing the same key
/// on another keyboard does not clear it. Nobody holds a key that long while long-pressing the
/// mouse.
public struct HeldKeyTracker: Sendable {
    public static let defaultStaleAfter: TimeInterval = 10

    public struct Reading: Equatable, Sendable {
        public var held: Set<Int>
        public var stale: Set<Int>

        public init(held: Set<Int>, stale: Set<Int>) {
            self.held = held
            self.stale = stale
        }
    }

    public var staleAfter: TimeInterval
    private var downSince: [Int: TimeInterval] = [:]

    public init(staleAfter: TimeInterval = HeldKeyTracker.defaultStaleAfter) {
        self.staleAfter = staleAfter
    }

    /// Records the keys that are down at `now`. A key counts from the first reading that saw it
    /// down, so readings must keep coming while the app runs for a stuck key to age out.
    public mutating func update(down: Set<Int>, now: TimeInterval) -> Reading {
        downSince = downSince.filter { down.contains($0.key) }
        for key in down where downSince[key] == nil {
            downSince[key] = now
        }
        var reading = Reading(held: [], stale: [])
        for key in down {
            if now - (downSince[key] ?? now) >= staleAfter {
                reading.stale.insert(key)
            } else {
                reading.held.insert(key)
            }
        }
        return reading
    }
}
