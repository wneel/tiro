import CoreAudio
import Foundation

struct FinishedRecording {
	let audioURL: URL
	let appName: String
	let startedAt: Date
	let duration: TimeInterval
}

/// Records one call: the default microphone on the left channel, every other process's audio output on
/// the right, into a crash-safe CAF under `<folder>/.inprogress/`, then an AAC .m4a in `<folder>` on stop.
///
/// Thread-safe. Meant to be driven from the main actor: `start` blocks for the ~50 ms Core Audio setup,
/// `stop` suspends while the file is finalised and encoded off the main thread.
final class CallRecorder {
	/// A call is detected; an in-person meeting is started from the menu and records the microphone only.
	enum Kind {
		case call, inPerson
	}

	static let minimumDuration: TimeInterval = 15
	/// Started on purpose, so only an accidental click is thrown away.
	static let inPersonMinimumDuration: TimeInterval = 3
	/// The name in-person files carry in place of an app, which is also how a leftover is recognised.
	static let inPersonName = "Meeting"
	/// Kept after the last sound when the silence stop trims the end.
	static let silenceTail: TimeInterval = 2
	static let inProgressFolderName = ".inprogress"

	var isRecording: Bool { locked { current != nil } }
	var startedAt: Date? { locked { current?.startedAt } }

	private let lock = NSLock()
	private var current: Recording?
	private var starting = false
	private let control = DispatchQueue(label: "org.animalert.tiro.capture", qos: .userInitiated)

	/// Serial: encoding after `stop` and `recoverLeftovers` never work on the same file at once.
	private static let conversionQueue = DispatchQueue(label: "org.animalert.tiro.conversion", qos: .utility)
	private static let busyLock = NSLock()
	private static var busyFiles = Set<String>()

	/// Mutable state is only touched on the control queue.
	private final class Recording: @unchecked Sendable {
		let kind: Kind
		let appName: String
		let startedAt: Date
		let folder: URL
		let tempURL: URL
		let writer: CafWriter
		var session: CaptureSession?
		var systemListeners: [PropertyListener] = []
		var pendingRebuild: DispatchWorkItem?
		var stallRetries = 0
		var failedRebuilds = 0
		var stopped = false
		var suspended = false

		init(kind: Kind, appName: String, startedAt: Date, folder: URL, tempURL: URL, writer: CafWriter) {
			self.kind = kind
			self.appName = appName
			self.startedAt = startedAt
			self.folder = folder
			self.tempURL = tempURL
			self.writer = writer
		}
	}

	init() {}

