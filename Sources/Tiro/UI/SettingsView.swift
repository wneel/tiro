import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
	var body: some View {
		TabView {
			GeneralSettings(preferences: .shared, loginItem: .shared)
				.tabItem { Label("General", systemImage: "gearshape") }
			AppsSettings(preferences: .shared)
				.tabItem { Label("Apps", systemImage: "app.badge") }
			TranscriptionSettings(preferences: .shared, models: .shared)
				.tabItem { Label("Transcription", systemImage: "text.bubble") }
			AboutSettings()
				.tabItem { Label("About", systemImage: "info.circle") }
		}
		.frame(width: 540)
	}
}

// MARK: General

private struct GeneralSettings: View {
	@ObservedObject var preferences: Preferences
	@ObservedObject var loginItem: LoginItem
	@State private var promptCopied = false

	var body: some View {
		Form {
			Section {
				LabeledContent("Folder") {
					Text(verbatim: Finder.displayPath(preferences.recordingsFolder))
						.lineLimit(1)
						.truncationMode(.middle)
						.textSelection(.enabled)
				}
				HStack {
					Spacer()
					Button("Show in Finder") { AppState.shared.openRecordingsFolder() }
					Button("Change…") { chooseFolder() }
				}
			} header: {
				Text("Recordings")
			} footer: {
				Text("Each call is saved as an audio file, with the transcript next to it when transcription is on.")
					.foregroundStyle(.secondary)
			}

			Section {
				Text(verbatim: AssistantPrompt.text(folder: preferences.recordingsFolder))
					.font(.callout)
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
					.lineLimit(4)
					.truncationMode(.tail)
				HStack {
					if promptCopied {
						Label("Copied", systemImage: "checkmark.circle.fill")
							.foregroundStyle(.green)
					}
					Spacer()
					Button("Copy Prompt") {
						AssistantPrompt.copy(folder: preferences.recordingsFolder)
						promptCopied = true
						Task {
							try? await Task.sleep(for: .seconds(2))
							promptCopied = false
						}
					}
				}
			} header: {
				Text("Use with Claude")
			} footer: {
				Text("Paste this once into Claude, or any assistant that can read files on this Mac, and ask it to remember it. Then just ask for your last meeting notes.")
					.foregroundStyle(.secondary)
			}

			Section("Startup") {
				Toggle("Open Tiro at login", isOn: $preferences.launchAtLogin)
				loginStatus
			}

			Section("Troubleshooting") {
				LabeledContent("Log file") {
					Button("Open") { Finder.open(Finder.logFile) }
				}
			}
		}
		.formStyle(.grouped)
		.frame(height: 560)
		.onAppear { loginItem.refresh() }
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			loginItem.refresh()
		}
	}

	@ViewBuilder
	private var loginStatus: some View {
		if preferences.launchAtLogin, preferences.hasCompletedOnboarding {
			switch loginItem.status {
			case .enabled:
				Text("Tiro opens when you log in, and restarts if it ever stops unexpectedly.")
					.foregroundStyle(.secondary)
			case .requiresApproval:
				HStack {
					Text("Allow Tiro in System Settings, under Login Items.")
						.foregroundStyle(.secondary)
					Spacer()
					Button("Open Login Items") { loginItem.openSystemSettings() }
				}
			default:
				if let error = loginItem.lastError {
					Text(verbatim: error).foregroundStyle(.red)
				}
			}
		}
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.directoryURL = preferences.recordingsFolder
		panel.prompt = String(localized: "Choose")
		panel.message = String(localized: "Choose where Tiro saves your recordings.")
		guard panel.runModal() == .OK, let url = panel.url else { return }
		preferences.recordingsFolder = url
	}
}

// MARK: Apps

private struct AppsSettings: View {
	@ObservedObject var preferences: Preferences

	var body: some View {
		Form {
			Section {
				ForEach($preferences.watchedApps) { $app in
					HStack(spacing: 10) {
						Toggle(isOn: $app.enabled) {
							VStack(alignment: .leading, spacing: 2) {
								Text(verbatim: app.name)
								Text(verbatim: app.bundlePrefix)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						Button {
							remove(app)
						} label: {
							Image(systemName: "minus.circle")
						}
						.buttonStyle(.borderless)
						.foregroundStyle(.secondary)
						.help(Text("Remove"))
					}
				}
			} header: {
				Text("Watched apps")
			} footer: {
				Text("A call starts when one of these apps uses the microphone. Browsers count, so calls in Google Meet or Teams on the web are caught too.")
					.foregroundStyle(.secondary)
			}

			Section {
				HStack {
					Button("Reset to Defaults") { preferences.watchedApps = WatchedApp.defaults }
					Spacer()
					Button("Add App…") { addApps() }
				}
			}
		}
		.formStyle(.grouped)
		.frame(height: 520)
	}

	private func remove(_ app: WatchedApp) {
		preferences.watchedApps.removeAll { $0.id == app.id }
	}

	private func addApps() {
		let panel = NSOpenPanel()
		panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
		panel.allowedContentTypes = [.application]
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.prompt = String(localized: "Add")
		panel.message = String(localized: "Choose the apps you make calls with.")
		guard panel.runModal() == .OK else { return }
		for url in panel.urls {
			guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
				Log.error("No bundle id in \(url.path)")
				continue
			}
			if let index = preferences.watchedApps.firstIndex(where: { bundleID.hasPrefix($0.bundlePrefix) }) {
				preferences.watchedApps[index].enabled = true
				continue
			}
			let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
				?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
				?? url.deletingPathExtension().lastPathComponent
			preferences.watchedApps.append(WatchedApp(name: name, bundlePrefix: bundleID, enabled: true))
			Log.info("Watching \(name) (\(bundleID))")
		}
	}
}

// MARK: Transcription

private struct TranscriptionSettings: View {
	@ObservedObject var preferences: Preferences
	@ObservedObject var models: ModelStore

