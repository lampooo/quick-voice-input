import Foundation

/// Builds MMKV files the same way MMKV writes them, so the reader is tested against the real layout.
struct MMKVBuilder {
    private var body: [UInt8]

    /// WeType's files start with 0x00FFFFFF; Doubao's with other, per-install 4-byte values.
    init(placeholder: UInt64 = 0x00FF_FFFF) {
        body = MMKVBuilder.varint(placeholder)
    }

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

    /// Objects and NSData values are stored as their raw bytes.
    mutating func data(_ key: String, _ value: Data) {
        raw(key, [UInt8](value))
    }

    func data(padding: Int = 64) -> Data {
        let size = UInt32(body.count)
        let header = [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24 & 0xFF)]
        // Bytes after the declared size are stale leftovers and must be ignored.
        return Data(header + body + [UInt8](repeating: 0x41, count: padding))
    }
}
