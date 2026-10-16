import XCTest
@testable import QuickVoiceCore

final class VoiceIMETests: XCTestCase {
    private let weTypeSource = "com.tencent.inputmethod.wetype.pinyin"
    private let doubaoSource = "com.bytedance.inputmethod.doubaoime.pinyin"

    func testDescriptorsAreDistinct() {
        XCTAssertEqual(Set(VoiceIME.all.map(\.id)).count, VoiceIME.all.count)
        XCTAssertEqual(Set(VoiceIME.all.flatMap(\.bundleIDs)).count, VoiceIME.all.flatMap(\.bundleIDs).count)
        for ime in VoiceIME.all {
            XCTAssertTrue(ime.defaultHotkey.isValid, ime.id)
            XCTAssertTrue(ime.defaultHotkey.risks.isEmpty, ime.id)
            XCTAssertEqual(ime.inputSourceIDs.isEmpty, ime.isStandalone, "only a standalone app has no input source: \(ime.id)")
            XCTAssertEqual(VoiceIME.withID(ime.id), ime)
        }
        XCTAssertEqual(VoiceIME.doubao.defaultHotkey, Hotkey(modifiers: [.rightCommand]))
        XCTAssertEqual(VoiceIME.weType.defaultHotkey, Hotkey(modifiers: [.rightOption]))
        XCTAssertEqual(VoiceIME.bageshuo.defaultHotkey, Hotkey(modifiers: [.leftCommand]))
        XCTAssertEqual(VoiceIME.inputMethods, [.weType, .doubao])
    }

    func testTriggerModes() {
        XCTAssertEqual(VoiceIME.weType.trigger, .hold)
        XCTAssertEqual(VoiceIME.doubao.trigger, .hold)
        XCTAssertEqual(VoiceIME.bageshuo.trigger, .tapToggle)
        XCTAssertEqual(VoiceIME.bageshuo.kind, .standaloneApp)
        XCTAssertEqual(VoiceTrigger.hold.verb, "按住")
        XCTAssertEqual(VoiceTrigger.tapToggle.verb, "点按")
        XCTAssertEqual(VoiceIME.weType.shortcutName, "按住说话")
        XCTAssertEqual(VoiceIME.bageshuo.shortcutName, "语音输入")
    }

    func testOwnsInputSources() {
        XCTAssertTrue(VoiceIME.weType.owns(sourceID: weTypeSource))
        XCTAssertTrue(VoiceIME.doubao.owns(sourceID: doubaoSource))
        XCTAssertTrue(VoiceIME.doubao.owns(sourceID: "com.bytedance.inputmethod.doubaoime"))
        XCTAssertFalse(VoiceIME.doubao.owns(sourceID: weTypeSource))
        XCTAssertFalse(VoiceIME.weType.owns(sourceID: "com.tencent.inputmethod.wetypeplus.pinyin"))
        XCTAssertFalse(VoiceIME.weType.owns(sourceID: nil))
        XCTAssertEqual(VoiceIME.owning(sourceID: doubaoSource), .doubao)
        XCTAssertNil(VoiceIME.owning(sourceID: "com.apple.keylayout.ABC"))
    }

    func testChoiceStorage() {
        for choice in VoiceIMEChoice.all {
            XCTAssertEqual(VoiceIMEChoice(storedValue: choice.storedValue), choice)
        }
        XCTAssertEqual(VoiceIMEChoice(storedValue: nil), .automatic)
        XCTAssertEqual(VoiceIMEChoice(storedValue: "sogou"), .automatic, "unknown input methods fall back to 自动")
        XCTAssertEqual(VoiceIMEChoice.all.map(\.title), ["自动（跟随当前输入法）", "微信输入法", "豆包输入法", "网易叭哥说"])
    }

    func testStandaloneAppOwnsNoInputSource() {
        for id in [weTypeSource, doubaoSource, "com.bageshuo", "com.bageshuo.pinyin", "com.apple.keylayout.ABC", ""] {
            XCTAssertFalse(VoiceIME.bageshuo.owns(sourceID: id), id)
        }
        XCTAssertNil(VoiceIME.owning(sourceID: "com.bageshuo"))
        XCTAssertTrue(VoiceIME.bageshuo.isStandalone)
        XCTAssertTrue(VoiceIME.bageshuo.inputSourceIDs.isEmpty)
    }

