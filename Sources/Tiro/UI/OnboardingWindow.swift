import AppKit
import SwiftUI

/// The first-run window. AppKit-hosted, because SwiftUI cannot open a window at launch from a menu bar app.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
	static let shared = OnboardingWindow()

	private var window: NSWindow?

	func show() {
		if window == nil {
			let hosting = NSHostingController(rootView: OnboardingView { [weak self] in self?.window?.close() })
			hosting.sizingOptions = .preferredContentSize
			let window = NSWindow(contentViewController: hosting)
			window.styleMask = [.titled, .closable, .fullSizeContentView]
			window.titlebarAppearsTransparent = true
			window.titleVisibility = .hidden
			window.title = String(localized: "Welcome to Tiro")
			window.isReleasedWhenClosed = false
			window.delegate = self
			window.center()
			self.window = window
		}
		NSApp.activate()
		// At launch nothing hands activation over to an agent app: bring the window up anyway.
		window?.orderFrontRegardless()
		window?.makeKey()
	}

	func windowWillClose(_ notification: Notification) {
		window = nil
	}
}
