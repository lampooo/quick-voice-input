import Foundation

/// Read-only decoder for unencrypted MMKV files (the key-value store WeType keeps its settings in).
///
/// Layout: a little-endian UInt32 with the used length, then an append-only log of
/// `varint(keyLength) key varint(valueLength) value` records. MMKV starts the log with a
/// placeholder varint (0x00FFFFFF). Later records override earlier ones; an empty value deletes.
public enum MMKVReader {
    public enum ReadError: Error, Equatable {
        case tooShort
        case malformed
    }

    static let itemSizeHolder: UInt64 = 0x00FF_FFFF

    public static func parse(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw ReadError.tooShort }
        let declared = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        let end = min(4 + declared, bytes.count)
        var index = 4
        if let holder = readVarint(bytes, index, end), holder.value == itemSizeHolder {
            index = holder.next
        }
        var result: [String: Data] = [:]
        var parsedAny = false
        while index < end {
            guard let keyLength = readVarint(bytes, index, end),
                  keyLength.next + Int(keyLength.value) <= end else { break }
            let keyBytes = bytes[keyLength.next ..< keyLength.next + Int(keyLength.value)]
            index = keyLength.next + Int(keyLength.value)
            guard let valueLength = readVarint(bytes, index, end),
                  valueLength.next + Int(valueLength.value) <= end else { break }
            let value = Data(bytes[valueLength.next ..< valueLength.next + Int(valueLength.value)])
            index = valueLength.next + Int(valueLength.value)
            parsedAny = true
            guard let key = String(bytes: keyBytes, encoding: .utf8), !key.isEmpty else { continue }
            if value.isEmpty {
                result.removeValue(forKey: key)
            } else {
                result[key] = value
            }
        }
        if !parsedAny && end > index { throw ReadError.malformed }
        return result
    }

    /// Integer and bool values are stored as a bare varint.
    public static func int(_ value: Data) -> Int64? {
        let bytes = [UInt8](value)
        guard let decoded = readVarint(bytes, 0, bytes.count), decoded.next == bytes.count else { return nil }
        return Int64(bitPattern: decoded.value)
    }

    public static func bool(_ value: Data) -> Bool? {
        int(value).map { $0 != 0 }
    }

    /// String values are stored as `varint(length) utf8`.
    public static func string(_ value: Data) -> String? {
        let bytes = [UInt8](value)
        guard let length = readVarint(bytes, 0, bytes.count),
              length.next + Int(length.value) == bytes.count else { return nil }
        return String(bytes: bytes[length.next...], encoding: .utf8)
    }

    static func readVarint(_ bytes: [UInt8], _ start: Int, _ end: Int) -> (value: UInt64, next: Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < end, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
        }
        return nil
    }
}
