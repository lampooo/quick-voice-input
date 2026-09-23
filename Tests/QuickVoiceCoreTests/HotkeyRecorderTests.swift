import XCTest
@testable import QuickVoiceCore

final class HotkeyRecorderTests: XCTestCase {
    private let rightOptionDown = EventFlagBits.nonCoalesced | EventFlagBits.option | EventFlagBits.deviceRightOption
    private let leftOptionDown = EventFlagBits.nonCoalesced | EventFlagBits.option | EventFlagBits.deviceLeftOption

    func testSingleModifierFinishesOnRelease() {
        var recorder = HotkeyRecorder()
        XCTAssertEqual(recorder.flagsChanged(keyCode: 61, flags: rightOptionDown), .holding([.rightOption]))
        XCTAssertEqual(recorder.flagsChanged(keyCode: 61, flags: EventFlagBits.nonCoalesced), .finished(Hotkey(modifiers: [.rightOption])))
    }

    func testModifierPlusKeyFinishesOnKeyDown() {
        var recorder = HotkeyRecorder()
        _ = recorder.flagsChanged(keyCode: 58, flags: leftOptionDown)
        XCTAssertEqual(recorder.keyDown(keyCode: 49, isRepeat: false), .finished(Hotkey(modifiers: [.leftOption], key: 49)))
        XCTAssertEqual(recorder.flagsChanged(keyCode: 58, flags: 0), .finished(Hotkey(modifiers: [.leftOption], key: 49)), "later events are ignored")
    }

    func testKeepsPressOrderAndSides() {
        var recorder = HotkeyRecorder()
        let ctrl = EventFlagBits.control | EventFlagBits.deviceRightControl
        _ = recorder.flagsChanged(keyCode: 62, flags: ctrl)
        _ = recorder.flagsChanged(keyCode: 61, flags: ctrl | EventFlagBits.option | EventFlagBits.deviceRightOption)
        _ = recorder.flagsChanged(keyCode: 62, flags: EventFlagBits.option | EventFlagBits.deviceRightOption)
        XCTAssertEqual(recorder.step, .holding([.rightOption]))
        XCTAssertEqual(recorder.flagsChanged(keyCode: 61, flags: 0), .finished(Hotkey(modifiers: [.rightControl, .rightOption])))
    }

    func testReleasedModifierIsNotPartOfLaterChord() {
        var recorder = HotkeyRecorder()
        _ = recorder.flagsChanged(keyCode: 55, flags: EventFlagBits.command | EventFlagBits.deviceLeftCommand)
        _ = recorder.flagsChanged(keyCode: 58, flags: EventFlagBits.command | EventFlagBits.deviceLeftCommand | leftOptionDown)
        _ = recorder.flagsChanged(keyCode: 55, flags: leftOptionDown)
        XCTAssertEqual(recorder.keyDown(keyCode: 49, isRepeat: false), .finished(Hotkey(modifiers: [.leftOption], key: 49)))
    }

    func testSpaceAloneIsAllowed() {
        var recorder = HotkeyRecorder()
        XCTAssertEqual(recorder.keyDown(keyCode: 49, isRepeat: false), .finished(Hotkey(modifiers: [], key: 49)))
    }

    func testRepeatsAreIgnored() {
        var recorder = HotkeyRecorder()
        _ = recorder.flagsChanged(keyCode: 58, flags: leftOptionDown)
        XCTAssertEqual(recorder.keyDown(keyCode: 49, isRepeat: true), .holding([.leftOption]))
    }

    func testEscapeCancelsWhenNothingHeld() {
        var recorder = HotkeyRecorder()
        XCTAssertEqual(recorder.keyDown(keyCode: 53, isRepeat: false), .cancelled)
    }

    func testFnAndCapsLockAreRejected() {
        var fn = HotkeyRecorder()
        if case .rejected = fn.flagsChanged(keyCode: 63, flags: EventFlagBits.secondaryFn) {} else { XCTFail("Fn must be rejected") }
        var caps = HotkeyRecorder()
        if case .rejected = caps.flagsChanged(keyCode: 57, flags: EventFlagBits.alphaShift) {} else { XCTFail("Caps Lock must be rejected") }
    }

