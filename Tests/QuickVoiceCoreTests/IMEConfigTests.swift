import XCTest
@testable import QuickVoiceCore

final class WeTypeConfigTests: XCTestCase {
    /// Mirrors the values read from WeType 2.2.1 on the development Mac.
    private func sampleFile() -> Data {
        var builder = MMKVBuilder()
        builder.int("voicePTTHotKey", 1)
        builder.int("voiceToggleHotKey", 1)
        builder.string("voiceToggleShortcut_keyCodes", "[63,49]")
        builder.int("voiceToggleShortcut_modifiers", 0)
        builder.string("currentVersion", "2.2.1(637)")
        builder.int("commandCandidateShortcut", 0)
        builder.string("voicePTTShortcut_keyCodes", "[58,49]")
        builder.int("voicePTTShortcut_modifiers", 524_288)
        builder.int("voicePTTShortcut_tapCount", 1)
        return builder.data()
    }

    func testVarintRoundTrip() {
        for value: UInt64 in [0, 1, 127, 128, 300, 524_288, 0x00FF_FFFF, UInt64.max] {
            let bytes = MMKVBuilder.varint(value)
            XCTAssertEqual(MMKVReader.readVarint(bytes, 0, bytes.count)?.value, value)
        }
    }

    func testParsesSampleSettings() throws {
        let values = try MMKVReader.parse(sampleFile())
        XCTAssertEqual(values["currentVersion"].flatMap(MMKVReader.string), "2.2.1(637)")
        XCTAssertEqual(values["voicePTTShortcut_modifiers"].flatMap(MMKVReader.int), 524_288)
        XCTAssertEqual(values["voicePTTHotKey"].flatMap(MMKVReader.bool), true)

        let config = WeTypeSettings.parse(values)
        XCTAssertEqual(config.version, "2.2.1(637)")
        XCTAssertEqual(config.pushToTalk, VoiceShortcut(keyCodes: [58, 49], modifierFlags: 524_288, tapCount: 1, enabled: true))
        XCTAssertEqual(config.pushToTalk?.displayName, "左 Option + 空格")
        XCTAssertEqual(config.pushToTalk?.hotkey, HotkeyPreset.optionSpace.hotkey)
        XCTAssertEqual(config.toggle?.keyCodes, [63, 49])
        XCTAssertEqual(config.toggle?.usesFn, true)
        XCTAssertNil(config.toggle?.hotkey)
        XCTAssertEqual(config.commandSelectsCandidates, false)
        XCTAssertNil(config.worksInOtherInputMethods)
    }

    func testLaterRecordsOverrideAndEmptyDeletes() throws {
        var builder = MMKVBuilder()
        builder.string("voicePTTShortcut_keyCodes", "[63]")
        builder.int("voicePTTHotKey", 1)
        builder.string("voicePTTShortcut_keyCodes", "[61]")
        builder.raw("voicePTTHotKey", [])
        let config = WeTypeSettings.parse(try MMKVReader.parse(builder.data()))
        XCTAssertEqual(config.pushToTalk?.keyCodes, [61])
        XCTAssertEqual(config.pushToTalk?.hotkey, HotkeyPreset.rightOption.hotkey)
        XCTAssertNil(config.pushToTalk?.enabled)
    }

    /// Changing the shortcut in WeType appends a cleared record, then the new keys.
    func testClearedThenRerecordedShortcut() throws {
        var builder = MMKVBuilder()
        builder.string("voicePTTShortcut_keyCodes", "[58,49]")
        builder.string("voicePTTShortcut_keyCodes", "[]")
        let cleared = WeTypeSettings.parse(try MMKVReader.parse(builder.data())).pushToTalk
        XCTAssertEqual(cleared?.isCleared, true)
        XCTAssertEqual(cleared?.displayName, "未设置")
        XCTAssertNil(cleared?.hotkey)

        builder.string("voicePTTShortcut_keyCodes", "[61]")
        XCTAssertEqual(WeTypeSettings.parse(try MMKVReader.parse(builder.data())).pushToTalk?.hotkey, Hotkey(modifiers: [.rightOption]))
    }

