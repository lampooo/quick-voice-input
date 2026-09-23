import XCTest
@testable import QuickVoiceCore

final class HotkeyTests: XCTestCase {
    func testRightOptionUsesFlagsChangedWithDeviceBit() {
        let hotkey = Hotkey(modifiers: [.rightOption])
        XCTAssertEqual(hotkey.pressSequence, [
            KeyStroke(.flagsChanged, keyCode: 61, flags: EventFlagBits.nonCoalesced | EventFlagBits.option | EventFlagBits.deviceRightOption),
        ])
        XCTAssertEqual(hotkey.releaseSequence, [
            KeyStroke(.flagsChanged, keyCode: 61, flags: EventFlagBits.nonCoalesced),
        ])
    }

    func testRightModifiersHaveDistinctKeyCodesAndDeviceBits() {
        XCTAssertEqual(ModifierKey.rightCommand.keyCode, 54)
        XCTAssertEqual(ModifierKey.rightShift.keyCode, 60)
        XCTAssertEqual(ModifierKey.rightControl.keyCode, 62)
        XCTAssertEqual(ModifierKey.rightCommand.deviceFlag, 0x10)
        XCTAssertEqual(ModifierKey.rightShift.deviceFlag, 0x04)
        XCTAssertEqual(ModifierKey.rightControl.deviceFlag, 0x2000)
        XCTAssertEqual(Set(ModifierKey.allCases.map(\.deviceFlag)).count, ModifierKey.allCases.count)
    }

    func testChordPressAndReleaseOrder() {
        let hotkey = Hotkey(modifiers: [.leftControl, .leftOption], key: KeyCode.space)
        let ctrl = EventFlagBits.control | EventFlagBits.deviceLeftControl
        let opt = EventFlagBits.option | EventFlagBits.deviceLeftOption
        let base = EventFlagBits.nonCoalesced
        XCTAssertEqual(hotkey.pressSequence, [
            KeyStroke(.flagsChanged, keyCode: 59, flags: base | ctrl),
            KeyStroke(.flagsChanged, keyCode: 58, flags: base | ctrl | opt),
            KeyStroke(.keyDown, keyCode: 49, flags: base | ctrl | opt),
        ])
        XCTAssertEqual(hotkey.releaseSequence, [
            KeyStroke(.keyUp, keyCode: 49, flags: base | ctrl | opt),
            KeyStroke(.flagsChanged, keyCode: 58, flags: base | ctrl),
            KeyStroke(.flagsChanged, keyCode: 59, flags: base),
        ])
    }

    func testBothShiftsKeepGenericFlagUntilLastRelease() {
        let hotkey = Hotkey(modifiers: [.leftShift, .rightShift])
        let release = hotkey.releaseSequence
        XCTAssertEqual(release[0].keyCode, 60)
        XCTAssertEqual(release[0].flags, EventFlagBits.nonCoalesced | EventFlagBits.shift | EventFlagBits.deviceLeftShift)
        XCTAssertEqual(release[1].flags, EventFlagBits.nonCoalesced)
    }

    func testDisplayNames() {
        XCTAssertEqual(Hotkey(modifiers: [.rightOption]).displayName, "右 Option")
        XCTAssertEqual(Hotkey(modifiers: [.leftOption], key: 49).displayName, "左 Option + 空格")
        XCTAssertEqual(KeyNames.name(for: 63), "Fn")
        XCTAssertEqual(KeyNames.name(for: 999), "键码 999")
    }