    func testGenericFlagsWithoutDeviceBits() {
        XCTAssertTrue(HotkeyRecorder.isDown(.rightOption, flags: EventFlagBits.option))
        XCTAssertFalse(HotkeyRecorder.isDown(.rightOption, flags: EventFlagBits.option | EventFlagBits.deviceLeftOption))
        XCTAssertFalse(HotkeyRecorder.isDown(.rightOption, flags: 0))
    }
}

final class HotkeyRiskAndResolverTests: XCTestCase {
    func testModifierOnlyHotkeysHaveNoRisk() {
        for preset in [HotkeyPreset.rightOption, .rightCommand, .rightControl, .rightShift] {
            XCTAssertEqual(preset.hotkey.risks, [], preset.id)
        }
    }

    func testOptionSpaceMayType() {
        XCTAssertEqual(HotkeyPreset.optionSpace.hotkey.risks, [.mayType("空格")])
    }

    func testSystemSpaceShortcuts() {
        XCTAssertEqual(Hotkey(modifiers: [.leftControl], key: 49).risks, [.systemShortcut("选择上一个输入法"), .mayTriggerShortcut("空格")])
        XCTAssertEqual(Hotkey(modifiers: [.rightCommand], key: 49).risks.first, .systemShortcut("聚焦搜索（Spotlight）"))
        XCTAssertEqual(Hotkey(modifiers: [.leftControl, .leftCommand], key: 49).risks.first, .systemShortcut("表情与符号"))
    }

    func testFunctionKeysMayTriggerShortcuts() {
        XCTAssertEqual(Hotkey(modifiers: [], key: 105).risks, [.mayTriggerShortcut("F13")])
    }

    private func config(_ shortcut: VoiceShortcut?) -> IMEVoiceConfig {
        IMEVoiceConfig(version: "2.2.3(657)", pushToTalk: shortcut)
    }

    func testManualIgnoresWeType() {
        let manual = Hotkey(modifiers: [.rightCommand])
        let result = HotkeyResolver.resolve(IMEHotkeySetting(source: .manual, manual: manual), ime: .weType,
                                            config: config(VoiceShortcut(keyCodes: [58, 49])))
        XCTAssertEqual(result, HotkeyResolution(ime: .weType, hotkey: manual, followsIME: false))
        XCTAssertEqual(result.origin, "手动设置")
    }

    func testFollowUsesWeTypeShortcut() {
        let result = HotkeyResolver.resolve(.standard(for: .weType), ime: .weType,
                                            config: config(VoiceShortcut(keyCodes: [58, 49], modifierFlags: 524_288, tapCount: 1, enabled: true)))
        XCTAssertEqual(result, HotkeyResolution(ime: .weType, hotkey: Hotkey(modifiers: [.leftOption], key: 49), followsIME: true))
        XCTAssertEqual(result.origin, "跟随微信输入法")
    }

    /// The change the user made: WeType's 「按住说话」 moved from ⌥ + Space to right Option.
    func testFollowPicksUpChangedWeTypeShortcut() {
        let setting = IMEHotkeySetting.standard(for: .weType)
        let before = HotkeyResolver.resolve(setting, ime: .weType, config: config(VoiceShortcut(keyCodes: [58, 49])))
        let after = HotkeyResolver.resolve(setting, ime: .weType, config: config(VoiceShortcut(keyCodes: [61], modifierFlags: 524_288)))
        XCTAssertEqual(before.hotkey, HotkeyPreset.optionSpace.hotkey)
        XCTAssertEqual(after.hotkey, HotkeyPreset.rightOption.hotkey)
        XCTAssertTrue(after.followsIME)
    }

    func testFollowFallsBackWhenWeTypeCannotBeSynthesized() {
        let setting = IMEHotkeySetting.standard(for: .weType)
        let cases: [IMEVoiceConfig?] = [
            nil,
            config(nil),
            config(VoiceShortcut(keyCodes: [])),
            config(VoiceShortcut(keyCodes: [63])),
            config(VoiceShortcut(keyCodes: [61], tapCount: 2)),
            config(VoiceShortcut(keyCodes: [61], enabled: false)),
        ]
        for weType in cases {
            let result = HotkeyResolver.resolve(setting, ime: .weType, config: weType)
            XCTAssertEqual(result.hotkey, VoiceIME.weType.defaultHotkey)
            XCTAssertFalse(result.followsIME)
            XCTAssertEqual(result.fallbackReason?.hasSuffix("暂时按住「右 Option」"), true, "\(String(describing: weType))")
        }
    }
}