    func testMultiTapIsNotSynthesizable() throws {
        var builder = MMKVBuilder()
        builder.string("voicePTTShortcut_keyCodes", "[61]")
        builder.int("voicePTTShortcut_tapCount", 2)
        let shortcut = WeTypeSettings.parse(try MMKVReader.parse(builder.data())).pushToTalk
        XCTAssertEqual(shortcut?.tapCount, 2)
        XCTAssertNil(shortcut?.hotkey)
        XCTAssertEqual(shortcut?.displayName, "连按 2 次 右 Option")
    }

    func testMissingKeysGiveEmptyConfig() throws {
        var builder = MMKVBuilder()
        builder.int("SUHasLaunchedBefore", 1)
        XCTAssertEqual(WeTypeSettings.parse(try MMKVReader.parse(builder.data())), IMEVoiceConfig())
    }

    func testTruncatedFileKeepsCompleteRecords() throws {
        var data = sampleFile()
        data = data.prefix(40)
        let size = UInt32(1000)
        data.replaceSubrange(0 ..< 4, with: [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), 0, 0])
        let values = try MMKVReader.parse(data)
        XCTAssertEqual(values["voicePTTHotKey"].flatMap(MMKVReader.int), 1)
        XCTAssertNil(values["currentVersion"])
    }

    func testRejectsTinyFile() {
        XCTAssertThrowsError(try MMKVReader.parse(Data([1, 2])))
    }

    func testAcceptsAnyFourBytePlaceholder() throws {
        var builder = MMKVBuilder(placeholder: 0x0196_8CCC)
        builder.int("a", 1)
        XCTAssertEqual(try MMKVReader.parse(builder.data())["a"].flatMap(MMKVReader.int), 1)
    }

    func testParseKeyCodes() {
        XCTAssertEqual(WeTypeSettings.parseKeyCodes("[58,49]"), [58, 49])
        XCTAssertEqual(WeTypeSettings.parseKeyCodes("[ 61 ]"), [61])
        XCTAssertEqual(WeTypeSettings.parseKeyCodes("[]"), [])
        XCTAssertNil(WeTypeSettings.parseKeyCodes("58,49"))
        XCTAssertNil(WeTypeSettings.parseKeyCodes("[\"a\"]"))
    }

    func testReadsRealWeTypeSettingsIfPresent() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(WeTypeSettings.relativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("WeType is not installed on this machine")
        }
        let config = try IMEVoiceConfig.parse(Data(contentsOf: url), format: .weTypeMMKV)
        XCTAssertNotNil(config.version)
    }
}

final class DoubaoConfigTests: XCTestCase {
    private let rightCommandFlags: Int64 = 0x10_0010
    private let rightOptionFlags: Int64 = 0x8_0040

    /// Same keys and value types as Doubao IME 1.0.0 writes.
    private func archive(longPress: Int, flags: Int64, toggle: Int = 61, toggleEnabled: Bool = true, global: Bool = false) throws -> Data {
        let dictionary: [String: Any] = [
            "asrLongPressShortcutKeyCode": longPress,
            "asrLongPressShortcutModifierFlags": flags,
            "asrLongPressShortcutKeyDisplay": "RightCommand",
            "asrShortcutKeyCode": toggle,
            "asrShortcutModifierFlags": 0,
            "asrShortcutKeyDisplay": "rightoption",
            "isStartASRShortcutEnable": toggleEnabled,
            "useLeftRightCommandToSelectCandidate": false,
            "isGloableASRShortcutEnable": global,
            "offlineASRModeRawValue": "offlineWhenNoNetwork",
        ]
        return try NSKeyedArchiver.archivedData(withRootObject: dictionary as NSDictionary, requiringSecureCoding: true)
    }

    private func parse(_ builder: MMKVBuilder) throws -> IMEVoiceConfig {
        try IMEVoiceConfig.parse(builder.data(), format: .doubaoMMKV)
    }

