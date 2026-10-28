import AppKit

enum Finder {
	/// Selects the file in Finder, or opens its folder when the file is gone.
	static func reveal(_ url: URL) {
		if FileManager.default.fileExists(atPath: url.path) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} else {
			NSWorkspace.shared.open(url.deletingLastPathComponent())
		}
	}

	static func open(_ url: URL) {
		NSWorkspace.shared.open(url)
	}

	/// The path with the home folder shown as ~.
	static func displayPath(_ url: URL) -> String {
		(url.path as NSString).abbreviatingWithTildeInPath
	}

	static let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tiro.log")
}
