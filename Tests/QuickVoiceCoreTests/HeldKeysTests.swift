import XCTest
@testable import QuickVoiceCore

final class HeldKeysTests: XCTestCase {
    func testAFreshKeyIsHeld() {
        var tracker = HeldKeyTracker(staleAfter: 10)
        XCTAssertEqual(tracker.update(down: [], now: 0), .init(held: [], stale: []))
        XCTAssertEqual(tracker.update(down: [56], now: 1), .init(held: [56], stale: []))
        XCTAssertEqual(tracker.update(down: [56], now: 10.9), .init(held: [56], stale: []))
    }

    /// Seen on the dev machine: key code 0 (A) stayed down in the HID state for over an hour,
    /// through real presses of A, and every Bageshuo tap was skipped as「a real key is held down」.
    func testAKeyStuckDownAgesOut() {
        var tracker = HeldKeyTracker(staleAfter: 10)
        _ = tracker.update(down: [0], now: 100)
        XCTAssertEqual(tracker.update(down: [0], now: 105), .init(held: [0], stale: []))
        XCTAssertEqual(tracker.update(down: [0], now: 110), .init(held: [], stale: [0]))
        XCTAssertEqual(tracker.update(down: [0, 49], now: 3_700), .init(held: [49], stale: [0]),
                       "a key pressed now still counts while the stuck one is ignored")
    }

    func testReleasingAKeyStartsItsClockAgain() {
        var tracker = HeldKeyTracker(staleAfter: 10)
        _ = tracker.update(down: [0], now: 0)
        XCTAssertEqual(tracker.update(down: [0], now: 20).stale, [0])
        XCTAssertEqual(tracker.update(down: [], now: 21), .init(held: [], stale: []))
        XCTAssertEqual(tracker.update(down: [0], now: 22), .init(held: [0], stale: []))
    }

    func testTheFirstReadingStartsTheClock() {
        var tracker = HeldKeyTracker()
        XCTAssertEqual(tracker.update(down: [0], now: 5_000), .init(held: [0], stale: []),
                       "without earlier readings a key down now is taken as held")
        XCTAssertEqual(HeldKeyTracker.defaultStaleAfter, 10)
    }
}
