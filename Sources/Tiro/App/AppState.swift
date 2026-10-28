import AVFoundation
import AppKit
import Combine

/// Wires detection, recording, transcription and notifications together. Every error is logged and notified, never thrown.
@MainActor
final class AppState: ObservableObject {
	static let shared = AppState()

	@Published private(set) var recordingAppName: String?
	@Published private(set) var recordingStartedAt: Date?
	/// The call app let go of the microphone: nothing is captured, and the file is saved unless the call comes back.
	@Published private(set) var isFinishing = false
	/// An in-person meeting started from the menu: microphone only, stopped from the menu or by long silence.
	@Published private(set) var isInPerson = false
	/// Ticks every second while recording, so the elapsed time redraws.
	@Published private(set) var now = Date()

	let preferences = Preferences.shared
	private let recorder = CallRecorder()
	private var detector: CallDetector?
	private var stopTask: Task<Void, Never>?
	private var timer: Timer?
	private var cancellables = Set<AnyCancellable>()
	private var started = false

	var isRecording: Bool { recordingAppName != nil }

	/// An in-person recording stops by itself after this much silence, in case it was left running.
	static let inPersonSilenceLimit: TimeInterval = 600

	private init() {}

	func start() {
		guard !started else { return }
		started = true
		Log.info("Tiro \(Self.version) started")

		if let until = preferences.pausedUntil, until <= Date() { preferences.pausedUntil = nil }
		ensureFolder(preferences.recordingsFolder)
		wireTranscription()
		observePreferences()
		startTimer()
		if preferences.hasCompletedOnboarding { LoginItem.shared.apply(preferences.launchAtLogin) }

		Task { await recoverLeftovers() }

		let detector = CallDetector(preferences: preferences)
		detector.onCallStarted = { [weak self] call in self?.callStarted(call) }
		detector.onMicrophoneReleased = { [weak self] in self?.microphoneReleased() }
		detector.onMicrophoneRetaken = { [weak self] in self?.microphoneRetaken() }
		detector.onCallEnded = { [weak self] in self?.callEnded() }
		detector.start()
		self.detector = detector
	}

	// MARK: Status

	var statusText: String {
		if isFinishing { return String(localized: "Call ended · saving…") }
		if isInPerson, let start = recordingStartedAt {
			let elapsed = Self.formatDuration(now.timeIntervalSince(start))
			return String(localized: "Recording in person · \(elapsed)")
		}
		if let app = recordingAppName, let start = recordingStartedAt {
			let elapsed = Self.formatDuration(now.timeIntervalSince(start))
			return String(localized: "Recording \(app) · \(elapsed)")
		}
		if preferences.isPaused, let until = preferences.pausedUntil {
			if until == .distantFuture { return String(localized: "Paused until you resume") }
			let time = until.formatted(date: Calendar.current.isDateInToday(until) ? .omitted : .abbreviated, time: .shortened)
			return String(localized: "Paused until \(time)")
		}
		return String(localized: "Waiting for a call")
	}

	static func formatDuration(_ seconds: TimeInterval) -> String {
		let duration = Duration.seconds(max(0, seconds.rounded(.down)))
		return duration.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
	}

