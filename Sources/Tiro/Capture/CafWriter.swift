import AVFoundation
import Foundation

/// Drains capture rings into a 24 kHz, 16-bit stereo CAF on its own queue.
///
/// The header is written by hand with the data chunk size set to -1 ("runs to end of file", allowed by the
/// CAF spec for the last chunk), so a file whose writer crashed is still a valid CAF. The real size is
/// patched in only on a clean close.
final class CafWriter {
	static let fileSampleRate: Double = 24_000
	static let channels = 2
	static let bytesPerFrame = 4
	private static let chunkFrames: AVAudioFrameCount = 4096
	private static let stallTimeout: TimeInterval = 3

	struct Summary {
		let frames: Int64
		let peakMic: Float
		let peakSystem: Float
		let droppedFrames: Int64
		let writeFailed: Bool
	}

	let url: URL
	/// Called on the writer queue when the attached ring stops receiving callbacks or reports a layout it
	/// cannot read. Fires once per attached ring.
	var onStall: ((String) -> Void)?

	private let queue = DispatchQueue(label: "org.animalert.tiro.writer", qos: .userInitiated)
	private var fd: Int32
	private var timer: DispatchSourceTimer?
	private var ring: CaptureRing?
	private var converter: AVAudioConverter?
	private var sourceBuffer: AVAudioPCMBuffer?
	private var convertedBuffer: AVAudioPCMBuffer?
	private var scratch: UnsafeMutablePointer<Int16>
	private var scratchFrames: Int
	private var framesWritten: Int64 = 0
	private var previousEndHostTime: Int64 = 0
	private var gapPending = false
	private var lastCallbacks: Int64 = 0
	private var lastProgress: TimeInterval = 0
	private var stallReported = false
	private var droppedFrames: Int64 = 0
	private var peakMic: Float = 0
	private var peakSystem: Float = 0
	private var writeFailed = false
	private var closed = false

	init(url: URL) throws {
		self.url = url
		fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
		guard fd >= 0 else { throw CaptureError.file("Cannot create \(url.path): \(String(cString: strerror(errno)))") }
		scratchFrames = 16_384
		scratch = .allocate(capacity: scratchFrames * Self.channels)
		guard writeAll(Self.header()) else {
			close(fd)
			try? FileManager.default.removeItem(at: url)
			scratch.deallocate()
			throw CaptureError.file("Cannot write to \(url.path): \(String(cString: strerror(errno)))")
		}
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
		timer.setEventHandler { [weak self] in self?.drain() }
		timer.resume()
		self.timer = timer
	}

	deinit {
		if !closed { close(fd) }
		scratch.deallocate()
	}

