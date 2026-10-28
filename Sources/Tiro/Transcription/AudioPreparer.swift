import Accelerate
import AVFoundation
import Foundation

/// Turns a recording into one 16 kHz mono Float32 track per channel, loudness-normalized for Whisper.
enum AudioPreparer {
	static let sampleRate = 16_000.0

	enum PrepError: Error, CustomStringConvertible {
		case unreadable(Error)
		case noAudioChannels
		case conversion(String)

		var description: String {
			switch self {
			case .unreadable(let error): "cannot open audio: \(error)"
			case .noAudioChannels: "no audio channels"
			case .conversion(let detail): "conversion failed: \(detail)"
			}
		}
	}

	/// Returns at most two tracks: index 0 is the left channel, index 1 the right.
	static func loadChannels(_ url: URL) throws -> [[Float]] {
		let file: AVAudioFile
		do {
			file = try AVAudioFile(forReading: url)
		} catch {
			throw PrepError.unreadable(error)
		}
		let inFormat = file.processingFormat
		let channelCount = min(Int(inFormat.channelCount), 2)
		guard channelCount > 0 else { throw PrepError.noAudioChannels }
		guard
			let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: inFormat.channelCount, interleaved: false),
			let converter = AVAudioConverter(from: inFormat, to: outFormat)
		else { throw PrepError.conversion("unsupported format \(inFormat)") }
		converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

		let inCapacity: AVAudioFrameCount = 1 << 16
		let outCapacity = AVAudioFrameCount(Double(inCapacity) * sampleRate / inFormat.sampleRate) + 1024
		guard
			let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity),
			let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
		else { throw PrepError.conversion("buffer allocation") }

		let estimatedFrames = Int(Double(file.length) * sampleRate / inFormat.sampleRate) + 1
		var tracks = (0..<channelCount).map { _ -> [Float] in
			var track = [Float]()
			track.reserveCapacity(estimatedFrames)
			return track
		}

		var reachedEnd = false
		var readError: Error?
		while true {
			outBuffer.frameLength = 0
			var conversionError: NSError?
			let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
				// AVAudioFile throws instead of returning zero frames when asked to read past the end.
				if reachedEnd || file.framePosition >= file.length {
					reachedEnd = true
					inputStatus.pointee = .endOfStream
					return nil
				}
				do {
					try file.read(into: inBuffer, frameCount: inCapacity)
				} catch {
					readError = error
					reachedEnd = true
					inputStatus.pointee = .endOfStream
					return nil
				}
				if inBuffer.frameLength == 0 {
					reachedEnd = true
					inputStatus.pointee = .endOfStream
					return nil
				}
				inputStatus.pointee = .haveData
				return inBuffer
			}
			if status == .error {
				throw PrepError.conversion(conversionError?.localizedDescription ?? "unknown")
			}
			if let data = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
				for channel in 0..<channelCount {
					tracks[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(outBuffer.frameLength)))
				}
			}
			if status == .endOfStream { break }
		}
		if let readError { throw PrepError.unreadable(readError) }
		return tracks
	}

	/// Brings speech to about -20 dBFS RMS, measured over non-silent 20 ms frames only, so quiet rooms
	/// do not push Whisper into repetition loops. Returns false when the track holds no speech-level signal.
	static func normalize(_ samples: inout [Float]) -> Bool {
		let frame = 320
		let gate: Float = 0.003_16      // -50 dBFS
		let target: Float = 0.1         // -20 dBFS
		let maxGain: Float = 100        // +40 dB
		let ceiling: Float = 0.95
		guard samples.count >= frame else { return false }

		var activeSquares: Double = 0
		var activeCount = 0
		var framePeaks = [Float]()
		samples.withUnsafeBufferPointer { buffer in
			var start = 0
			while start + frame <= buffer.count {
				let slice = UnsafeBufferPointer(rebasing: buffer[start..<(start + frame)])
				var meanSquare: Float = 0
				vDSP_measqv(slice.baseAddress!, 1, &meanSquare, vDSP_Length(frame))
				if meanSquare.squareRoot() >= gate {
					activeSquares += Double(meanSquare) * Double(frame)
					activeCount += frame
					var peak: Float = 0
					vDSP_maxmgv(slice.baseAddress!, 1, &peak, vDSP_Length(frame))
					framePeaks.append(peak)
				}
				start += frame
			}
		}
		// Under half a second of signal above the gate: nothing worth transcribing.
		guard activeCount >= Int(sampleRate / 2) else { return false }

		let activeRMS = Float((activeSquares / Double(activeCount)).squareRoot())
		// Cap on a high percentile of frame peaks so one click does not keep the whole call quiet.
		framePeaks.sort()
		let referencePeak = framePeaks[min(framePeaks.count - 1, Int(Double(framePeaks.count) * 0.999))]
		var gain = min(target / activeRMS, maxGain)
		if referencePeak > 0 { gain = min(gain, ceiling / referencePeak) }
		samples.withUnsafeMutableBufferPointer { buffer in
			vDSP_vsmul(buffer.baseAddress!, 1, &gain, buffer.baseAddress!, 1, vDSP_Length(buffer.count))
		}

		// Soft-limit the rare samples above the ceiling instead of clipping them.
		let headroom = 1 - ceiling
		for index in samples.indices where abs(samples[index]) > ceiling {
			let magnitude = abs(samples[index])
			let limited = ceiling + headroom * tanh((magnitude - ceiling) / headroom)
			samples[index] = samples[index] < 0 ? -limited : limited
		}
		return true
	}
}