    func testFromPhysicalKeyCodes() {
        XCTAssertEqual(Hotkey(physicalKeyCodes: [58, 49]), Hotkey(modifiers: [.leftOption], key: 49))
        XCTAssertEqual(Hotkey(physicalKeyCodes: [61]), Hotkey(modifiers: [.rightOption]))
        XCTAssertEqual(Hotkey(physicalKeyCodes: [54]), Hotkey(modifiers: [.rightCommand]))
        XCTAssertNil(Hotkey(physicalKeyCodes: [63]), "Fn cannot be synthesized")
        XCTAssertNil(Hotkey(physicalKeyCodes: [63, 49]))
        XCTAssertNil(Hotkey(physicalKeyCodes: [57]))
        XCTAssertNil(Hotkey(physicalKeyCodes: [0, 1]), "two ordinary keys")
        XCTAssertNil(Hotkey(physicalKeyCodes: []))
        XCTAssertNil(Hotkey(physicalKeyCodes: [61, 61]))
    }

    func testMatchesIsOrderInsensitive() {
        let hotkey = Hotkey(modifiers: [.leftOption], key: 49)
        XCTAssertTrue(hotkey.matches(keyCodes: [58, 49]))
        XCTAssertTrue(hotkey.matches(keyCodes: [49, 58]))
        XCTAssertFalse(hotkey.matches(keyCodes: [61, 49]))
        XCTAssertFalse(hotkey.matches(keyCodes: [58]))
    }

    func testPresetsAreValidAndUnique() {
        XCTAssertEqual(HotkeyPreset.recommended.id, "rightOption")
        XCTAssertEqual(Set(HotkeyPreset.all.map(\.id)).count, HotkeyPreset.all.count)
        XCTAssertEqual(Set(HotkeyPreset.all.map(\.hotkey)).count, HotkeyPreset.all.count)
        for preset in HotkeyPreset.all {
            XCTAssertTrue(preset.hotkey.isValid, preset.id)
            XCTAssertFalse(preset.hotkey.keyCodes.contains(KeyCode.function), preset.id)
        }
        XCTAssertEqual(HotkeyPreset.matching(Hotkey(modifiers: [.rightOption])), .rightOption)
        XCTAssertNil(HotkeyPreset.matching(Hotkey(modifiers: [.leftCommand])))
    }

    func testHotkeyCodableRoundTrip() throws {
        let hotkey = Hotkey(modifiers: [.rightControl, .rightOption], key: 49)
        let data = try JSONEncoder().encode(hotkey)
        XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: data), hotkey)
    }

    func testTestOutcomeEvaluation() {
        XCTAssertEqual(HotkeyTestOutcome.evaluate(micBusyBefore: true, startLatency: 0.3, stoppedAfterRelease: true), .micBusy)
        XCTAssertEqual(HotkeyTestOutcome.evaluate(micBusyBefore: false, startLatency: nil, stoppedAfterRelease: true), .noResponse)
        XCTAssertEqual(HotkeyTestOutcome.evaluate(micBusyBefore: false, startLatency: 0.3, stoppedAfterRelease: true), .pushToTalk(latency: 0.3))
        XCTAssertEqual(HotkeyTestOutcome.evaluate(micBusyBefore: false, startLatency: 0.3, stoppedAfterRelease: false), .toggle(latency: 0.3))
        XCTAssertTrue(HotkeyTestOutcome.pushToTalk(latency: 0.2).isPushToTalk)
        XCTAssertFalse(HotkeyTestOutcome.toggle(latency: 0.2).isPushToTalk)
    }

    func testAppRules() {
        XCTAssertEqual(AppRules.rule(for: "com.apple.Terminal", overrides: [:]), .anywhere)
        XCTAssertEqual(AppRules.rule(for: "com.apple.Terminal", overrides: ["com.apple.Terminal": .auto]), .auto)
        XCTAssertEqual(AppRules.rule(for: "com.apple.Notes", overrides: [:]), .auto)
        XCTAssertEqual(AppRules.rule(for: "com.apple.Notes", overrides: ["com.apple.Notes": .never]), .never)
        XCTAssertEqual(AppRules.rule(for: "com.apple.loginwindow", overrides: ["com.apple.loginwindow": .anywhere]), .never)
        XCTAssertEqual(AppRules.rule(for: nil, overrides: [:]), .auto)
    }
}