    /// Replays the history found on the development Mac: Fn, cleared, right Command.
    func testLatestSettingsWin() throws {
        var builder = MMKVBuilder(placeholder: 0x0196_8CCC)
        builder.data("d", try archive(longPress: 63, flags: 0))
        builder.data("d", try archive(longPress: -1, flags: 0))
        builder.data("d", try archive(longPress: 54, flags: rightCommandFlags))
        let config = try parse(builder)
        XCTAssertEqual(config.pushToTalk, VoiceShortcut(keyCodes: [54], modifierFlags: rightCommandFlags))
        XCTAssertEqual(config.pushToTalk?.hotkey, Hotkey(modifiers: [.rightCommand]))
        XCTAssertEqual(config.pushToTalk?.displayName, "右 Command")
        XCTAssertEqual(config.toggle, VoiceShortcut(keyCodes: [61], modifierFlags: 0, enabled: true))
        XCTAssertEqual(config.commandSelectsCandidates, false)
        XCTAssertEqual(config.worksInOtherInputMethods, false)
    }

    func testClearedAndFnShortcuts() throws {
        var cleared = MMKVBuilder(placeholder: 0x0196_8CCC)
        cleared.data("d", try archive(longPress: -1, flags: 0))
        XCTAssertEqual(try parse(cleared).pushToTalk?.isCleared, true)

        var fn = MMKVBuilder(placeholder: 0x0196_8CCC)
        fn.data("d", try archive(longPress: 63, flags: 0))
        let shortcut = try parse(fn).pushToTalk
        XCTAssertEqual(shortcut?.usesFn, true)
        XCTAssertNil(shortcut?.hotkey)
    }

    func testKeyCodesFromFlags() {
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: 54, modifierFlags: rightCommandFlags), [54])
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: 54, modifierFlags: 0x10_0000), [54], "own flag without device bits")
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: 61, modifierFlags: rightOptionFlags), [61])
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: 49, modifierFlags: 0x8_0020), [58, 49], "left Option + Space")
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: 49, modifierFlags: 0x8_0000), [58, 49], "generic Option means the left key")
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: 49, modifierFlags: rightOptionFlags), [61, 49])
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: 61, modifierFlags: rightOptionFlags | rightCommandFlags), [54, 61])
        XCTAssertEqual(DoubaoSettings.keyCodes(keyCode: -1, modifierFlags: 0), [])
    }

    func testGlobalVoiceAndDisabledToggle() throws {
        var builder = MMKVBuilder(placeholder: 0x0196_8CCC)
        builder.data("d", try archive(longPress: 54, flags: rightCommandFlags, toggleEnabled: false, global: true))
        let config = try parse(builder)
        XCTAssertEqual(config.worksInOtherInputMethods, true)
        XCTAssertEqual(config.toggle?.enabled, false)
    }

    func testFindsArchiveAmongOtherValues() throws {
        var builder = MMKVBuilder(placeholder: 0x0196_8CCC)
        builder.string("install_state.install_type", "normal")
        builder.data("d", try archive(longPress: 54, flags: rightCommandFlags))
        XCTAssertEqual(try parse(builder).pushToTalk?.keyCodes, [54])

        var unrelated = MMKVBuilder(placeholder: 0x0196_8CCC)
        unrelated.string("install_state.install_type", "normal")
        XCTAssertThrowsError(try parse(unrelated)) { error in
            XCTAssertEqual(error as? DoubaoSettings.ReadError, .noSettingsDictionary)
        }
    }

    func testLengthPrefixedArchive() throws {
        let archive = try archive(longPress: 54, flags: rightCommandFlags)
        var builder = MMKVBuilder(placeholder: 0x0196_8CCC)
        builder.data("d", Data(MMKVBuilder.varint(UInt64(archive.count))) + archive)
        XCTAssertEqual(try parse(builder).pushToTalk?.keyCodes, [54])
    }

    func testReadsRealDoubaoSettingsIfPresent() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(DoubaoSettings.relativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("Doubao IME is not installed on this machine")
        }
        let config = try IMEVoiceConfig.parse(Data(contentsOf: url), format: .doubaoMMKV)
        XCTAssertNotNil(config.pushToTalk)
    }
}