	func start(appName: String, folder: URL, kind: Kind = .call) throws {
		try locked {
			guard current == nil, !starting else { throw CaptureError.alreadyRecording }
			starting = true
		}
		defer { locked { starting = false } }

		let startedAt = Date()
		let inProgress = folder.appendingPathComponent(Self.inProgressFolderName, isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: inProgress, withIntermediateDirectories: true)
		} catch {
			throw CaptureError.file("Cannot create \(inProgress.path): \(error.localizedDescription)")
		}
		let tempURL = RecordingName.unique(in: inProgress, base: RecordingName.base(startedAt: startedAt, appName: appName), ext: "caf")
		_ = Self.claim(tempURL)
		let writer: CafWriter
		do {
			writer = try CafWriter(url: tempURL)
		} catch {
			Self.release(tempURL)
			throw error
		}
		let recording = Recording(kind: kind, appName: appName, startedAt: startedAt, folder: folder, tempURL: tempURL, writer: writer)
		writer.onStall = { [weak self, weak recording] reason in
			guard let self, let recording else { return }
			self.control.async { self.handleStall(recording, reason: reason) }
		}
		do {
			try control.sync {
				let session = try makeSession(for: recording)
				writer.attach(session.ring)
				do {
					try session.start()
				} catch {
					session.invalidate()
					writer.detach()
					throw error
				}
				recording.session = session
				installSystemListeners(for: recording)
				Log.info("Recording \(appName) to \(tempURL.lastPathComponent): \(session.summary)")
			}
		} catch {
			writer.abandon()
			Self.release(tempURL)
			Log.error("Recording could not start: \(error.localizedDescription)")
			throw error
		}
		locked { current = recording }
	}

	/// Lets go of the microphone and the tap while keeping the file open, for when the call app has released
	/// the microphone but the call may still come back (a reconnect, a headset switch). Nothing is recorded
	/// until `resume`, and the macOS microphone indicator goes off with the call app's.
	func suspend() {
		guard let recording = locked({ current }) else { return }
		control.async {
			guard !recording.stopped, !recording.suspended else { return }
			recording.suspended = true
			recording.pendingRebuild?.cancel()
			recording.pendingRebuild = nil
			recording.session?.invalidate()
			recording.session = nil
			recording.writer.detach()
			Log.info("Capture suspended: the call app released the microphone")
		}
	}

	/// Starts capturing again into the same file. The pause is written as silence, so the file keeps
	/// following wall-clock time.
	func resume() {
		guard let recording = locked({ current }) else { return }
		control.async {
			guard !recording.stopped, recording.suspended else { return }
			recording.suspended = false
			recording.stallRetries = 0
			self.rebuild(recording, reason: "the call app took the microphone back")
		}
	}

	/// Seconds since the microphone last carried sound in the current recording, or nil when idle.
	func secondsSinceVoice() -> TimeInterval? {
		locked { current }?.writer.secondsSinceVoice()
	}

	/// Stops capture and returns the saved .m4a, or nil when it was too short to keep (its file is deleted).
	/// With `trimToLastVoice`, the saved file ends shortly after the microphone last carried sound.
	func stop(trimToLastVoice: Bool = false) async -> FinishedRecording? {
		let recording: Recording? = locked {
			let recording = current
			current = nil
			return recording
		}
		guard let recording else { return nil }
		return await withCheckedContinuation { continuation in
			control.async {
				recording.stopped = true
				recording.pendingRebuild?.cancel()
				recording.systemListeners.forEach { $0.remove() }
				recording.systemListeners = []
				recording.session?.invalidate()
				recording.session = nil
				let summary = recording.writer.finish()
				Self.conversionQueue.async {
					defer { Self.release(recording.tempURL) }
					continuation.resume(returning: Self.finalize(recording, summary: summary, trimToLastVoice: trimToLastVoice))
				}
			}
		}
	}

	/// Encodes every CAF a crash left in `<folder>/.inprogress/` (except one being recorded right now).
	static func recoverLeftovers(in folder: URL) async -> [FinishedRecording] {
		await withCheckedContinuation { continuation in
			conversionQueue.async { continuation.resume(returning: recover(in: folder)) }
		}
	}

	/// Runs a system-audio tap for half a second so macOS asks for the System Audio Recording permission.
	/// It does not touch the microphone.
	static func primeSystemAudioPermission() async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			DispatchQueue.global(qos: .userInitiated).async {
				do {
					let session = try CaptureSession.make(includeMicrophone: false, queue: DispatchQueue(label: "org.animalert.tiro.prime"), onTrouble: { _ in })
					defer { session.invalidate() }
					try session.start()
					Thread.sleep(forTimeInterval: 0.5)
					Log.info("System audio tap primed (\(session.ring.load(.callbacks)) callbacks)")
				} catch {
					Log.error("Priming the system audio tap failed: \(error.localizedDescription)")
				}
				continuation.resume()
			}
		}
	}

	// MARK: - Control queue

	private func makeSession(for recording: Recording) throws -> CaptureSession {
		let onTrouble: (String) -> Void = { [weak self, weak recording] reason in
			guard let self, let recording else { return }
			self.scheduleRebuild(recording, reason: reason, delay: 0.4)
		}
		do {
			return try CaptureSession.make(includeMicrophone: true, queue: control, onTrouble: onTrouble)
		} catch {
			Log.error("Capture with the microphone failed (\(error.localizedDescription)); recording system audio only")
			return try CaptureSession.make(includeMicrophone: false, queue: control, onTrouble: onTrouble)
		}
	}

	private func installSystemListeners(for recording: Recording) {
		for (selector, label) in [(kAudioHardwarePropertyDefaultInputDevice, "default input device changed"), (kAudioHardwarePropertyDefaultOutputDevice, "default output device changed")] {
			recording.systemListeners.append(PropertyListener(object: AudioHAL.system, selector: selector, queue: control) { [weak self, weak recording] in
				guard let self, let recording else { return }
				recording.stallRetries = 0
				self.scheduleRebuild(recording, reason: label, delay: 0.4)
			})
		}
	}

	private func handleStall(_ recording: Recording, reason: String) {
		guard !recording.stopped, !recording.suspended else { return }
		// A session that had been delivering audio gets rebuilt at once; one that never did backs off.
		if let session = recording.session, session.ring.load(.callbacks) > 0, session.ring.load(.badLayout) == 0 {
			recording.stallRetries = 0
		} else {
			recording.stallRetries += 1
		}
		scheduleRebuild(recording, reason: reason, delay: min(30, Double(recording.stallRetries) * 2))
	}

	/// Coalesces bursts of device notifications (AirPods connecting change input and output together).
	private func scheduleRebuild(_ recording: Recording, reason: String, delay: TimeInterval) {
		guard !recording.stopped, !recording.suspended else { return }
		recording.pendingRebuild?.cancel()
		let work = DispatchWorkItem { [weak self, weak recording] in
			guard let self, let recording else { return }
			self.rebuild(recording, reason: reason)
		}
		recording.pendingRebuild = work
		control.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func rebuild(_ recording: Recording, reason: String) {
		guard !recording.stopped, !recording.suspended else { return }
		recording.pendingRebuild = nil
		recording.session?.invalidate()
		recording.session = nil
		recording.writer.detach()
		do {
			let session = try makeSession(for: recording)
			recording.writer.attach(session.ring)
			do {
				try session.start()
			} catch {
				session.invalidate()
				recording.writer.detach()
				throw error
			}
			recording.session = session
			recording.failedRebuilds = 0
			Log.info("Capture rebuilt (\(reason)): \(session.summary)")
		} catch {
			recording.failedRebuilds += 1
			let delay = min(30, 2 * Double(recording.failedRebuilds))
			Log.error("Capture rebuild failed (\(reason)): \(error.localizedDescription); retrying in \(Int(delay)) s")
			scheduleRebuild(recording, reason: "retry after a failed rebuild", delay: delay)
		}
	}

	// MARK: - Finalising

	private static func finalize(_ recording: Recording, summary: CafWriter.Summary, trimToLastVoice: Bool) -> FinishedRecording? {
		var frames = summary.frames
		Log.info("Recording stopped after \(String(format: "%.1f", Double(frames) / CafWriter.fileSampleRate)) s: mic peak \(decibels(summary.peakMic)), system peak \(decibels(summary.peakSystem)), \(summary.droppedFrames) frames dropped")
		if recording.kind == .call && summary.peakSystem == 0 && frames > 0 {
			Log.info("System audio was pure digital silence (nothing played, or the System Audio Recording permission is missing)")
		}
		if trimToLastVoice {
			frames = min(frames, summary.lastVoiceFrame + Int64(silenceTail * CafWriter.fileSampleRate))
			Log.info("Trimmed to \(String(format: "%.1f", Double(frames) / CafWriter.fileSampleRate)) s, the last sound plus \(Int(silenceTail)) s")
		}
		let duration = Double(frames) / CafWriter.fileSampleRate
		let minimum = recording.kind == .inPerson ? inPersonMinimumDuration : minimumDuration
		guard duration >= minimum, !(summary.writeFailed && summary.frames == 0) else {
			try? FileManager.default.removeItem(at: recording.tempURL)
			Log.info("Recording shorter than \(Int(minimum)) s, discarded")
			return nil
		}
		return export(recording.tempURL, folder: recording.folder, appName: recording.appName, startedAt: recording.startedAt, duration: duration, kind: recording.kind, maxFrames: trimToLastVoice ? frames : nil)
	}

	private static func export(_ caf: URL, folder: URL, appName: String, startedAt: Date, duration: TimeInterval, kind: Kind, maxFrames: Int64? = nil) -> FinishedRecording? {
		let fileManager = FileManager.default
		let base = RecordingName.base(startedAt: startedAt, appName: appName)
		let partial = caf.deletingPathExtension().appendingPathExtension("partial.m4a")
		let began = Date()
		do {
			try AudioExport.encodeM4A(from: caf, to: partial, monoFromLeft: kind == .inPerson, maxFrames: maxFrames)
			let destination = RecordingName.unique(in: folder, base: base, ext: "m4a")
			try fileManager.moveItem(at: partial, to: destination)
			try? fileManager.removeItem(at: caf)
			let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
			Log.info("Saved \(destination.lastPathComponent): \(String(format: "%.1f", duration)) s, \(bytes / 1024) KB, encoded in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
			return FinishedRecording(audioURL: destination, appName: appName, startedAt: startedAt, duration: duration)
		} catch {
			try? fileManager.removeItem(at: partial)
			let fallback = RecordingName.unique(in: folder, base: base, ext: "caf")
			Log.error("AAC encoding failed (\(error.localizedDescription)); keeping the uncompressed file as \(fallback.lastPathComponent)")
			do {
				try fileManager.moveItem(at: caf, to: fallback)
				return FinishedRecording(audioURL: fallback, appName: appName, startedAt: startedAt, duration: duration)
			} catch {
				Log.error("Could not move \(caf.lastPathComponent) out of \(inProgressFolderName): \(error.localizedDescription)")
				return nil
			}
		}
	}

	private static func recover(in folder: URL) -> [FinishedRecording] {
		let fileManager = FileManager.default
		let directory = folder.appendingPathComponent(inProgressFolderName, isDirectory: true)
		guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
		var recovered: [FinishedRecording] = []
		for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
			if url.lastPathComponent.hasSuffix(".partial.m4a") {
				try? fileManager.removeItem(at: url)
				continue
			}
			guard url.pathExtension == "caf", claim(url) else { continue }
			defer { release(url) }
			let base = url.deletingPathExtension().lastPathComponent
			do {
				guard try CafFile.repair(url) else { throw CaptureError.file("not a CAF file") }
				let info = try AudioExport.info(of: url)
				let parsed = RecordingName.parse(base)
				let startedAt = parsed?.startedAt ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
				let appName = parsed?.appName ?? base
				let kind: Kind = appName.hasPrefix(inPersonName) ? .inPerson : .call
				let minimum = kind == .inPerson ? inPersonMinimumDuration : minimumDuration
				guard info.duration >= minimum else {
					try? fileManager.removeItem(at: url)
					Log.info("Leftover \(url.lastPathComponent) is shorter than \(Int(minimum)) s, discarded")
					continue
				}
				Log.info("Recovering \(url.lastPathComponent) (\(String(format: "%.1f", info.duration)) s)")
				if let result = export(url, folder: folder, appName: appName, startedAt: startedAt, duration: info.duration, kind: kind) {
					recovered.append(result)
				}
			} catch {
				let aside = url.appendingPathExtension("unreadable")
				try? fileManager.moveItem(at: url, to: aside)
				Log.error("Leftover \(url.lastPathComponent) is unreadable (\(error.localizedDescription)); renamed to \(aside.lastPathComponent)")
			}
		}
		return recovered
	}

	// MARK: - Helpers

	private func locked<T>(_ body: () throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}

	/// Marks a temp file as owned by a recording or a conversion. Returns false if someone already owns it.
	/// Keyed by file name, which is unique inside `.inprogress`: full paths are not comparable, because
	/// `standardizedFileURL` keeps or drops the `/private` prefix depending on whether the file exists yet.
	private static func claim(_ url: URL) -> Bool {
		busyLock.lock()
		defer { busyLock.unlock() }
		return busyFiles.insert(url.lastPathComponent).inserted
	}

	private static func release(_ url: URL) {
		busyLock.lock()
		defer { busyLock.unlock() }
		busyFiles.remove(url.lastPathComponent)
	}

	private static func decibels(_ peak: Float) -> String {
		peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "silent"
	}
}

