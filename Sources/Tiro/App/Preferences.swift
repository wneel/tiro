import Foundation

/// An app whose microphone use counts as a call. Matched by bundle id prefix, ignoring case, so helper
/// processes (com.google.Chrome.helper, company.thebrowser.browser.helper) count as their parent app.
struct WatchedApp: Codable, Identifiable, Hashable {
	var name: String
	var bundlePrefix: String
	var enabled: Bool
	var id: String { bundlePrefix }

	static let defaults: [WatchedApp] = [
		WatchedApp(name: "Google Chrome", bundlePrefix: "com.google.Chrome", enabled: true),
		WatchedApp(name: "Arc", bundlePrefix: "company.thebrowser", enabled: true),
		WatchedApp(name: "Safari", bundlePrefix: "com.apple.Safari", enabled: true),
		WatchedApp(name: "Safari (WebKit)", bundlePrefix: "com.apple.WebKit", enabled: true),
		WatchedApp(name: "Firefox", bundlePrefix: "org.mozilla.firefox", enabled: true),
		WatchedApp(name: "Brave", bundlePrefix: "com.brave.Browser", enabled: true),
		WatchedApp(name: "Microsoft Edge", bundlePrefix: "com.microsoft.edgemac", enabled: true),
		WatchedApp(name: "Microsoft Teams", bundlePrefix: "com.microsoft.teams", enabled: true),
		WatchedApp(name: "Zoom", bundlePrefix: "us.zoom", enabled: true),
		WatchedApp(name: "FaceTime", bundlePrefix: "com.apple.FaceTime", enabled: true),
		// FaceTime's audio runs in this daemon rather than in the app itself.
		WatchedApp(name: "FaceTime (calls)", bundlePrefix: "com.apple.avconferenced", enabled: true),
		WatchedApp(name: "Slack", bundlePrefix: "com.tinyspeck.slackmacgap", enabled: true),
		WatchedApp(name: "Discord", bundlePrefix: "com.hnc.Discord", enabled: true),
		WatchedApp(name: "WhatsApp", bundlePrefix: "net.whatsapp.WhatsApp", enabled: true),
		WatchedApp(name: "Webex", bundlePrefix: "Cisco-Systems.Spark", enabled: true),
	]
}

/// Every user setting, persisted in UserDefaults. Read from the main thread.
final class Preferences: ObservableObject {
	static let shared = Preferences()
	private let store = UserDefaults.standard

	@Published var recordingsFolder: URL { didSet { store.set(recordingsFolder.path, forKey: "recordingsFolder") } }
	@Published var watchedApps: [WatchedApp] { didSet { store.set(try? JSONEncoder().encode(watchedApps), forKey: "watchedApps") } }
	@Published var transcriptionEnabled: Bool { didSet { store.set(transcriptionEnabled, forKey: "transcriptionEnabled") } }
	/// A `WhisperModel.rawValue`.
	@Published var modelID: String { didSet { store.set(modelID, forKey: "modelID") } }
	/// A ggml model file the user already has; overrides `modelID` when set.
	@Published var customModelPath: String? { didSet { store.set(customModelPath, forKey: "customModelPath") } }
	/// "auto" or an ISO 639-1 code ("fr", "en").
	@Published var language: String { didSet { store.set(language, forKey: "language") } }
	@Published var launchAtLogin: Bool { didSet { store.set(launchAtLogin, forKey: "launchAtLogin") } }
	/// Auto-record is paused while this is in the future. `Date.distantFuture` means until resumed.
	@Published var pausedUntil: Date? { didSet { store.set(pausedUntil, forKey: "pausedUntil") } }
	@Published var hasCompletedOnboarding: Bool { didSet { store.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

	var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }
	var enabledBundlePrefixes: [String] { watchedApps.filter(\.enabled).map(\.bundlePrefix) }

	private init() {
		let home = FileManager.default.homeDirectoryForCurrentUser
		recordingsFolder = store.string(forKey: "recordingsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
			?? home.appendingPathComponent("Tiro", isDirectory: true)
		watchedApps = store.data(forKey: "watchedApps").flatMap { try? JSONDecoder().decode([WatchedApp].self, from: $0) }
			?? WatchedApp.defaults
		transcriptionEnabled = store.bool(forKey: "transcriptionEnabled")
		modelID = store.string(forKey: "modelID") ?? "large-v3-turbo-q5_0"
		customModelPath = store.string(forKey: "customModelPath")
		language = store.string(forKey: "language") ?? "auto"
		launchAtLogin = store.object(forKey: "launchAtLogin") as? Bool ?? true
		pausedUntil = store.object(forKey: "pausedUntil") as? Date
		hasCompletedOnboarding = store.bool(forKey: "hasCompletedOnboarding")
	}

	/// The display name of the watched app a bundle id belongs to, or nil if it is not watched.
	func watchedAppName(forBundleID bundleID: String) -> String? {
		let id = bundleID.lowercased()
		return watchedApps.first { $0.enabled && id.hasPrefix($0.bundlePrefix.lowercased()) }?.name
	}
}
