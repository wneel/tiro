import Darwin

/// Single-producer single-consumer ring of stereo frames (left = mic, right = system audio), written from
/// the real-time IOProc and drained by the file writer. All storage is allocated up front; the producer
/// side only does arithmetic and atomic counter updates.
///
/// Atomics use the OSAtomic*Barrier family: each call is a full memory barrier, and the Synchronization
/// module's Atomic needs macOS 15 while Tiro supports 14.4.
final class CaptureRing {
	enum Counter: Int, CaseIterable {
		/// Frames ever written / read; their difference is the fill level.
		case written, read
		case dropped, callbacks, badLayout
		/// Host time of the first input frame, and of the end of the last callback.
		case firstHostTime, endHostTime
	}

	let capacity: Int
	let sampleRate: Double
	/// capacity * 2 interleaved floats.
	let samples: UnsafeMutablePointer<Float>
	let counters: UnsafeMutablePointer<Int64>

	init(sampleRate: Double, seconds: Double) {
		self.sampleRate = sampleRate
		capacity = max(4096, Int(sampleRate * seconds))
		samples = .allocate(capacity: capacity * 2)
		samples.initialize(repeating: 0, count: capacity * 2)
		counters = .allocate(capacity: Counter.allCases.count)
		counters.initialize(repeating: 0, count: Counter.allCases.count)
	}

	deinit {
		samples.deallocate()
		counters.deallocate()
	}

	func load(_ counter: Counter) -> Int64 { OSAtomicAdd64Barrier(0, counters + counter.rawValue) }

	/// Consumer side: moves up to `maxFrames` frames out of the ring into two planar destinations.
	func read(mic: UnsafeMutablePointer<Float>, system: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
		let written = load(.written)
		let read = load(.read)
		let count = min(Int(written - read), maxFrames)
		guard count > 0 else { return 0 }
		var index = Int(read % Int64(capacity))
		for frame in 0..<count {
			mic[frame] = samples[index * 2]
			system[frame] = samples[index * 2 + 1]
			index += 1
			if index == capacity { index = 0 }
		}
		OSAtomicAdd64Barrier(Int64(count), counters + Counter.read.rawValue)
		return count
	}
}
