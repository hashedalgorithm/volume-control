import Foundation

/// Timestamped critical/warning/info lines written to a small rotating file under this
/// app's own Application Support directory -- its own internal files, not system
/// Console log (which rolls over and is easy to lose track of by the time anyone looks,
/// as happened trying to find anything about the hang-after-abrupt-shutdown bug this
/// was added to help debug). Also mirrors every call to NSLog, so Console/`log stream`
/// debugging during development is unaffected.
final class ErrorLogger {
    static let shared = ErrorLogger()

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case critical = "CRIT"
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.volumecontrol.errorlogger")
    private static let maxBytesBeforeRotate: UInt64 = 2 * 1024 * 1024

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VolumeControl", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("volumecontrol.log")
    }

    var logFileURL: URL { fileURL }

    func info(_ message: String) { log(message, level: .info) }
    func warning(_ message: String) { log(message, level: .warning) }
    func critical(_ message: String) { log(message, level: .critical) }

    private func log(_ message: String, level: Level) {
        NSLog("VolumeControl[\(level.rawValue)]: \(message)")
        queue.async { [fileURL] in
            Self.rotateIfNeeded(fileURL)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) [\(level.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// One rotation, not a numbered series -- this is a debugging aid for a menu-bar
    /// utility, not a production service log; keeping at most ~4MB on disk total is
    /// plenty to catch a recent incident without it growing unbounded.
    private static func rotateIfNeeded(_ fileURL: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64, size > maxBytesBeforeRotate else { return }
        let rotated = fileURL.deletingLastPathComponent().appendingPathComponent("volumecontrol.log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }

    func clear() {
        queue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
