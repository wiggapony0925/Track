// File-based logger that writes each API call, response JSON,
// and app event to a log.app text file in the Documents directory.
// The log file is cleared on every app launch.
// Best Practices:
// - Uses isDirectory: false for file URLs to avoid blocking I/O
// - Performs file writes asynchronously on a background queue

import Foundation

/// Singleton logger that writes timestamped entries to a persistent log file.
/// The log is cleared on each app launch to keep it fresh.
///
/// Marked `@unchecked Sendable` because all mutable state is protected by the
/// serial `writeQueue` — safe to access from any isolation domain.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    /// Timestamp when the logger (and therefore the app) was first initialized.
    /// Used to measure total elapsed time from app launch to key milestones.
    let launchDate = Date()

    /// Seconds elapsed since app launch.
    nonisolated var timeSinceLaunch: TimeInterval {
        Date().timeIntervalSince(launchDate)
    }

    /// Human-readable elapsed time since app launch (e.g. "2m 10.3s" or "4.5s").
    nonisolated var timeSinceLaunchFormatted: String {
        Self.formatDuration(timeSinceLaunch)
    }

    /// Formats a duration in seconds to a human-readable string.
    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = seconds - Double(mins * 60)
            return "\(mins)m \(String(format: "%.1f", secs))s"
        }
        return "\(String(format: "%.1f", seconds))s"
    }

    private let fileURL: URL
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()
    
    /// Background queue for asynchronous file I/O operations
    private let writeQueue = DispatchQueue(label: "com.track.logger", qos: .utility)

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // Use isDirectory: false to avoid blocking file system check
        fileURL = docs.appendingPathComponent("log.app", isDirectory: false)

        // Clear the log file on every app launch (async to avoid blocking)
        writeQueue.async { [fileURL] in
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        log("APP_LAUNCH", message: "Track app started — log file cleared")
    }

    /// Writes a timestamped log entry to the log file and prints to console.
    ///
    /// - Parameters:
    ///   - tag: Category tag (e.g. "API_REQ", "API_RES", "ERROR")
    ///   - message: The log message
    nonisolated func log(_ tag: String, message: String) {
        let now = Date()
        // Capture the formatter reference once — actual formatting
        // happens on the serial writeQueue to avoid DateFormatter races.
        let fmt = dateFormatter

        // Append to log file asynchronously to avoid blocking main thread
        // Append to log file asynchronously to avoid blocking main thread
        writeQueue.async { [fileURL] in
            let timestamp = fmt.string(from: now)
            let entry = "[\(timestamp)] [\(tag)] \(message)\n"

            // Print to Xcode console (debug builds only)
            #if DEBUG
            print(entry, terminator: "")
            #endif
            guard let data = entry.data(using: .utf8) else { return }
            
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer {
                        do {
                            try handle.close()
                        } catch {
                            // Log close failure to console only (avoid recursive logging)
                            let msg = error.localizedDescription
                            print("[AppLogger] Failed to close file handle: \(msg)")
                        }
                    }
                    handle.seekToEndOfFile()
                    handle.write(data)
                } else {
                    try data.write(to: fileURL)
                }
            } catch {
                // Log write failure to console only (avoid recursive logging)
                print("[AppLogger] Failed to write log: \(error.localizedDescription)")
            }
        }
    }

    /// Logs an API request.
    nonisolated func logRequest(method: String, url: String) {
        log("API_REQ", message: "\(method) \(url)")
    }

    /// Logs an API response with the raw JSON body.
    nonisolated func logResponse(url: String, statusCode: Int, json: String) {
        log("API_RES", message: "[\(statusCode)] \(url)\n  → \(json)")
    }

    /// Logs an error.
    nonisolated func logError(_ context: String, error: Error) {
        log("ERROR", message: "\(context): \(error.localizedDescription)")
    }
}
