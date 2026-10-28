import Foundation
import os

/// Writes to the unified log and to ~/Library/Logs/Tiro.log, so a user can attach the file to a bug report.
enum Log {
	private static let logger = Logger(subsystem: "org.animalert.tiro", category: "app")
	private static let queue = DispatchQueue(label: "org.animalert.tiro.log")
	private static let fileURL: URL = {
		let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("Tiro.log")
	}()
	private static let stamp: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()

	static func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .public)") }
	static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

	private static func write(_ level: String, _ message: String) {
		let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
		queue.async {
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
}
