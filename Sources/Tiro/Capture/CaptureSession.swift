import CoreAudio
import Foundation

/// One system-audio tap plus a private aggregate device (default mic + tap) and its IOProc.
/// Device changes throw the whole thing away and build a new one; the file writer outlives it.
final class CaptureSession {
	let ring: CaptureRing
	let summary: String
	private let tapID: AudioObjectID
	private let aggregateID: AudioObjectID
	private var ioProcID: AudioDeviceIOProcID?
	private var listeners: [PropertyListener] = []
	private var invalidated = false

	private init(ring: CaptureRing, summary: String, tapID: AudioObjectID, aggregateID: AudioObjectID, ioProcID: AudioDeviceIOProcID) {
		self.ring = ring
		self.summary = summary
		self.tapID = tapID
		self.aggregateID = aggregateID
		self.ioProcID = ioProcID
	}

	/// Builds the tap, the aggregate and the IOProc, without starting IO.
	/// With `includeMicrophone` false (or no input device) the aggregate is clocked by the output device
	/// and the left channel stays silent.
	/// `onTrouble` fires on `queue` when the mic dies or the aggregate changes rate.
	static func make(includeMicrophone: Bool, queue: DispatchQueue, onTrouble: @escaping (String) -> Void) throws -> CaptureSession {
		let ownProcess = AudioHAL.processObject(forPID: getpid())
		let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
		tapDescription.name = "Tiro system audio"
		tapDescription.isPrivate = true
		tapDescription.muteBehavior = .unmuted
		var tapID = AudioObjectID(kAudioObjectUnknown)
		try AudioHAL.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")
		var aggregateID = AudioObjectID(kAudioObjectUnknown)
		var procID: AudioDeviceIOProcID?
		var built = false
		defer {
			if !built {
				if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
				if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
				AudioHardwareDestroyProcessTap(tapID)
			}
		}

		let mic = includeMicrophone ? AudioHAL.defaultDevice(input: true) : nil
		// An aggregate cannot hold another aggregate (Core Audio silently drops it and only the tap
		// remains), so a user aggregate set as default input is replaced by its physical input devices.
		let micDevices = mic.map(AudioHAL.physicalInputDevices) ?? []
		let micUIDs = micDevices.compactMap(AudioHAL.deviceUID)
		let useMic = !micUIDs.isEmpty && micUIDs.count == micDevices.count
		let output = AudioHAL.defaultDevice(input: false)
		guard let clockUID = useMic ? micUIDs.first : output.flatMap(AudioHAL.deviceUID) else { throw CaptureError.noAudioDevice }
		let subdevices = useMic ? micUIDs : [clockUID]

		// The mic is the clock master; the tap gets drift compensation, which also resamples it to the
		// mic's rate when they differ (measured with an 8 kHz input: the tap stream still reports 48 kHz
		// but delivers the aggregate's frame count). tapautostart stays off: with it on, IO never starts
		// while no tapped process plays audio, so the mic would not be recorded either.
		let composition: [String: Any] = [
			kAudioAggregateDeviceNameKey: "Tiro capture",
			kAudioAggregateDeviceUIDKey: "org.animalert.tiro.capture.\(UUID().uuidString)",
			kAudioAggregateDeviceMainSubDeviceKey: clockUID,
			kAudioAggregateDeviceIsPrivateKey: true,
			kAudioAggregateDeviceIsStackedKey: false,
			kAudioAggregateDeviceTapAutoStartKey: false,
			kAudioAggregateDeviceSubDeviceListKey: subdevices.map { [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: $0 != clockUID] },
			kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
		]
		try AudioHAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")

		// Input buffers arrive in stream order: the subdevice's streams first, the tap's stream last
		// (verified: built-in mic gives [1, 2], a 2-channel virtual input gives [2, 2] with the tap last).
		let channels = AudioHAL.inputStreamChannels(aggregateID)
		let formats = AudioHAL.inputStreamFormats(aggregateID)
		guard let tapChannels = channels.last, tapChannels > 0 else {
			throw CaptureError.unexpectedStreams("no tap stream in \(channels)")
		}
		for format in formats where !(format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32) {
			throw CaptureError.unexpectedStreams("non Float32 stream (flags \(format.mFormatFlags), \(format.mBitsPerChannel) bits)")
		}
		guard let rate = AudioHAL.nominalSampleRate(aggregateID), rate >= 8000 else {
			throw CaptureError.unexpectedStreams("no usable sample rate")
		}

		let expectedMicStreams = useMic ? micDevices.reduce(0) { $0 + AudioHAL.inputStreamChannels($1).count } : 0
		let micStreams = useMic ? channels.count - 1 : 0
		if useMic && micStreams != expectedMicStreams {
			Log.error("Capture device has \(micStreams) microphone streams where \(expectedMicStreams) were expected (\(channels)); the microphone may be missing")
		}

		let ring = CaptureRing(sampleRate: rate, seconds: 15)
		let block = makeIOBlock(ring: ring, bufferCount: channels.count, micBufferCount: micStreams, micChannels: useMic ? channels.dropLast().reduce(0, +) : 0, tapChannels: tapChannels)
		try AudioHAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block), "AudioDeviceCreateIOProcIDWithBlock")
		guard let procID else { throw CaptureError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", -1) }

		let micText = useMic ? "\(AudioHAL.name(mic!)) [\(micUIDs.joined(separator: ", "))]" : "none (clocked by \(output.map(AudioHAL.name) ?? clockUID))"
		let tapRate = AudioHAL.read(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())?.mSampleRate ?? 0
		let summary = "mic \(micText), aggregate \(Int(rate)) Hz, input streams \(channels), tap \(Int(tapRate)) Hz"
		let session = CaptureSession(ring: ring, summary: summary, tapID: tapID, aggregateID: aggregateID, ioProcID: procID)
		built = true

		session.listeners.append(PropertyListener(object: aggregateID, selector: kAudioDevicePropertyNominalSampleRate, queue: queue) {
			onTrouble("aggregate sample rate changed")
		})
		if useMic, let mic {
			session.listeners.append(PropertyListener(object: mic, selector: kAudioDevicePropertyDeviceIsAlive, queue: queue) {
				if AudioHAL.read(mic, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 1 { onTrouble("microphone disappeared") }
			})
		}
		return session
	}

	func start() throws {
		guard let ioProcID else { throw CaptureError.coreAudio("AudioDeviceStart", -1) }
		try AudioHAL.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
	}

	/// Stops IO and destroys the IOProc, the aggregate and the tap. Safe to call twice.
	func invalidate() {
		guard !invalidated else { return }
		invalidated = true
		listeners.forEach { $0.remove() }
		listeners = []
		if let ioProcID {
			AudioDeviceStop(aggregateID, ioProcID)
			AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
			self.ioProcID = nil
		}
		let aggregateStatus = AudioHardwareDestroyAggregateDevice(aggregateID)
		let tapStatus = AudioHardwareDestroyProcessTap(tapID)
		if aggregateStatus != noErr || tapStatus != noErr {
			Log.error("Capture teardown: aggregate \(AudioHAL.describe(aggregateStatus)), tap \(AudioHAL.describe(tapStatus))")
		}
	}

	deinit { invalidate() }

	/// The real-time callback. It captures only raw pointers and integers (no ARC traffic), never
	/// allocates, locks, logs or touches files.
	private static func makeIOBlock(ring: CaptureRing, bufferCount: Int, micBufferCount: Int, micChannels: Int, tapChannels: Int) -> AudioDeviceIOBlock {
		let samples = ring.samples
		let counters = ring.counters
		let capacity = ring.capacity
		let micScale = micChannels > 0 ? 1 / Float(micChannels) : 0
		let tapScale = 1 / Float(tapChannels)
		let ticksPerFrame = AudioHAL.hostTicksPerSecond / ring.sampleRate
		let written = counters + CaptureRing.Counter.written.rawValue
		let read = counters + CaptureRing.Counter.read.rawValue
		let dropped = counters + CaptureRing.Counter.dropped.rawValue
		let callbacks = counters + CaptureRing.Counter.callbacks.rawValue
		let badLayout = counters + CaptureRing.Counter.badLayout.rawValue
		let firstHostTime = counters + CaptureRing.Counter.firstHostTime.rawValue
		let endHostTime = counters + CaptureRing.Counter.endHostTime.rawValue

		return { _, inputData, inputTime, _, _ in
			OSAtomicIncrement64Barrier(callbacks)
			let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
			guard buffers.count == bufferCount else { OSAtomicIncrement64Barrier(badLayout); return }
			let tap = buffers[bufferCount - 1]
			guard Int(tap.mNumberChannels) == tapChannels, let tapRaw = tap.mData else { OSAtomicIncrement64Barrier(badLayout); return }
			let tapData = tapRaw.assumingMemoryBound(to: Float.self)
			let frames = Int(tap.mDataByteSize) / (4 * tapChannels)
			guard frames > 0 else { return }

			var micUsable = micBufferCount > 0
			for index in 0..<micBufferCount {
				let buffer = buffers[index]
				if buffer.mData == nil || Int(buffer.mDataByteSize) < frames * 4 * Int(buffer.mNumberChannels) { micUsable = false }
			}

			if inputTime.pointee.mFlags.contains(.hostTimeValid) {
				let host = Int64(bitPattern: inputTime.pointee.mHostTime)
				_ = OSAtomicCompareAndSwap64Barrier(0, host, firstHostTime)
				let end = host + Int64(Double(frames) * ticksPerFrame)
				let previous = OSAtomicAdd64Barrier(0, endHostTime)
				_ = OSAtomicCompareAndSwap64Barrier(previous, end, endHostTime)
			}

			let filled = OSAtomicAdd64Barrier(0, written) - OSAtomicAdd64Barrier(0, read)
			let count = min(frames, capacity - Int(filled))
			if count < frames { OSAtomicAdd64Barrier(Int64(frames - count), dropped) }
			guard count > 0 else { return }

			var slot = Int((OSAtomicAdd64Barrier(0, written)) % Int64(capacity))
			for frame in 0..<count {
				var mic: Float = 0
				if micUsable {
					for index in 0..<micBufferCount {
						let buffer = buffers[index]
						let channelCount = Int(buffer.mNumberChannels)
						let data = buffer.mData!.assumingMemoryBound(to: Float.self)
						for channel in 0..<channelCount { mic += data[frame * channelCount + channel] }
					}
					mic *= micScale
				}
				var system: Float = 0
				for channel in 0..<tapChannels { system += tapData[frame * tapChannels + channel] }
				samples[slot * 2] = mic
				samples[slot * 2 + 1] = system * tapScale
				slot += 1
				if slot == capacity { slot = 0 }
			}
			OSAtomicAdd64Barrier(Int64(count), written)
		}
	}
}