	static var version: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
	}

	// MARK: Calls

	private func callStarted(_ call: ActiveCall) {
		if isInPerson {
			Log.info("Call in \(call.appName) not recorded: an in-person recording is running")
			return
		}
		if preferences.isPaused {
			Log.info("Call in \(call.appName) not recorded: Tiro is paused")
			return
		}
		if let stopTask {
			// The previous recording is still being finalized.
			Task {
				await stopTask.value
				if self.detector?.currentCall == call { self.beginRecording(call) }
			}
			return
		}
		beginRecording(call)
	}

	private func microphoneReleased() {
		guard isRecording, !isInPerson else { return }
		recorder.suspend()
		isFinishing = true
	}

	private func microphoneRetaken() {
		guard !isInPerson else { return }
		if isRecording {
			isFinishing = false
			recorder.resume()
		} else if let call = detector?.currentCall {
			// Auto-record was resumed while the call app had let go of the microphone.
			callStarted(call)
		}
	}

	private func callEnded() {
		guard isRecording, !isInPerson else { return }
		stopRecording()
	}

	private func beginRecording(_ call: ActiveCall) {
		guard !isRecording, !preferences.isPaused else { return }
		let folder = preferences.recordingsFolder
		guard ensureFolder(folder) else { return }
		do {
			try recorder.start(appName: call.appName, folder: folder)
			recordingAppName = call.appName
			recordingStartedAt = Date()
			now = Date()
			Log.info("Recording \(call.appName) (\(call.bundleID)) into \(folder.path)")
			let micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
			if !micAllowed { Log.error("Microphone access is off: only the other side is recorded") }
			Notifier.shared.post(
				title: String(localized: "Recording: \(call.appName)"),
				body: micAllowed
					? String(localized: "Tell everyone on the call that it is being recorded.")
					: String(localized: "Microphone access is off, so only the other side is recorded. Turn on Tiro in Privacy & Security, Microphone.")
			)
		} catch {
			Log.error("Could not start recording \(call.appName): \(error.localizedDescription)")
			Notifier.shared.post(
				title: String(localized: "Tiro could not record this call"),
				body: error.localizedDescription
			)
		}
	}

	// MARK: In person

	/// Starts recording the microphone for a meeting in the room. Works while auto-record is paused.
	func startInPerson() {
		guard !isRecording, stopTask == nil else { return }
		let folder = preferences.recordingsFolder
		guard ensureFolder(folder) else { return }
		do {
			try recorder.start(appName: CallRecorder.inPersonName, folder: folder, kind: .inPerson)
			isInPerson = true
			recordingAppName = CallRecorder.inPersonName
			recordingStartedAt = Date()
			now = Date()
			Log.info("Recording in person into \(folder.path)")
		} catch {
			Log.error("Could not start the in-person recording: \(error.localizedDescription)")
			Notifier.shared.post(title: String(localized: "Tiro could not start recording"), body: error.localizedDescription)
		}
	}

	func stopInPerson() {
		guard isInPerson else { return }
		stopRecording()
	}

	private func checkInPersonSilence() {
		guard isInPerson, stopTask == nil, let silence = recorder.secondsSinceVoice(), silence >= Self.inPersonSilenceLimit else { return }
		Log.info("In-person recording stopped after \(Int(silence)) s of silence")
		stopRecording(trimToLastVoice: true)
		Notifier.shared.post(
			title: String(localized: "Recording stopped"),
			body: String(localized: "Nothing was heard for 10 minutes, so Tiro stopped and kept everything up to the last sound.")
		)
	}

	@discardableResult
	private func stopRecording(trimToLastVoice: Bool = false) -> Task<Void, Never> {
		if let stopTask { return stopTask }
		guard let appName = recordingAppName else { return Task {} }
		recordingAppName = nil
		recordingStartedAt = nil
		isFinishing = false
		isInPerson = false
		let task = Task {
			let result = await self.recorder.stop(trimToLastVoice: trimToLastVoice)
			self.stopTask = nil
			self.handleFinished(result, appName: appName)
		}
		stopTask = task
		return task
	}

	/// Stops and saves the current recording, if any.
	func finishRecording() async {
		await stopRecording().value
	}

	private func handleFinished(_ recording: FinishedRecording?, appName: String) {
		guard let recording else {
			Log.info("Recording of \(appName) too short to keep: discarded")
			return
		}
		let file = recording.audioURL.lastPathComponent
		Log.info("Saved \(file) (\(Int(recording.duration)) s)")
		Notifier.shared.post(
			title: String(localized: "Recording saved"),
			body: "\(file) · \(Self.formatDuration(recording.duration))",
			revealing: recording.audioURL
		)
		transcribeIfEnabled(recording.audioURL)
	}

	private func recoverLeftovers() async {
		let recovered = await CallRecorder.recoverLeftovers(in: preferences.recordingsFolder)
		for recording in recovered {
			let file = recording.audioURL.lastPathComponent
			Log.info("Recovered \(file)")
			Notifier.shared.post(
				title: String(localized: "Recording recovered"),
				body: String(localized: "\(file) was saved after Tiro stopped unexpectedly."),
				revealing: recording.audioURL
			)
			transcribeIfEnabled(recording.audioURL)
		}
	}

	// MARK: Transcription

	private func wireTranscription() {
		let queue = TranscriptionQueue.shared
		queue.onFinished = { txtURL in
			Notifier.shared.post(
				title: String(localized: "Transcript ready"),
				body: txtURL.lastPathComponent,
				revealing: txtURL
			)
		}
		queue.onFailed = { audioURL, reason in
			Log.error("Transcription of \(audioURL.lastPathComponent) failed: \(reason)")
			Notifier.shared.post(
				title: String(localized: "Transcription failed"),
				body: "\(audioURL.lastPathComponent): \(reason)",
				revealing: audioURL
			)
		}
	}

	private func transcribeIfEnabled(_ audioURL: URL) {
		guard preferences.transcriptionEnabled else { return }
		guard ModelStore.shared.resolvedModelPath(preferences: preferences) != nil else {
			Log.error("Transcription is on but no model is installed: \(audioURL.lastPathComponent) not transcribed")
			Notifier.shared.post(
				title: String(localized: "No transcription model"),
				body: String(localized: "Download a model in Settings, under Transcription.")
			)
			return
		}
		TranscriptionQueue.shared.enqueue(audioURL, preferences: preferences)
	}

	// MARK: Pause

	/// Pauses auto-record for `duration` seconds, or until resumed when nil. Stops a call recording in
	/// progress; an in-person recording keeps going, since the user started it.
	func pause(for duration: TimeInterval?) {
		let until = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
		preferences.pausedUntil = until
		Log.info(duration == nil ? "Paused until resumed" : "Paused until \(until)")
		if isRecording, !isInPerson {
			Log.info("Pause started during a call: stopping the recording")
			stopRecording()
		}
	}

	/// Resumes auto-record. A call already under way starts recording now, since the user asked for it.
	func resume() {
		preferences.pausedUntil = nil
		Log.info("Resumed")
		if let call = detector?.currentCall, detector?.isMicrophoneHeld == true, !isRecording { callStarted(call) }
	}

	// MARK: Misc

	func openRecordingsFolder() {
		let folder = preferences.recordingsFolder
		if ensureFolder(folder) { Finder.open(folder) }
	}

	func quit() {
		Task {
			await finishRecording()
			Log.info("Quit")
			exit(0)
		}
	}

	@discardableResult
	private func ensureFolder(_ folder: URL) -> Bool {
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			return true
		} catch {
			Log.error("Could not create \(folder.path): \(error.localizedDescription)")
			Notifier.shared.post(
				title: String(localized: "Tiro cannot use the recordings folder"),
				body: Finder.displayPath(folder)
			)
			return false
		}
	}

	private func observePreferences() {
		preferences.$recordingsFolder
			.dropFirst()
			.removeDuplicates()
			.sink { [weak self] folder in
				Log.info("Recordings folder is now \(folder.path)")
				self?.ensureFolder(folder)
			}
			.store(in: &cancellables)

		preferences.$launchAtLogin
			.dropFirst()
			.removeDuplicates()
			.sink { [weak self] enabled in
				guard let self, self.preferences.hasCompletedOnboarding else { return }
				LoginItem.shared.apply(enabled)
			}
			.store(in: &cancellables)
	}

	private func startTimer() {
		let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.tick() }
		}
		timer.tolerance = 0.2
		// Common modes, so the time keeps moving while the menu is open.
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	private func tick() {
		if isRecording, !isFinishing { now = Date() }
		checkInPersonSilence()
		if let until = preferences.pausedUntil, until <= Date() {
			preferences.pausedUntil = nil
			Log.info("Pause ended")
		}
	}
}
