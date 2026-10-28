import AppKit
import UserNotifications

/// Posts local notifications. Clicking one that carries a file reveals it in Finder.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
	static let shared = Notifier()

	@Published private(set) var status: UNAuthorizationStatus = .notDetermined

	nonisolated private static let pathKey = "path"

	/// UNUserNotificationCenter traps when the process has no bundle (a bare `swift run`).
	private var center: UNUserNotificationCenter? {
		Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
	}

	func configure() {
		center?.delegate = self
		Task { await refreshStatus() }
	}

	func refreshStatus() async {
		guard let center else { return }
		status = await center.notificationSettings().authorizationStatus
	}

	@discardableResult
	func requestAuthorization() async -> Bool {
		guard let center else { return false }
		var granted = false
		do {
			granted = try await center.requestAuthorization(options: [.alert, .sound])
			Log.info("Notifications \(granted ? "allowed" : "declined")")
		} catch {
			Log.error("Notification authorization failed: \(error.localizedDescription)")
		}
		await refreshStatus()
		return granted
	}

	func post(title: String, body: String, revealing file: URL? = nil) {
		Log.info("Notify: \(title) | \(body)")
		guard let center else { return }
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		if let file { content.userInfo = [Self.pathKey: file.path] }
		let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
		center.add(request) { error in
			if let error { Log.error("Notification failed: \(error.localizedDescription)") }
		}
	}

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		if let path = response.notification.request.content.userInfo[Self.pathKey] as? String {
			let url = URL(fileURLWithPath: path)
			DispatchQueue.main.async { Finder.reveal(url) }
		}
		completionHandler()
	}

	// A menu bar app counts as frontmost while its menu or a window is open: show banners anyway.
	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification,
		withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		completionHandler([.banner, .list])
	}
}
