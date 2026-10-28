import Foundation
import ServiceManagement

/// The launch agent bundled in Contents/Library/LaunchAgents. It keeps Tiro running and relaunches it after a crash.
@MainActor
final class LoginItem: ObservableObject {
	static let shared = LoginItem()

	@Published private(set) var status: SMAppService.Status = .notRegistered
	@Published private(set) var lastError: String?

	private let service = SMAppService.agent(plistName: "org.animalert.tiro.agent.plist")

	private init() { refresh() }

	func refresh() {
		status = service.status
	}

	/// Registers or unregisters the agent so it matches the setting.
	func apply(_ enabled: Bool) {
		guard Bundle.main.bundleIdentifier != nil else { return }
		refresh()
		do {
			if enabled {
				if status == .notRegistered || status == .notFound {
					try service.register()
					Log.info("Login item registered")
				}
			} else if status == .enabled || status == .requiresApproval {
				try service.unregister()
				Log.info("Login item unregistered")
			}
			lastError = nil
		} catch {
			lastError = error.localizedDescription
			Log.error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
		}
		refresh()
	}

	func openSystemSettings() {
		SMAppService.openSystemSettingsLoginItems()
	}
}
