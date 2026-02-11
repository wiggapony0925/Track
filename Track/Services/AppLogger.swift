//
//  AppLogger.swift
//  Track
//
//  File-based logger that writes each API call, response JSON,
//  and app event to a log.app text file in the Documents directory.
//  The log file is cleared on every app launch.
//

import Foundation

/// Singleton logger that writes timestamped entries to a persistent log file.
/// The log is cleared on each app launch to keep it fresh.
final class AppLogger {
    static let shared = AppLogger()

    private let fileURL: URL
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("log.app")

        // Clear the log file on every app launch
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        log("APP_LAUNCH", message: "Track app started — log file cleared")
    }

    /// Writes a timestamped log entry to the log file and prints to console.
    ///
    /// - Parameters:
    ///   - tag: Category tag (e.g. "API_REQ", "API_RES", "ERROR")
    ///   - message: The log message
    func log(_ tag: String, message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(tag)] \(message)\n"

        // Print to Xcode console
        print(entry, terminator: "")

        // Append to log file
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Logs an API request.
    func logRequest(method: String, url: String) {
        log("API_REQ", message: "\(method) \(url)")
    }

    /// Logs an API response with the raw JSON body.
    func logResponse(url: String, statusCode: Int, json: String) {
        log("API_RES", message: "[\(statusCode)] \(url)\n  → \(json)")
    }

    /// Logs an error.
    func logError(_ context: String, error: Error) {
        log("ERROR", message: "\(context): \(error.localizedDescription)")
    }
}
