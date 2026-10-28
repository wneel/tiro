import Foundation

/// One full transcription job, run synchronously off the main thread.
enum Transcriber {
	struct Job: Sendable {
		var audioURL: URL
		var modelPath: URL
		var vadModelPath: URL?
		var language: String
	}

	enum Failure: Error {
		case audio(String)
		case model(String)
		case inference(String)
		case output(String)

		/// Shown to the user.
		var reason: String {
			switch self {
			case .audio: String(localized: "The recording could not be read.")
			case .model: String(localized: "The transcription model could not be loaded.")
			case .inference: String(localized: "The transcription failed.")
			case .output: String(localized: "The transcript could not be saved.")
			}
		}

		var detail: String {
			switch self {
			case .audio(let detail), .model(let detail), .inference(let detail), .output(let detail): detail
			}
		}
	}

	/// Returns the URL of the written .txt.
	static func run(_ job: Job) throws -> URL {
		let started = Date()
		var tracks: [[Float]]
		do {
			tracks = try AudioPreparer.loadChannels(job.audioURL)
		} catch {
			throw Failure.audio("\(error)")
		}
		let duration = Double(tracks.first?.count ?? 0) / AudioPreparer.sampleRate
		let speakers: [String?] = tracks.count == 1
			? [nil]
			: [String(localized: "You"), String(localized: "Others")]

		let engine: WhisperEngine
		do {
			engine = try WhisperEngine(modelPath: job.modelPath)
		} catch {
			throw Failure.model("\(error)")
		}

		let voiceDetector = job.vadModelPath.flatMap { VoiceDetector(modelPath: $0) }
		if job.vadModelPath != nil, voiceDetector == nil {
			Log.error("VAD model failed to load, decoding whole channels")
		}

		var channels: [[TranscriptSegment]] = []
		for index in tracks.indices {
			guard AudioPreparer.normalize(&tracks[index]) else {
				Log.info("Channel \(index) has no speech, skipped")
				channels.append([])
				tracks[index] = []
				continue
			}
			do {
				let raw = try engine.transcribe(tracks[index], language: job.language, voiceDetector: voiceDetector)
				let cleaned = TranscriptFilter.clean(raw)
				if cleaned.count != raw.count {
					Log.info("Channel \(index): filtered \(raw.count - cleaned.count) of \(raw.count) segments")
				}
				channels.append(cleaned)
			} catch {
				throw Failure.inference("\(error)")
			}
			tracks[index] = []
		}

		let txtURL: URL
		do {
			txtURL = try TranscriptWriter.write(TranscriptWriter.merge(channels, speakers: speakers), nextTo: job.audioURL)
		} catch {
			throw Failure.output("\(error)")
		}
		let elapsed = Date().timeIntervalSince(started)
		let factor = duration > 0 ? elapsed / duration : 0
		Log.info(String(format: "Transcribed %@ (%.0f s of audio) in %.1f s, %.3fx realtime, model %@",
			job.audioURL.lastPathComponent, duration, elapsed, factor, job.modelPath.lastPathComponent))
		return txtURL
	}
}
