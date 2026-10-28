import AVFoundation
import AppKit
import SwiftUI

struct OnboardingView: View {
	let onDone: () -> Void

	@ObservedObject private var preferences = Preferences.shared
	@ObservedObject private var notifier = Notifier.shared
	@State private var step = Step.welcome
	@State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
	@State private var systemAudioRequested = false
	@State private var working = false
	@State private var promptCopied = false

	private enum Step: Int, CaseIterable {
		case welcome, microphone, systemAudio, notifications, login, consent, assistant
	}

	var body: some View {
		VStack(spacing: 0) {
			page
				.padding(.horizontal, 40)
				.padding(.top, 36)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			Divider()
			footer
				.padding(.horizontal, 20)
				.padding(.vertical, 14)
		}
		.frame(width: 520, height: 390)
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			microphone = AVCaptureDevice.authorizationStatus(for: .audio)
			Task { await notifier.refreshStatus() }
		}
	}

	@ViewBuilder
	private var page: some View {
		switch step {
		case .welcome:
			StepPage(symbol: "waveform", title: "Welcome to Tiro", text: "Tiro records your calls as audio, on this Mac, as soon as they start. It lives in the menu bar and stays out of the way.") {
				Text(AboutPanel.story)
					.font(.callout)
					.italic()
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
		case .microphone:
			StepPage(symbol: "mic", title: "Your voice", text: "Tiro records your side of the call through the microphone. macOS asks you once.") {
				microphoneAction
			}
		case .systemAudio:
			StepPage(symbol: "speaker.wave.2", title: "The other people on the call", text: "To hear them, Tiro records the sound your Mac plays during the call. macOS calls this System Audio Recording.") {
				systemAudioAction
			}
		case .notifications:
			StepPage(symbol: "bell", title: "Notifications", text: "Tiro tells you when a recording starts and when it is saved. Click a notification to find the file.") {
				notificationsAction
			}
		case .login:
			StepPage(symbol: "power", title: "Open at login", text: "Tiro can only catch a call while it is running. Open it when you log in and you never have to think about it.") {
				Toggle("Open Tiro at login", isOn: $preferences.launchAtLogin)
					.toggleStyle(.switch)
					.fixedSize()
			}
		case .consent:
			StepPage(symbol: "person.2", title: "Before your first call", text: "In many countries, including France, everyone on a call must agree to be recorded. Tell them at the start of the call.") {
				Text("You can pause Tiro from the menu bar at any time.")
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
		case .assistant:
			StepPage(symbol: "sparkles", title: "Ask Claude about your calls", text: "Paste this prompt once into Claude, or any assistant that can read files on this Mac. Then ask it for your last meeting notes.") {
				VStack(spacing: 8) {
					Button(promptCopied ? "Copied" : "Copy Prompt") {
						AssistantPrompt.copy(folder: preferences.recordingsFolder)
						promptCopied = true
					}
					.controlSize(.large)
					Text("You will also find it in Settings, General.")
						.font(.callout)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	// MARK: Actions

	@ViewBuilder
	private var microphoneAction: some View {
		switch microphone {
		case .authorized:
			Granted(text: "Microphone allowed")
		case .notDetermined:
			Button("Allow Microphone") {
				Task {
					let granted = await AVCaptureDevice.requestAccess(for: .audio)
					Log.info("Microphone \(granted ? "allowed" : "declined")")
					microphone = AVCaptureDevice.authorizationStatus(for: .audio)
				}
			}
			.controlSize(.large)
		default:
			VStack(spacing: 10) {
				Text("Microphone access is off. Turn on Tiro in Privacy & Security, Microphone.")
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
				Button("Open System Settings") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
			}
		}
	}

	private var systemAudioAction: some View {
		VStack(spacing: 10) {
			if systemAudioRequested {
				Text("If no prompt appeared, turn on Tiro in Privacy & Security, Screen & System Audio Recording.")
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			} else {
				Button("Allow System Audio") {
					working = true
					Task {
						await CallRecorder.primeSystemAudioPermission()
						working = false
						systemAudioRequested = true
					}
				}
				.controlSize(.large)
				.disabled(working)
			}
			Button("Open System Settings") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") }
				.buttonStyle(.link)
		}
	}

	@ViewBuilder
	private var notificationsAction: some View {
		switch notifier.status {
		case .authorized, .provisional, .ephemeral:
			Granted(text: "Notifications allowed")
		case .notDetermined:
			Button("Allow Notifications") {
				Task { await notifier.requestAuthorization() }
			}
			.controlSize(.large)
		default:
			VStack(spacing: 10) {
				Text("Notifications are off. Tiro still records, but it cannot tell you.")
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
				Button("Open System Settings") { openSettings("x-apple.systempreferences:com.apple.preference.notifications?id=org.animalert.tiro") }
			}
		}
	}

	// MARK: Footer

	private var footer: some View {
		HStack {
			HStack(spacing: 7) {
				ForEach(Step.allCases, id: \.self) { item in
					Circle()
						.fill(item == step ? Color.accentColor : Color.secondary.opacity(0.35))
						.frame(width: 7, height: 7)
				}
			}
			.accessibilityHidden(true)
			Spacer()
			if step != .welcome {
				Button("Back") { move(-1) }
			}
			if step == .assistant {
				Button("Start Using Tiro") { finish() }
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
			} else {
				Button("Continue") { move(1) }
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
					.disabled(!canContinue)
			}
		}
		.controlSize(.large)
	}

	/// The microphone is half of every recording, so its page holds until access is granted. System audio
	/// consent cannot be read back through a public API, so its page only holds until the prompt was triggered.
	private var canContinue: Bool {
		switch step {
		case .microphone: microphone == .authorized
		case .systemAudio: systemAudioRequested
		default: true
		}
	}

	private func move(_ delta: Int) {
		guard let next = Step(rawValue: step.rawValue + delta) else { return }
		withAnimation(.easeInOut(duration: 0.15)) { step = next }
	}

	private func finish() {
		preferences.hasCompletedOnboarding = true
		LoginItem.shared.apply(preferences.launchAtLogin)
		Log.info("Onboarding completed")
		onDone()
	}

	private func openSettings(_ link: String) {
		if let url = URL(string: link) { NSWorkspace.shared.open(url) }
	}
}

private struct StepPage<Action: View>: View {
	let symbol: String
	let title: LocalizedStringKey
	let text: LocalizedStringKey
	@ViewBuilder let action: Action

	var body: some View {
		VStack(spacing: 18) {
			Image(systemName: symbol)
				.font(.system(size: 30, weight: .medium))
				.foregroundStyle(.tint)
				.frame(width: 68, height: 68)
				.background(Circle().fill(Color.accentColor.opacity(0.12)))
			Text(title)
				.font(.title2.weight(.semibold))
			Text(text)
				.font(.body)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
			action
				.padding(.top, 6)
		}
		.frame(maxWidth: .infinity)
	}
}

private struct Granted: View {
	let text: LocalizedStringKey

	var body: some View {
		Label(text, systemImage: "checkmark.circle.fill")
			.foregroundStyle(.green)
			.font(.body.weight(.medium))
	}
}
