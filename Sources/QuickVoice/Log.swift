import Foundation

/// Small append-only file log in ~/Library/Logs/QuickVoiceInput. Never records typed or dictated text.
enum Log {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QuickVoiceInput", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("quickvoice.log")

    private static let queue = DispatchQueue(label: "quickvoice.log", qos: .utility)
    private static let maxBytes: UInt64 = 1_000_000
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: @autoclosure () -> String) {
        let line = "\(formatter.string(from: Date())) \(message())\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64, size > maxBytes {
            let old = directory.appendingPathComponent("quickvoice.1.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: fileURL, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
