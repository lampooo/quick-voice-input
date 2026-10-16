import XCTest
@testable import QuickVoiceCore

final class BageshuoTests: XCTestCase {
    private func store(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "settings": settings,
            "session": ["token": "must-never-be-read"],
        ] as [String: Any])
    }

    private func parse(_ settings: [String: Any]) throws -> IMEVoiceConfig {
        try BageshuoSettings.parse(try store(settings))
    }

    // MARK: Reading the settings file

    func testLeftCommandIsTheCurrentSetup() throws {
        let config = try parse(["polishHotkey": "LeftCommand", "polishHotkeys": ["LeftCommand"],
                                "translateHotkey": "Fn+LeftShift", "askHotkey": "Fn+Space"])
        XCTAssertEqual(config.toggle, VoiceShortcut(keyCodes: [55]))
        XCTAssertEqual(config.toggle?.hotkey, Hotkey(modifiers: [.leftCommand]))
        XCTAssertEqual(config.toggle?.displayName, "左 Command")
        XCTAssertNil(config.pushToTalk, "Bageshuo has no hold-to-talk shortcut")
        XCTAssertEqual(config.shortcut(for: .tapToggle), config.toggle)
        XCTAssertNil(config.shortcut(for: .hold))
    }

    func testTheListWinsOverTheOlderSingleValue() throws {
        let config = try parse(["polishHotkey": "RightOption", "polishHotkeys": ["LeftOption"]])
        XCTAssertEqual(config.toggle?.hotkey, Hotkey(modifiers: [.leftOption]))
        XCTAssertEqual(try parse(["polishHotkey": "RightOption"]).toggle?.hotkey, Hotkey(modifiers: [.rightOption]))
    }

    func testTheFirstShortcutThatCanBeSynthesizedWins() throws {
        let config = try parse(["polishHotkeys": ["Fn", "mouse4", "RightCommand"]])
        XCTAssertEqual(config.toggle?.hotkey, Hotkey(modifiers: [.rightCommand]))
    }

    func testFnCannotBeSynthesized() throws {
        let fn = try XCTUnwrap(try parse(["polishHotkeys": ["Fn"]]).toggle)
        XCTAssertTrue(fn.usesFn)
        XCTAssertNil(fn.hotkey)
        XCTAssertEqual(fn.displayName, "Fn")
        XCTAssertNil(try XCTUnwrap(try parse(["polishHotkeys": ["Fn+LeftShift"]]).toggle).hotkey)
    }

    func testMouseButtonsCannotBeSynthesized() throws {
        let side = try XCTUnwrap(try parse(["polishHotkeys": ["mouse4"]]).toggle)
        XCTAssertNil(side.hotkey)
        XCTAssertFalse(side.isCleared)
        XCTAssertEqual(side.displayName, "鼠标侧键 4")
        XCTAssertEqual(try XCTUnwrap(try parse(["polishHotkeys": ["mousemiddle"]]).toggle).displayName, "鼠标中键")
        XCTAssertEqual(try XCTUnwrap(try parse(["polishHotkeys": ["LeftShift+mouse5"]]).toggle).displayName, "左 Shift + 鼠标侧键 5")
    }

    func testChordsAndOrdinaryKeys() throws {
        XCTAssertEqual(try parse(["polishHotkeys": ["LeftOption+Space"]]).toggle?.hotkey, Hotkey(modifiers: [.leftOption], key: 49))
        XCTAssertEqual(try parse(["polishHotkeys": ["RightControl+RightOption"]]).toggle?.hotkey,
                       Hotkey(modifiers: [.rightControl, .rightOption]))
        XCTAssertEqual(try parse(["polishHotkeys": ["Command"]]).toggle?.hotkey, Hotkey(modifiers: [.leftCommand]), "no side means the left key is used")
    }

    func testUnknownNamesAreKeptAsTheyAre() throws {
        let shortcut = try XCTUnwrap(try parse(["polishHotkeys": ["Hyper+Banana"]]).toggle)
        XCTAssertNil(shortcut.hotkey)
        XCTAssertEqual(shortcut.displayName, "Hyper+Banana")
    }

    func testMissingOrEmptyShortcutMeansNothingIsRecorded() throws {
        XCTAssertNil(try parse(["language": "zh"]).toggle)
        XCTAssertNil(try parse(["polishHotkeys": []]).toggle)
        let cleared = try XCTUnwrap(try parse(["polishHotkeys": [""]]).toggle)
        XCTAssertTrue(cleared.isCleared)
    }

    func testBrokenFilesAreReportedNotGuessed() throws {
        XCTAssertThrowsError(try BageshuoSettings.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try BageshuoSettings.parse(Data("[1, 2]".utf8)))
        XCTAssertThrowsError(try BageshuoSettings.parse(try JSONSerialization.data(withJSONObject: ["other": 1])))
        XCTAssertThrowsError(try IMEVoiceConfig.parse(Data("{}".utf8), format: .bageshuoJSON))
    }

    func testOnlyTheShortcutIsExtracted() throws {
        let config = try parse(["polishHotkeys": ["LeftCommand"]])
        XCTAssertEqual(config, IMEVoiceConfig(toggle: VoiceShortcut(keyCodes: [55])))
    }

    func testFollowingBageshuoWhenItsKeyChanges() throws {
        let setting = IMEHotkeySetting.standard(for: .bageshuo)
        let before = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": ["LeftCommand"]]))
        XCTAssertEqual(before, HotkeyResolution(ime: .bageshuo, hotkey: Hotkey(modifiers: [.leftCommand]), followsIME: true))
        XCTAssertEqual(before.origin, "跟随网易叭哥说")
        let after = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": ["RightOption"]]))
        XCTAssertEqual(after.hotkey, Hotkey(modifiers: [.rightOption]))
        XCTAssertTrue(after.followsIME)
    }

    // MARK: Resolver fallbacks

    func testFallbacksSayTapNotHold() throws {
        let setting = IMEHotkeySetting.standard(for: .bageshuo)
        let fn = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": ["Fn"]]))
        XCTAssertEqual(fn.hotkey, VoiceIME.bageshuo.defaultHotkey)
        XCTAssertFalse(fn.followsIME)
        XCTAssertEqual(fn.fallbackReason, "网易叭哥说的「语音输入」是「Fn」，Fn 无法被程序模拟，在网易叭哥说里设好快捷键之前不会点按")
        let mouse = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": ["mouse4"]]))
        XCTAssertEqual(mouse.fallbackReason, "网易叭哥说的「语音输入」是「鼠标侧键 4」，程序无法模拟，在网易叭哥说里设好快捷键之前不会点按")
        let missing = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse([:]))
        XCTAssertEqual(missing.fallbackReason, "网易叭哥说没有记录「语音输入」快捷键（默认是 Fn，程序无法模拟），在网易叭哥说里设好快捷键之前不会点按")
        let cleared = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": [""]]))
        XCTAssertEqual(cleared.fallbackReason, "网易叭哥说的「语音输入」快捷键是空的，请先在网易叭哥说里设置它，在网易叭哥说里设好快捷键之前不会点按")
        let unreadable = HotkeyResolver.resolve(setting, ime: .bageshuo, config: nil)
        XCTAssertEqual(unreadable.fallbackReason, "没能读取网易叭哥说的设置，在网易叭哥说里设好快捷键之前不会点按")
    }

    func testAnUnboundChordFallbackIsNotTapped() throws {
        let setting = IMEHotkeySetting(source: .followIME, manual: HotkeyPreset.optionSpace.hotkey)
        let fn = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": ["Fn"]]))
        XCTAssertEqual(fn.fallbackReason, "网易叭哥说的「语音输入」是「Fn」，Fn 无法被程序模拟，在网易叭哥说里设好快捷键之前不会点按")
    }

    func testAChordIsOnlyTappedWhenBageshuoIsBoundToIt() {
        let chord = HotkeyPreset.optionSpace.hotkey
        XCTAssertFalse(VoiceIME.bageshuo.wouldLeakKey(of: chord, bound: chord))
        XCTAssertTrue(VoiceIME.bageshuo.wouldLeakKey(of: chord, bound: nil))
        XCTAssertTrue(VoiceIME.bageshuo.wouldLeakKey(of: chord, bound: Hotkey(modifiers: [.rightOption], key: KeyCode.space)))
        XCTAssertFalse(VoiceIME.bageshuo.wouldLeakKey(of: Hotkey(modifiers: [.leftCommand]), bound: nil), "a lone modifier types nothing")
        XCTAssertFalse(VoiceIME.weType.wouldLeakKey(of: chord, bound: nil), "input methods are judged by their risks instead")
    }

    func testAModifierOnlyFallbackIsStillTapped() throws {
        let setting = IMEHotkeySetting(source: .followIME, manual: Hotkey(modifiers: [.leftCommand]))
        let fn = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": ["Fn"]]))
        XCTAssertEqual(fn.fallbackReason, "网易叭哥说的「语音输入」是「Fn」，Fn 无法被程序模拟，暂时点按「左 Command」")
    }

    // MARK: Recommended chord

    func testTheRecommendedChordIsReadFromBageshuosSettings() throws {
        let config = try parse(["polishHotkeys": ["LeftControl+LeftOption+LeftShift+V"]])
        XCTAssertEqual(config.toggle?.hotkey, VoiceIME.bageshuo.defaultHotkey)
        let followed = HotkeyResolver.resolve(.standard(for: .bageshuo), ime: .bageshuo, config: config)
        XCTAssertEqual(followed, HotkeyResolution(ime: .bageshuo, hotkey: VoiceIME.bageshuo.defaultHotkey, followsIME: true))
        XCTAssertEqual(try parse(["polishHotkeys": ["LeftControl+LeftAlt+V"]]).toggle?.hotkey, HotkeyPreset.controlOptionV.hotkey)
        XCTAssertNotEqual(try parse(["polishHotkeys": ["RightControl+LeftOption+LeftShift+V"]]).toggle?.hotkey, VoiceIME.bageshuo.defaultHotkey,
                          "Bageshuo tells left from right, so a right-hand modifier is a different shortcut")
    }

    func testTheRecommendedChordIsOneCleanTap() {
        let chord = VoiceIME.bageshuo.defaultHotkey
        XCTAssertEqual(chord.displayName, "左 Control + 左 Option + 左 Shift + V")
        XCTAssertEqual(chord.pressSequence.map(\.keyCode), [59, 58, 56, 9])
        XCTAssertEqual(chord.pressSequence.map(\.kind), [.flagsChanged, .flagsChanged, .flagsChanged, .keyDown])
        XCTAssertEqual(chord.releaseSequence.map(\.keyCode), [9, 56, 58, 59])
        let all = EventFlagBits.control | EventFlagBits.option | EventFlagBits.shift
            | EventFlagBits.deviceLeftControl | EventFlagBits.deviceLeftOption | EventFlagBits.deviceLeftShift
        XCTAssertEqual(chord.pressSequence.last?.flags, all | EventFlagBits.nonCoalesced)
        XCTAssertEqual(chord.releaseSequence.last?.flags, EventFlagBits.nonCoalesced)
    }

    func testTheRecommendedChordAvoidsTheOtherEnginesAndMacOS() {
        let chord = VoiceIME.bageshuo.defaultHotkey
        for other in VoiceIME.inputMethods {
            XCTAssertNotEqual(chord, other.defaultHotkey, other.id)
            XCTAssertTrue(Set(chord.modifiers).isDisjoint(with: other.defaultHotkey.modifiers), other.id)
        }
        XCTAssertFalse(chord.modifiers.contains { $0 == .leftCommand || $0 == .rightCommand })
        XCTAssertEqual(VoiceIME.bageshuo.risks(of: chord), [])
        let configs: [VoiceIME: IMEVoiceConfig] = [
            .weType: IMEVoiceConfig(pushToTalk: VoiceShortcut(keyCodes: [61]), toggle: VoiceShortcut(keyCodes: [63, 49]), commandSelectsCandidates: true),
            .doubao: doubaoConfig(commandCandidates: true),
            .bageshuo: IMEVoiceConfig(toggle: VoiceShortcut(keyCodes: [59, 58, 56, 9])),
        ]
        XCTAssertEqual(IMEConflicts.find(hotkey: chord, ime: .bageshuo, configs: configs), [])
    }

    func testOnlyAStandaloneAppSwallowsTheLetterInItsChord() {
        let chord = VoiceIME.bageshuo.defaultHotkey
        XCTAssertEqual(chord.risks, [.mayTriggerShortcut("V")])
        XCTAssertEqual(VoiceIME.weType.risks(of: chord), [.mayTriggerShortcut("V")])
        XCTAssertEqual(VoiceIME.bageshuo.risks(of: Hotkey(modifiers: [.leftControl], key: KeyCode.space)), [.systemShortcut("选择上一个输入法")])
    }

    func testManualHotkeyIgnoresTheFile() throws {
        let setting = IMEHotkeySetting(source: .manual, manual: Hotkey(modifiers: [.rightOption]))
        let result = HotkeyResolver.resolve(setting, ime: .bageshuo, config: try parse(["polishHotkeys": ["LeftCommand"]]))
        XCTAssertEqual(result, HotkeyResolution(ime: .bageshuo, hotkey: Hotkey(modifiers: [.rightOption]), followsIME: false))
    }

    // MARK: Conflicts

    private func doubaoConfig(commandCandidates: Bool, pushToTalk: [Int] = [54]) -> IMEVoiceConfig {
        IMEVoiceConfig(
            pushToTalk: VoiceShortcut(keyCodes: pushToTalk),
            toggle: VoiceShortcut(keyCodes: [61], enabled: true),
            commandSelectsCandidates: commandCandidates,
            worksInOtherInputMethods: false
        )
    }

    private let leftCommand = Hotkey(modifiers: [.leftCommand])

    func testLeftCommandWarnsAboutCandidateSelectionOfAnyInputMethod() {
        let configs: [VoiceIME: IMEVoiceConfig] = [
            .doubao: doubaoConfig(commandCandidates: true),
            .weType: IMEVoiceConfig(pushToTalk: VoiceShortcut(keyCodes: [61]), commandSelectsCandidates: true),
            .bageshuo: IMEVoiceConfig(toggle: VoiceShortcut(keyCodes: [55])),
        ]
        let conflicts = IMEConflicts.find(hotkey: leftCommand, ime: .bageshuo, configs: configs)
        XCTAssertEqual(conflicts.map(\.summary), ["微信输入法开启了「用左右 Command 选候选词」", "豆包输入法开启了「用左右 Command 选候选词」"])
        XCTAssertTrue(conflicts[0].detail.contains("网易叭哥说收不到"))
    }

    func testCommandHintsAreQuietWhenNoInputMethodUsesCommandForCandidates() {
        let configs: [VoiceIME: IMEVoiceConfig] = [
            .doubao: doubaoConfig(commandCandidates: false),
            .bageshuo: IMEVoiceConfig(toggle: VoiceShortcut(keyCodes: [55])),
        ]
        XCTAssertEqual(IMEConflicts.find(hotkey: leftCommand, ime: .bageshuo, configs: configs), [])
        XCTAssertEqual(IMEConflicts.find(hotkey: Hotkey(modifiers: [.leftOption]), ime: .bageshuo,
                                         configs: [.doubao: doubaoConfig(commandCandidates: true)]), [])
    }

    func testOtherEnginesCandidateSettingOnlyMattersForCommandKeys() {
        let configs: [VoiceIME: IMEVoiceConfig] = [.doubao: doubaoConfig(commandCandidates: true)]
        XCTAssertEqual(IMEConflicts.find(hotkey: Hotkey(modifiers: [.rightCommand]), ime: .doubao, configs: configs).map(\.summary),
                       ["豆包输入法开启了「用左右 Command 选候选词」"])
        XCTAssertEqual(IMEConflicts.find(hotkey: Hotkey(modifiers: [.rightOption]), ime: .weType, configs: configs), [])
    }

    func testSharingAKeyWithBageshuoIsReportedBothWays() {
        let configs: [VoiceIME: IMEVoiceConfig] = [
            .doubao: doubaoConfig(commandCandidates: false, pushToTalk: [55]),
            .bageshuo: IMEVoiceConfig(toggle: VoiceShortcut(keyCodes: [55])),
        ]
        let holding = IMEConflicts.find(hotkey: leftCommand, ime: .doubao, configs: configs)
        XCTAssertEqual(holding.map(\.summary), ["网易叭哥说也在用「左 Command」"])
        XCTAssertTrue(holding[0].detail.contains("按住它时会同时唤起网易叭哥说"))
        let tapping = IMEConflicts.find(hotkey: leftCommand, ime: .bageshuo, configs: configs)
        XCTAssertEqual(tapping.map(\.summary), ["「左 Command」也是豆包输入法的语音快捷键"])
    }

    func testBageshuosOwnShortcutIsNotAConflictWithItself() {
        let configs: [VoiceIME: IMEVoiceConfig] = [.bageshuo: IMEVoiceConfig(toggle: VoiceShortcut(keyCodes: [55]))]
        XCTAssertEqual(IMEConflicts.find(hotkey: leftCommand, ime: .bageshuo, configs: configs), [])
    }

    func testSettingsFileFormatIsWiredToTheDescriptor() {
        XCTAssertEqual(VoiceIME.bageshuo.settingsFilePath, "Library/Application Support/com.bageshuo/bageshuo-store.json")
        XCTAssertNil(VoiceIME.bageshuo.settingsAppPath)
        XCTAssertEqual(VoiceIME.bageshuo.bundleIDs, ["com.bageshuo"])
        XCTAssertNil(VoiceIME.bageshuo.versionAdvice("1.0.35"))
    }
}