	/// Starts draining a new ring. Any silence between the previous ring's last frame and this one's first
	/// frame is written out, so the file stays aligned with wall-clock time across device switches.
	func attach(_ ring: CaptureRing) {
		queue.sync {
			flushRing()
			self.ring = ring
			let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: ring.sampleRate, channels: AVAudioChannelCount(Self.channels))!
			let fileFormat = AVAudioFormat(standardFormatWithSampleRate: Self.fileSampleRate, channels: AVAudioChannelCount(Self.channels))!
			sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: Self.chunkFrames)
			if ring.sampleRate == Self.fileSampleRate {
				converter = nil
				convertedBuffer = nil
			} else {
				converter = AVAudioConverter(from: sourceFormat, to: fileFormat)
				converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
				let capacity = AVAudioFrameCount((Double(Self.chunkFrames) * Self.fileSampleRate / ring.sampleRate).rounded(.up)) + 1024
				convertedBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity)
				ensureScratch(frames: Int(capacity))
			}
			ensureScratch(frames: Int(Self.chunkFrames))
			gapPending = previousEndHostTime != 0
			lastCallbacks = 0
			lastProgress = ProcessInfo.processInfo.systemUptime
			stallReported = false
		}
	}

	/// Writes out everything the current ring holds and lets go of it. Call after its IOProc has stopped.
	func detach() {
		queue.sync { flushRing() }
	}

	/// Flushes, patches the header with the real size and closes the file.
	func finish() -> Summary {
		queue.sync {
			flushRing()
			timer?.cancel()
			timer = nil
			if !closed {
				closed = true
				patchDataSize()
				fsync(fd)
				close(fd)
			}
			return Summary(frames: framesWritten, peakMic: peakMic, peakSystem: peakSystem, droppedFrames: droppedFrames, writeFailed: writeFailed)
		}
	}

	/// Closes and deletes the file (start failed before anything was recorded).
	func abandon() {
		_ = finish()
		try? FileManager.default.removeItem(at: url)
	}

	// MARK: - Writer queue

	private func drain() {
		guard let ring, !closed else { return }
		let callbacks = ring.load(.callbacks)
		let now = ProcessInfo.processInfo.systemUptime
		if callbacks != lastCallbacks {
			lastCallbacks = callbacks
			lastProgress = now
		}
		if !stallReported {
			if ring.load(.badLayout) > 0 {
				stallReported = true
				onStall?("the audio stream layout changed")
			} else if now - lastProgress > Self.stallTimeout {
				stallReported = true
				onStall?("no audio for \(Int(Self.stallTimeout)) s")
			}
		}
		pump(ring)
	}

	private func pump(_ ring: CaptureRing) {
		guard let sourceBuffer, let channels = sourceBuffer.floatChannelData else { return }
		if gapPending {
			let first = ring.load(.firstHostTime)
			guard first != 0 else { return }
			gapPending = false
			let gap = Double(first - previousEndHostTime) / AudioHAL.hostTicksPerSecond
			if gap > 0.01 && gap < 120 {
				writeSilence(frames: Int(gap * Self.fileSampleRate))
			}
		}
		while true {
			let count = ring.read(mic: channels[0], system: channels[1], maxFrames: Int(Self.chunkFrames))
			guard count > 0 else { break }
			sourceBuffer.frameLength = AVAudioFrameCount(count)
			if let converter, let convertedBuffer {
				convert(sourceBuffer, with: converter, into: convertedBuffer)
			} else {
				write(sourceBuffer)
			}
		}
	}

	private func flushRing() {
		guard let ring else { return }
		pump(ring)
		if let converter, let convertedBuffer {
			while true {
				convertedBuffer.frameLength = 0
				var error: NSError?
				let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
					outStatus.pointee = .endOfStream
					return nil
				}
				if convertedBuffer.frameLength > 0 { write(convertedBuffer) }
				if status != .haveData { break }
			}
		}
		droppedFrames += ring.load(.dropped)
		let end = ring.load(.endHostTime)
		if end != 0 { previousEndHostTime = end }
		self.ring = nil
		converter = nil
	}

	private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, into output: AVAudioPCMBuffer) {
		var supplied = false
		while true {
			output.frameLength = 0
			var error: NSError?
			let status = converter.convert(to: output, error: &error) { _, outStatus in
				if supplied {
					outStatus.pointee = .noDataNow
					return nil
				}
				supplied = true
				outStatus.pointee = .haveData
				return input
			}
			if output.frameLength > 0 { write(output) }
			if status == .error {
				if !writeFailed { Log.error("Sample rate conversion failed: \(error?.localizedDescription ?? "unknown")") }
				return
			}
			if status != .haveData { return }
		}
	}

	private func write(_ buffer: AVAudioPCMBuffer) {
		guard let channels = buffer.floatChannelData else { return }
		let frames = Int(buffer.frameLength)
		ensureScratch(frames: frames)
		let mic = channels[0]
		let system = channels[1]
		for frame in 0..<frames {
			let left = mic[frame]
			let right = system[frame]
			peakMic = max(peakMic, abs(left))
			peakSystem = max(peakSystem, abs(right))
			scratch[frame * 2] = Self.int16(left).littleEndian
			scratch[frame * 2 + 1] = Self.int16(right).littleEndian
		}
		writeFrames(frames)
	}

	private func writeSilence(frames: Int) {
		var remaining = frames
		while remaining > 0 {
			let count = min(remaining, scratchFrames)
			scratch.update(repeating: 0, count: count * Self.channels)
			writeFrames(count)
			remaining -= count
		}
	}

	private func writeFrames(_ frames: Int) {
		guard !writeFailed, frames > 0 else { return }
		if writeAll(UnsafeRawBufferPointer(start: scratch, count: frames * Self.bytesPerFrame)) {
			framesWritten += Int64(frames)
		} else {
			writeFailed = true
			Log.error("Recording write failed (\(String(cString: strerror(errno)))); the rest of this call is not saved")
		}
	}

	private func writeAll(_ bytes: UnsafeRawBufferPointer) -> Bool {
		var offset = 0
		while offset < bytes.count {
			let result = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
			if result < 0 {
				if errno == EINTR { continue }
				return false
			}
			offset += result
		}
		return true
	}

	private func writeAll(_ data: Data) -> Bool {
		data.withUnsafeBytes { writeAll($0) }
	}

	private func ensureScratch(frames: Int) {
		guard frames > scratchFrames else { return }
		scratch.deallocate()
		scratchFrames = frames
		scratch = .allocate(capacity: frames * Self.channels)
	}

	private func patchDataSize() {
		let size = Int64(4) + framesWritten * Int64(Self.bytesPerFrame)
		var bigEndian = size.bigEndian
		_ = withUnsafeBytes(of: &bigEndian) { pwrite(fd, $0.baseAddress!, 8, off_t(CafFile.dataSizeOffset)) }
	}

	private static func int16(_ sample: Float) -> Int16 {
		let clipped = min(max(sample, -1), 1)
		return Int16((clipped * 32767).rounded())
	}

	private static func header() -> Data {
		var data = Data()
		func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
		data.append(contentsOf: Array("caff".utf8))
		append(UInt16(1))
		append(UInt16(0))
		data.append(contentsOf: Array("desc".utf8))
		append(Int64(32))
		append(fileSampleRate.bitPattern)
		data.append(contentsOf: Array("lpcm".utf8))
		append(UInt32(2)) // kCAFLinearPCMFormatFlagIsLittleEndian
		append(UInt32(bytesPerFrame))
		append(UInt32(1))
		append(UInt32(channels))
		append(UInt32(16))
		data.append(contentsOf: Array("data".utf8))
		append(Int64(-1))
		append(UInt32(0)) // edit count
		assert(data.count == CafFile.dataSizeOffset + 12)
		return data
	}
}
