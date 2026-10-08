import Foundation
import os
import UIKit

/// Connection and audio-session events, kept where they survive a suspended
/// or relaunched app. Each line goes to the unified log and to a small file
/// in the app's Caches folder, which a Mac can copy from a development build:
/// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer
///  --domain-identifier com.10x.tailview.ios.dev --source Library/Caches/TailView.log
///  --destination TailView.log`
enum DiagnosticLog {
    private static let logger = Logger(subsystem: "com.10x.tailview.ios", category: "Session")
    private static let queue = DispatchQueue(label: "TailView.diagnosticLog")
    private static let maximumBytes = 1_000_000
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TailView.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    /// Call on the main thread, which the app state requires.
    static func note(_ message: String) {
        let state = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        default: "background"
        }
        logger.notice("\(message, privacy: .public) [\(state, privacy: .public)]")
        let line = "\(formatter.string(from: Date())) [\(state)] \(message)\n"
        queue.async { append(line) }
    }

    /// An NSError's domain and code identify iOS refusals such as
    /// `!rec` (cannot start recording) that the description hides.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)\(fourCharacterCode(error.code)): \(error.localizedDescription)"
    }

    private static func fourCharacterCode(_ code: Int) -> String {
        guard code > 0x2020_2020, code <= 0x7E7E_7E7E else { return "" }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return "" }
        return " '\(String(decoding: bytes, as: UTF8.self))'"
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size + data.count > maximumBytes {
            // Keep the newer half instead of growing without bound.
            if let old = try? Data(contentsOf: url) {
                try? old.suffix(maximumBytes / 2).write(to: url)
            }
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
