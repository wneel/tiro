import AppKit
import CoreAudio
import Foundation

struct ActiveCall: Equatable {
	let appName: String
	let bundleID: String
}

/// Polls Core Audio's process list and reports a call while a watched app holds the microphone.
/// A call starts on the first poll that sees one. When the app lets go of the microphone the call is
/// released at once, so the recorder can let go too, and it ends once no watched app has held the
/// microphone for 20 consecutive seconds; taking it back within that window resumes the same call.
/// `start`, `stop` and the callbacks all live on the main thread.
final class CallDetector {
	static let pollInterval: TimeInterval = 1
	static let endDelay: TimeInterval = 20

	var onCallStarted: ((ActiveCall) -> Void)?
	/// The call app released the microphone; the call ends unless it takes it back within `endDelay`.
	var onMicrophoneReleased: (() -> Void)?
	/// The call app took the microphone back before the call ended.
	var onMicrophoneRetaken: (() -> Void)?
	var onCallEnded: (() -> Void)?
	private(set) var currentCall: ActiveCall?
	/// True while the call app actually holds the microphone, false during the grace window after it let go.
	var isMicrophoneHeld: Bool { currentCall != nil && !released }

	struct InputProcess: Equatable {
		let pid: pid_t
		let bundleID: String
	}

	private let preferences: Preferences
	private let pollQueue = DispatchQueue(label: "org.animalert.tiro.detector", qos: .utility)
	private var timer: DispatchSourceTimer?
	private var generation = 0
	private var lastHeldAt: TimeInterval = 0
	private var lastHolders: [String] = []
	private var released = false

	init(preferences: Preferences) {
		self.preferences = preferences
	}

	func start() {
		guard timer == nil else { return }
		generation += 1
		let generation = generation
		let ownPID = getpid()
		let timer = DispatchSource.makeTimerSource(queue: pollQueue)
		timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(250))
		timer.setEventHandler { [weak self] in
			let holders = Self.processesHoldingInput(excluding: ownPID)
			DispatchQueue.main.async { self?.evaluate(holders, generation: generation) }
		}
		self.timer = timer
		timer.resume()
		Log.info("Call detection started")
	}

	/// Stops polling. An ongoing call is forgotten without calling `onCallEnded`.
	func stop() {
		guard let timer else { return }
		timer.cancel()
		self.timer = nil
		generation += 1
		currentCall = nil
		released = false
		lastHolders = []
		Log.info("Call detection stopped")
	}

	private func evaluate(_ holders: [InputProcess], generation: Int) {
		guard generation == self.generation, timer != nil else { return }
		let bundleIDs = holders.map(\.bundleID)
		if bundleIDs != lastHolders {
			lastHolders = bundleIDs
			Log.info("Microphone held by: \(bundleIDs.isEmpty ? "nobody" : bundleIDs.joined(separator: ", "))")
		}
		let now = ProcessInfo.processInfo.systemUptime
		let match = holders.lazy.compactMap { process in
			self.preferences.watchedAppName(forBundleID: process.bundleID).map { ActiveCall(appName: $0, bundleID: process.bundleID) }
		}.first
		if let match {
			lastHeldAt = now
			if currentCall == nil {
				currentCall = match
				Log.info("Call started: \(match.appName) (\(match.bundleID)) holds the microphone")
				onCallStarted?(match)
			} else if released {
				released = false
				Log.info("\(match.appName) took the microphone back")
				onMicrophoneRetaken?()
			}
		} else if let call = currentCall, !released {
			released = true
			Log.info("\(call.appName) released the microphone")
			onMicrophoneReleased?()
		} else if let call = currentCall, now - lastHeldAt >= Self.endDelay {
			currentCall = nil
			released = false
			Log.info("Call ended: no watched app has held the microphone for \(Int(Self.endDelay)) s (was \(call.appName), \(call.bundleID))")
			onCallEnded?()
		}
	}

	/// Every process other than `excluding` that currently runs audio input. Safe on any thread.
	static func processesHoldingInput(excluding excludedPID: pid_t) -> [InputProcess] {
		AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
			guard AudioHAL.read(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) == 1,
				let pid = AudioHAL.read(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0, pid != excludedPID
			else { return nil }
			var bundleID = AudioHAL.readString(object, kAudioProcessPropertyBundleID) ?? ""
			if bundleID.isEmpty { bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
			return bundleID.isEmpty ? nil : InputProcess(pid: pid, bundleID: bundleID)
		}
	}
}