/// File names carry the start time and the app, so a leftover can be recovered from its name alone:
/// `YYYY-MM-DD_HHMM_<AppName>.caf`.
enum RecordingName {
	private static func formatter() -> DateFormatter {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = .current
		formatter.dateFormat = "yyyy-MM-dd_HHmm"
		return formatter
	}

	static func base(startedAt: Date, appName: String) -> String {
		"\(formatter().string(from: startedAt))_\(sanitize(appName))"
	}

	static func sanitize(_ name: String) -> String {
		let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
		var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
		cleaned = cleaned.trimmingCharacters(in: .whitespaces)
		while cleaned.hasPrefix(".") { cleaned.removeFirst() }
		return cleaned.isEmpty ? "Call" : String(cleaned.prefix(80))
	}

	/// `<base>.<ext>`, or `<base> 2.<ext>`, `<base> 3.<ext>`... when taken.
	static func unique(in directory: URL, base: String, ext: String) -> URL {
		var candidate = directory.appendingPathComponent("\(base).\(ext)")
		var index = 2
		while FileManager.default.fileExists(atPath: candidate.path) {
			candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
			index += 1
		}
		return candidate
	}

	static func parse(_ base: String) -> (startedAt: Date, appName: String)? {
		guard base.count > 16 else { return nil }
		let stamp = String(base.prefix(15))
		let separator = base.index(base.startIndex, offsetBy: 15)
		guard base[separator] == "_", let date = formatter().date(from: stamp) else { return nil }
		return (date, String(base[base.index(after: separator)...]))
	}
}