	private static let languages: [(code: String, name: String)] = [
		("fr", "Français"),
		("en", "English"),
		("es", "Español"),
		("de", "Deutsch"),
		("it", "Italiano"),
		("pt", "Português"),
		("nl", "Nederlands"),
	]

	var body: some View {
		Form {
			Section {
				Toggle("Transcribe recordings", isOn: $preferences.transcriptionEnabled)
			} footer: {
				Text("Everything stays on this Mac: the audio and the transcript never leave it.")
					.foregroundStyle(.secondary)
			}

			Section {
				Picker("Model", selection: $preferences.modelID) {
					ForEach(WhisperModel.allCases) { model in
						Text(verbatim: model.displayName).tag(model.rawValue)
					}
				}
				.disabled(preferences.customModelPath != nil)
				ForEach(WhisperModel.allCases) { model in
					ModelRow(model: model, models: models)
				}
				if let error = models.lastError {
					Text(verbatim: error)
						.foregroundStyle(.red)
				}
			} header: {
				Text("Models")
			} footer: {
				Text("Larger models are more accurate and slower. A model is downloaded only when you ask for it.")
					.foregroundStyle(.secondary)
			}

			Section {
				LabeledContent("Model file") {
					if let path = preferences.customModelPath {
						Text(verbatim: Finder.displayPath(URL(fileURLWithPath: path)))
							.lineLimit(1)
							.truncationMode(.middle)
					} else {
						Text("None")
							.foregroundStyle(.secondary)
					}
				}
				HStack {
					Spacer()
					if preferences.customModelPath != nil {
						Button("Stop Using It") { preferences.customModelPath = nil }
					}
					Button("Choose…") { chooseModelFile() }
				}
			} header: {
				Text("Use a model file I already have")
			} footer: {
				Text("A whisper.cpp model in ggml format (.bin). When set, it replaces the model above.")
					.foregroundStyle(.secondary)
			}

			Section {
				Picker("Language", selection: $preferences.language) {
					Text("Automatic").tag("auto")
					Divider()
					ForEach(Self.languages, id: \.code) { language in
						Text(verbatim: language.name).tag(language.code)
					}
				}
			} footer: {
				Text("Automatic detects the language of each call. Pick one if your calls are always in the same language.")
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.frame(height: 560)
	}

	private func chooseModelFile() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		// Models usually live in hidden folders (~/.cache/whisper-cpp, ~/.cache/whisper), which the panel hides.
		panel.showsHiddenFiles = true
		let home = FileManager.default.homeDirectoryForCurrentUser
		panel.directoryURL = ["~/.cache/whisper-cpp", "~/.cache/whisper", "~/.cache"]
			.map { home.appendingPathComponent(String($0.dropFirst(2)), isDirectory: true) }
			.first { FileManager.default.fileExists(atPath: $0.path) } ?? home
		panel.prompt = String(localized: "Use This Model")
		panel.message = String(localized: "Choose a whisper.cpp model file (.bin).")
		guard panel.runModal() == .OK, let url = panel.url else { return }
		preferences.customModelPath = url.path
		Log.info("Custom model: \(url.path)")
	}
}

private struct ModelRow: View {
	let model: WhisperModel
	@ObservedObject var models: ModelStore
	@State private var confirmingDelete = false

	var body: some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text(verbatim: model.displayName)
				if !model.approximateSize.isEmpty {
					Text(verbatim: model.approximateSize)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			if let progress = models.downloadProgress[model] {
				ProgressView(value: min(max(progress, 0), 1))
					.frame(width: 120)
				Button("Cancel") { models.cancelDownload(model) }
			} else if models.isInstalled(model) {
				Label("Downloaded", systemImage: "checkmark.circle.fill")
					.foregroundStyle(.secondary)
				Button("Delete…") { confirmingDelete = true }
			} else {
				Button("Download") { Task { await models.download(model) } }
			}
		}
		.confirmationDialog(Text("Delete \(model.displayName)?"), isPresented: $confirmingDelete) {
			Button("Delete", role: .destructive) {
				models.delete(model)
				models.objectWillChange.send()
			}
		} message: {
			Text("You can download it again later.")
		}
	}
}

// MARK: About

private struct AboutSettings: View {
	private var build: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
	}

	var body: some View {
		VStack(spacing: 14) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.frame(width: 72, height: 72)
			VStack(spacing: 4) {
				Text(verbatim: "Tiro")
					.font(.title.weight(.semibold))
				Text("Version \(AppState.version) (\(build))")
					.foregroundStyle(.secondary)
			}
			Text(AboutPanel.story)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
			Text("A free tool by Animalert, a French non-profit.")
				.foregroundStyle(.secondary)
			HStack(spacing: 18) {
				Link("Source code on GitHub", destination: AboutPanel.repository)
				Link("MIT License", destination: AboutPanel.license)
			}
			Divider()
				.frame(width: 200)
			Text("Transcription by [whisper.cpp](https://github.com/ggml-org/whisper.cpp), MIT License.")
				.font(.caption)
			.foregroundStyle(.secondary)
		}
		.padding(32)
		.frame(maxWidth: .infinity)
		.frame(height: 400)
	}
}
