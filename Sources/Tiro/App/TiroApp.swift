import AppKit
import SwiftUI

@main
struct TiroApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

	init() {
		Self.exitIfAlreadyRunning()
	}

	var body: some Scene {
		MenuBarExtra {
			MenuContent(state: .shared, preferences: .shared, queue: .shared)
		} label: {
			MenuBarIcon(state: .shared, preferences: .shared, queue: .shared)
		}
		.menuBarExtraStyle(.menu)

		Settings {
			SettingsView()
		}
	}

	/// The launch agent and a double-click in Finder can both start Tiro: the older instance wins.
	private static func exitIfAlreadyRunning() {
		guard let bundleID = Bundle.main.bundleIdentifier else { return }
		let me = NSRunningApplication.current
		let myLaunch = me.launchDate ?? Date()
		let older = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
			$0.processIdentifier != me.processIdentifier && ($0.launchDate ?? .distantPast) <= myLaunch
		}
		if older {
			Log.info("Another Tiro is already running: exiting")
			exit(0)
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		MainActor.assumeIsolated {
			Notifier.shared.configure()
			AppState.shared.start()
			if !Preferences.shared.hasCompletedOnboarding { OnboardingWindow.shared.show() }
		}
	}

	/// Finishes the file on logout or Cmd-Q from a window, so the recording is not left for recovery.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		MainActor.assumeIsolated {
			guard AppState.shared.isRecording else { return .terminateNow }
			Task {
				await AppState.shared.finishRecording()
				sender.reply(toApplicationShouldTerminate: true)
			}
			return .terminateLater
		}
	}
}
