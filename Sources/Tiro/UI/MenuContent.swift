import AppKit
import SwiftUI

struct MenuBarIcon: View {
	@ObservedObject var state: AppState
	@ObservedObject var preferences: Preferences
	@ObservedObject var queue: TranscriptionQueue

	var body: some View {
		Image(systemName: symbol)
			.accessibilityLabel(Text(verbatim: "Tiro"))
	}

	private var symbol: String {
		if state.isFinishing { return "hourglass" }
		if state.isRecording { return "record.circle.fill" }
		if preferences.isPaused { return "pause.circle" }
		if queue.isTranscribing { return "text.bubble" }
		return "waveform"
	}
}

struct MenuContent: View {
	@ObservedObject var state: AppState
	@ObservedObject var preferences: Preferences
	@ObservedObject var queue: TranscriptionQueue
	@Environment(\.openSettings) private var openSettings

	var body: some View {
		Text(state.statusText)
		if queue.isTranscribing {
			if queue.pendingCount > 0 {
				Text("Transcribing · \(queue.pendingCount) waiting")
			} else {
				Text("Transcribing…")
			}
		}
		if !preferences.hasCompletedOnboarding {
			Button("Finish Setting Up Tiro…") { OnboardingWindow.shared.show() }
		}

		Divider()

		if state.isInPerson {
			Button("Stop Recording") { state.stopInPerson() }
		} else {
			Button("Start Recording") { state.startInPerson() }
				.disabled(state.isRecording)
		}

		Divider()

		if preferences.isPaused {
			Button("Resume") { state.resume() }
		} else {
			Button("Pause for 1 Hour") { state.pause(for: 3600) }
			Button("Pause Until Resumed") { state.pause(for: nil) }
		}

		Divider()

		Button("Open Recordings Folder") { state.openRecordingsFolder() }
		Button("Settings…") {
			NSApp.activate()
			openSettings()
		}
		.keyboardShortcut(",")
		Button("About Tiro") { AboutPanel.show() }

		Divider()

		Button("Quit Tiro") { state.quit() }
			.keyboardShortcut("q")
	}
}

enum AboutPanel {
	static let repository = URL(string: "https://github.com/wneel/tiro")!
	static let license = URL(string: "https://github.com/wneel/tiro/blob/main/LICENSE")!
	static let whisper = URL(string: "https://github.com/ggml-org/whisper.cpp")!

	static var story: String {
		String(localized: "Named after Tiro, Cicero's secretary, who sat in on every speech and invented a shorthand to keep up.")
	}

	@MainActor
	static func show() {
		let paragraph = NSMutableParagraphStyle()
		paragraph.alignment = .center
		let attributes: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
			.foregroundColor: NSColor.labelColor,
			.paragraphStyle: paragraph,
		]
		let credits = NSMutableAttributedString(string: story + "\n\n" + String(localized: "A free tool by Animalert, a French non-profit.") + "\n", attributes: attributes)
		var link = attributes
		link[.link] = repository
		credits.append(NSAttributedString(string: "github.com/wneel/tiro", attributes: link))
		NSApp.activate()
		NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
	}
}