    func testChoosingAStandaloneAppNeedsNoInputMethodSwitch() {
        let selection = VoiceIMESelector.select(.fixed(.bageshuo), in: environment(current: weTypeSource))
        XCTAssertEqual(selection, VoiceIMESelection(ime: .bageshuo, reason: .chosen))
    }

    func testAutomaticOnlyFallsBackToAStandaloneAppWhenNothingElseIsInstalled() {
        let abc = "com.apple.keylayout.ABC"
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: abc, enabled: [], installed: ["wetype", "bageshuo"])),
                       VoiceIMESelection(ime: .weType, reason: .installed))
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: abc, enabled: [], installed: ["bageshuo"])),
                       VoiceIMESelection(ime: .bageshuo, reason: .installed))
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: abc, enabled: ["wetype"], installed: ["wetype", "bageshuo"], lastUsed: "bageshuo")),
                       VoiceIMESelection(ime: .weType, reason: .enabled), "a standalone app is never 「最近用过」: it is not an input source")
    }

    private func environment(current: String?, enabled: Set<String> = ["wetype", "doubao"], installed: Set<String> = ["wetype", "doubao"],
                             lastUsed: String? = nil) -> VoiceIMESelector.Environment {
        VoiceIMESelector.Environment(currentSourceID: current, enabledIDs: enabled, installedIDs: installed, lastUsedID: lastUsed)
    }

    func testFixedChoiceWins() {
        let selection = VoiceIMESelector.select(.fixed(.doubao), in: environment(current: weTypeSource))
        XCTAssertEqual(selection, VoiceIMESelection(ime: .doubao, reason: .chosen))
    }

    func testAutomaticFollowsCurrentInputMethod() {
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: doubaoSource, lastUsed: "wetype")),
                       VoiceIMESelection(ime: .doubao, reason: .current))
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: weTypeSource, lastUsed: "doubao")),
                       VoiceIMESelection(ime: .weType, reason: .current))
    }

    func testAutomaticWithOtherInputMethodUsesLastUsed() {
        let abc = "com.apple.keylayout.ABC"
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: abc, lastUsed: "doubao")),
                       VoiceIMESelection(ime: .doubao, reason: .lastUsed))
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: abc, enabled: ["wetype"], lastUsed: "doubao")),
                       VoiceIMESelection(ime: .weType, reason: .enabled), "last used one was removed from the input sources")
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: abc, enabled: [], installed: ["doubao"])),
                       VoiceIMESelection(ime: .doubao, reason: .installed))
        XCTAssertEqual(VoiceIMESelector.select(.automatic, in: environment(current: abc, enabled: [], installed: [])),
                       VoiceIMESelection(ime: .weType, reason: .fallback))
    }

    func testLegacyWeTypeSettingsMigrate() {
        XCTAssertNil(IMEHotkeySetting.migrated(legacySource: nil, legacyHotkey: nil))
        XCTAssertEqual(IMEHotkeySetting.migrated(legacySource: "followWeType", legacyHotkey: nil), .standard(for: .weType))
        let optionSpace = HotkeyPreset.optionSpace.hotkey
        XCTAssertEqual(IMEHotkeySetting.migrated(legacySource: "manual", legacyHotkey: optionSpace),
                       IMEHotkeySetting(source: .manual, manual: optionSpace))
        XCTAssertEqual(IMEHotkeySetting.migrated(legacySource: nil, legacyHotkey: Hotkey(modifiers: [])),
                       .standard(for: .weType), "an invalid stored hotkey is replaced")
    }

    func testHotkeySettingCodableRoundTrip() throws {
        let settings: [String: IMEHotkeySetting] = [
            "wetype": .standard(for: .weType),
            "doubao": IMEHotkeySetting(source: .manual, manual: Hotkey(modifiers: [.leftOption], key: 49)),
        ]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode([String: IMEHotkeySetting].self, from: data), settings)
    }

    private func doubaoConfig(pushToTalk: [Int], toggle: [Int] = [61], global: Bool = false, commandCandidates: Bool = false) -> IMEVoiceConfig {
        IMEVoiceConfig(
            pushToTalk: VoiceShortcut(keyCodes: pushToTalk),
            toggle: VoiceShortcut(keyCodes: toggle, enabled: true),
            commandSelectsCandidates: commandCandidates,
            worksInOtherInputMethods: global
        )
    }

    func testFollowDoubao() {
        let result = HotkeyResolver.resolve(.standard(for: .doubao), ime: .doubao, config: doubaoConfig(pushToTalk: [54]))
        XCTAssertEqual(result, HotkeyResolution(ime: .doubao, hotkey: Hotkey(modifiers: [.rightCommand]), followsIME: true))
        XCTAssertEqual(result.origin, "跟随豆包输入法")
    }

    func testDoubaoFallbacks() {
        let setting = IMEHotkeySetting.standard(for: .doubao)
        let fn = HotkeyResolver.resolve(setting, ime: .doubao, config: doubaoConfig(pushToTalk: [63]))
        XCTAssertEqual(fn.hotkey, Hotkey(modifiers: [.rightCommand]))
        XCTAssertEqual(fn.fallbackReason, "豆包输入法的「按住说话」是「Fn」，Fn 无法被程序模拟，暂时按住「右 Command」")
        let cleared = HotkeyResolver.resolve(setting, ime: .doubao, config: doubaoConfig(pushToTalk: []))
        XCTAssertEqual(cleared.fallbackReason, "豆包输入法的「按住说话」快捷键是空的，请先在豆包输入法里设置它，暂时按住「右 Command」")
        let unreadable = HotkeyResolver.resolve(setting, ime: .doubao, config: nil)
        XCTAssertEqual(unreadable.fallbackReason, "没能读取豆包输入法的设置，暂时按住「右 Command」")
    }

    /// WeType holds right Option, Doubao holds right Command, Doubao's press-once key is right Option.
    func testCurrentUserSetupHasNoConflicts() {
        let configs: [VoiceIME: IMEVoiceConfig] = [
            .weType: IMEVoiceConfig(pushToTalk: VoiceShortcut(keyCodes: [61]), toggle: VoiceShortcut(keyCodes: [63, 49]), commandSelectsCandidates: false),
            .doubao: doubaoConfig(pushToTalk: [54]),
        ]
        XCTAssertEqual(IMEConflicts.find(hotkey: Hotkey(modifiers: [.rightOption]), ime: .weType, configs: configs), [])
        XCTAssertEqual(IMEConflicts.find(hotkey: Hotkey(modifiers: [.rightCommand]), ime: .doubao, configs: configs), [])
    }

    func testConflicts() {
        let rightOption = Hotkey(modifiers: [.rightOption])
        let rightCommand = Hotkey(modifiers: [.rightCommand])
        let toggle = IMEConflicts.find(hotkey: rightOption, ime: .doubao, configs: [.doubao: doubaoConfig(pushToTalk: [54])])
        XCTAssertEqual(toggle.map(\.summary), ["「右 Option」也是豆包输入法「按一次开始说话」的快捷键"])

        let candidates = IMEConflicts.find(hotkey: rightCommand, ime: .doubao, configs: [.doubao: doubaoConfig(pushToTalk: [54], commandCandidates: true)])
        XCTAssertEqual(candidates.map(\.summary), ["豆包输入法开启了「用左右 Command 选候选词」"])

        let global = IMEConflicts.find(hotkey: rightOption, ime: .weType, configs: [.doubao: doubaoConfig(pushToTalk: [54], global: true)])
        XCTAssertEqual(global.map(\.summary), ["豆包输入法开启了「全局唤起语音」，也在用「右 Option」"])
        XCTAssertEqual(IMEConflicts.find(hotkey: rightOption, ime: .weType, configs: [.doubao: doubaoConfig(pushToTalk: [54], global: false)]), [])
    }

    func testInputMethodsAndTheirSettingsAppsAreAlwaysExcluded() {
        for bundleID in ["com.tencent.inputmethod.wetype", "com.tencent.WeTypeSettings",
                         "com.bytedance.inputmethod.doubaoime", "com.bytedance.inputmethod.doubaoime.settings",
                         "com.bageshuo"] {
            XCTAssertFalse(AppRules.canChangeRule(for: bundleID), bundleID)
            XCTAssertEqual(AppRules.rule(for: bundleID, overrides: [bundleID: .anywhere]), .never, bundleID)
        }
    }
}
