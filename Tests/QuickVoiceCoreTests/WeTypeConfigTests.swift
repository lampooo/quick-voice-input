import XCTest
@testable import QuickVoiceCore

/// Builds MMKV files the same way MMKV writes them, so the reader is tested against the real layout.
private struct MMKVBuilder {
    private var body: [UInt8] = MMKVBuilder.varint(0x00FF_FFFF)

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    mutating func raw(_ key: String, _ value: [UInt8]) {
        let keyBytes = Array(key.utf8)
        body += MMKVBuilder.varint(UInt64(keyBytes.count)) + keyBytes
        body += MMKVBuilder.varint(UInt64(value.count)) + value
    }

    mutating func int(_ key: String, _ value: Int64) {
        raw(key, MMKVBuilder.varint(UInt64(bitPattern: value)))
    }

    mutating func string(_ key: String, _ value: String) {
        let bytes = Array(value.utf8)
        raw(key, MMKVBuilder.varint(UInt64(bytes.count)) + bytes)
    }

    func data(padding: Int = 64) -> Data {
        let size = UInt32(body.count)
        let header = [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24 & 0xFF)]
        // Bytes after the declared size are stale leftovers and must be ignored.
        return Data(header + body + [UInt8](repeating: 0x41, count: padding))
    }
}

final class WeTypeConfigTests: XCTestCase {
    /// Mirrors the values read from WeType 2.2.1 on the development Mac.
    private func sampleFile() -> Data {
        var builder = MMKVBuilder()
        builder.int("voicePTTHotKey", 1)
        builder.int("voiceToggleHotKey", 1)
        builder.string("voiceToggleShortcut_keyCodes", "[63,49]")
        builder.int("voiceToggleShortcut_modifiers", 0)
        builder.string("currentVersion", "2.2.1(637)")
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

        let config = WeTypeVoiceConfig.parse(values)
        XCTAssertEqual(config.version, "2.2.1(637)")
        XCTAssertEqual(config.pushToTalk, WeTypeShortcut(keyCodes: [58, 49], modifierFlags: 524_288, tapCount: 1, enabled: true))
        XCTAssertEqual(config.pushToTalk?.displayName, "左 Option + 空格")
        XCTAssertEqual(config.pushToTalk?.hotkey, HotkeyPreset.optionSpace.hotkey)
        XCTAssertEqual(config.toggle?.keyCodes, [63, 49])
        XCTAssertEqual(config.toggle?.usesFn, true)
        XCTAssertNil(config.toggle?.hotkey)
    }

    func testLaterRecordsOverrideAndEmptyDeletes() throws {
        var builder = MMKVBuilder()
        builder.string("voicePTTShortcut_keyCodes", "[63]")
        builder.int("voicePTTHotKey", 1)
        builder.string("voicePTTShortcut_keyCodes", "[61]")
        builder.raw("voicePTTHotKey", [])
        let config = WeTypeVoiceConfig.parse(try MMKVReader.parse(builder.data()))
        XCTAssertEqual(config.pushToTalk?.keyCodes, [61])
        XCTAssertEqual(config.pushToTalk?.hotkey, HotkeyPreset.rightOption.hotkey)
        XCTAssertNil(config.pushToTalk?.enabled)
    }

    func testMultiTapIsNotSynthesizable() throws {
        var builder = MMKVBuilder()
        builder.string("voicePTTShortcut_keyCodes", "[61]")
        builder.int("voicePTTShortcut_tapCount", 2)
        let shortcut = WeTypeVoiceConfig.parse(try MMKVReader.parse(builder.data())).pushToTalk
        XCTAssertEqual(shortcut?.tapCount, 2)
        XCTAssertNil(shortcut?.hotkey)
        XCTAssertEqual(shortcut?.displayName, "连按 2 次 右 Option")
    }

    func testMissingKeysGiveEmptyConfig() throws {
        var builder = MMKVBuilder()
        builder.int("SUHasLaunchedBefore", 1)
        XCTAssertEqual(WeTypeVoiceConfig.parse(try MMKVReader.parse(builder.data())), WeTypeVoiceConfig())
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

    func testParseKeyCodes() {
        XCTAssertEqual(WeTypeVoiceConfig.parseKeyCodes("[58,49]"), [58, 49])
        XCTAssertEqual(WeTypeVoiceConfig.parseKeyCodes("[ 61 ]"), [61])
        XCTAssertNil(WeTypeVoiceConfig.parseKeyCodes("58,49"))
        XCTAssertNil(WeTypeVoiceConfig.parseKeyCodes("[\"a\"]"))
    }

    func testReadsRealWeTypeSettingsIfPresent() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(WeTypeVoiceConfig.settingsRelativePath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("WeType is not installed on this machine")
        }
        let config = try WeTypeVoiceConfig.load(fromFile: url)
        XCTAssertNotNil(config.version)
    }
}
