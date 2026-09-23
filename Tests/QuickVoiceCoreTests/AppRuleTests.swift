import XCTest
@testable import QuickVoiceCore

final class AppRuleTests: XCTestCase {
    private let notes = "com.apple.Notes"
    private let terminal = "com.apple.Terminal"

    func testBlockingIsTheNeverRule() {
        let blocked = AppRules.blocking(notes, in: [:])
        XCTAssertEqual(blocked, [notes: .never])
        XCTAssertEqual(AppRules.rule(for: notes, overrides: blocked), .never)
        XCTAssertTrue(AppRules.isBlocked(notes, overrides: blocked))
        XCTAssertEqual(AppRules.setting(.never, for: notes, in: [:]), blocked, "「不触发」 in the rule menu and the block toggle are the same state")
    }

    func testUnblockRestoresDefaultRule() {
        XCTAssertEqual(AppRules.unblocking(notes, in: [notes: .never]), [:])
        XCTAssertEqual(AppRules.rule(for: notes, overrides: AppRules.unblocking(notes, in: [notes: .never])), .auto)
        let terminalBlocked = AppRules.blocking(terminal, in: [:])
        XCTAssertEqual(terminalBlocked, [terminal: .never])
        XCTAssertEqual(AppRules.rule(for: terminal, overrides: AppRules.unblocking(terminal, in: terminalBlocked)), .anywhere)
    }

    func testUnblockLeavesOtherRulesAlone() {
        let overrides: [String: AppRule] = [notes: .anywhere]
        XCTAssertEqual(AppRules.unblocking(notes, in: overrides), overrides)
    }

    func testRuleEqualToDefaultIsNotStored() {
        XCTAssertEqual(AppRules.setting(.auto, for: notes, in: [notes: .anywhere]), [:])
        XCTAssertEqual(AppRules.setting(.anywhere, for: terminal, in: [terminal: .never]), [:])
        XCTAssertEqual(AppRules.setting(.auto, for: terminal, in: [:]), [terminal: .auto])
    }

    func testChangingRuleReplacesBlock() {
        let blocked = AppRules.blocking(notes, in: [:])
        let anywhere = AppRules.setting(.anywhere, for: notes, in: blocked)
        XCTAssertEqual(anywhere, [notes: .anywhere])
        XCTAssertFalse(AppRules.isBlocked(notes, overrides: anywhere))
    }

    func testAlwaysExcludedAppsCannotBeChanged() {
        let wetype = "com.tencent.inputmethod.wetype"
        XCTAssertFalse(AppRules.canChangeRule(for: wetype))
        XCTAssertEqual(AppRules.setting(.anywhere, for: wetype, in: [:]), [:])
        XCTAssertEqual(AppRules.rule(for: wetype, overrides: [wetype: .anywhere]), .never)
        XCTAssertTrue(AppRules.isBlocked(wetype, overrides: [:]))
        XCTAssertEqual(AppRules.blocking(wetype, in: [:]), [:], "already never; nothing to store")
    }

    func testBlockedListContainsOnlyUserBlockedApps() {
        let overrides: [String: AppRule] = ["com.b": .never, notes: .anywhere, "com.a": .never, terminal: .auto]
        XCTAssertEqual(AppRules.blockedBundleIDs(in: overrides), ["com.a", "com.b"])
    }

    func testLongPressGate() {
        XCTAssertFalse(AppRules.allowsLongPress(bundleID: notes, overrides: [notes: .never]))
        XCTAssertTrue(AppRules.allowsLongPress(bundleID: notes, overrides: [:]))
        XCTAssertTrue(AppRules.allowsLongPress(bundleID: terminal, overrides: [:]))
        XCTAssertTrue(AppRules.allowsLongPress(bundleID: nil, overrides: [notes: .never]), "unknown target: let the probe decide")
        XCTAssertFalse(AppRules.allowsLongPress(bundleID: "com.apple.loginwindow", overrides: [:]))
    }

    func testBlockedPressIsNeverTrackedByTheMachine() {
        var machine = LongPressMachine()
        let allowed = AppRules.allowsLongPress(bundleID: notes, overrides: [notes: .never])
        let output = machine.mouseDown(at: .zero, time: 1, clickCount: 1, modifierFlags: 0, enabled: allowed)
        XCTAssertEqual(output, MachineOutput(), "no probe, no timer, event passes untouched")
        XCTAssertEqual(machine.state, .idle)
    }
}
