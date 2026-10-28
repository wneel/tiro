import Foundation
import whisper

struct TranscriptSegment {
	/// Seconds from the start of the recording.
	var start: Double
	var end: Double
	var text: String
}

/// One loaded whisper.cpp context, reused for both channels of a recording. Not thread-safe: use from one thread.
///
/// Silence is skipped with our own Silero pass rather than `params.vad`: whisper.cpp's built-in VAD glues the
/// speech together and maps timestamps back by interpolation, so a sentence said after a long pause got the
/// time of the pause and landed before the other side's reply. Decoding each stretch of speech in place keeps
/// real timestamps and stops one segment from spanning two turns.
final class WhisperEngine {
	enum EngineError: Error, CustomStringConvertible {
		case modelLoad(String)
		case inference(Int32)

		var description: String {
			switch self {
			case .modelLoad(let path): "cannot load model at \(path)"
			case .inference(let code): "whisper_full returned \(code)"
			}
		}
	}

	private let context: OpaquePointer
	private let threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
	/// Each decode window spans at most this much audio, so it fits Whisper's 30 s context.
	private static let maxChunkSamples = Int(29 * AudioPreparer.sampleRate)
	private static let maxPauseSamples = Int(2 * AudioPreparer.sampleRate)

	init(modelPath: URL) throws {
		_ = Self.logHandlerInstalled
		var params = whisper_context_default_params()
		params.use_gpu = true
		params.flash_attn = true
		guard let context = whisper_init_from_file_with_params(modelPath.path, params) else {
			throw EngineError.modelLoad(modelPath.path)
		}
		self.context = context
	}

	deinit {
		whisper_free(context)
	}

	/// `language` is "auto" or an ISO 639-1 code. Without a voice detector, the whole track is decoded.
	func transcribe(_ samples: [Float], language: String, voiceDetector: VoiceDetector?) throws -> [TranscriptSegment] {
		let spans = voiceDetector?.speechSpans(samples) ?? [0..<samples.count]
		guard !spans.isEmpty else { return [] }
		let speechSeconds = Double(spans.reduce(0) { $0 + $1.count }) / AudioPreparer.sampleRate
		Log.info(String(format: "%d speech spans, %.1f s of speech, first at %.2f s", spans.count, speechSeconds, Double(spans[0].lowerBound) / AudioPreparer.sampleRate))
		let resolvedLanguage = language == "auto" || language.isEmpty ? detectLanguage(samples, spans: spans) : language

		var segments: [TranscriptSegment] = []
		for chunk in Self.chunks(spans) {
			guard let first = chunk.first, let last = chunk.last else { continue }
			// Copy the window and silence what the detector did not call speech, so bleed and noise are not transcribed.
			var window = [Float](repeating: 0, count: last.upperBound - first.lowerBound)
			for span in chunk {
				window.replaceSubrange((span.lowerBound - first.lowerBound)..<(span.upperBound - first.lowerBound), with: samples[span])
			}
			let offset = Double(first.lowerBound) / AudioPreparer.sampleRate
			let duration = Double(window.count) / AudioPreparer.sampleRate
			for segment in try decode(window, language: resolvedLanguage) {
				segments.append(TranscriptSegment(
					start: offset + min(segment.start, duration),
					end: offset + min(max(segment.end, segment.start), duration),
					text: segment.text
				))
			}
		}
		return segments
	}

	private func decode(_ window: [Float], language: String) throws -> [TranscriptSegment] {
		// Beam 5 cost about 9% over greedy with large-v3 on an M2 Pro: the encoder dominates.
		var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
		params.beam_search.beam_size = 5
		params.n_threads = threads
		params.no_context = true
		params.suppress_nst = true
		params.print_special = false
		params.print_progress = false
		params.print_realtime = false
		params.print_timestamps = false
		params.detect_language = false

		let languageC = strdup(language)
		defer { free(languageC) }
		params.language = UnsafePointer(languageC)

		let result = window.withUnsafeBufferPointer { buffer in
			whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
		}
		guard result == 0 else { throw EngineError.inference(result) }

		return (0..<whisper_full_n_segments(context)).compactMap { index in
			guard let text = whisper_full_get_segment_text(context, index) else { return nil }
			// Segment times are in centiseconds.
			return TranscriptSegment(
				start: Double(whisper_full_get_segment_t0(context, index)) / 100,
				end: Double(whisper_full_get_segment_t1(context, index)) / 100,
				text: String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
			)
		}
	}

	/// Detects once per channel, on up to 30 s of its speech, so a short "ok" cannot switch a chunk to another language.
	private func detectLanguage(_ samples: [Float], spans: [Range<Int>]) -> String {
		var speech: [Float] = []
		let limit = Int(30 * AudioPreparer.sampleRate)
		for span in spans where speech.count < limit {
			speech.append(contentsOf: samples[span.lowerBound..<min(span.upperBound, span.lowerBound + limit - speech.count)])
		}
		let melResult = speech.withUnsafeBufferPointer { buffer in
			whisper_pcm_to_mel(context, buffer.baseAddress, Int32(buffer.count), threads)
		}
		guard melResult == 0 else { return "auto" }
		let id = whisper_lang_auto_detect(context, 0, threads, nil)
		guard id >= 0, let code = whisper_lang_str(id) else { return "auto" }
		let language = String(cString: code)
		Log.info("Detected language: \(language)")
		return language
	}

	/// Groups speech spans separated by short pauses into windows of at most 29 s. A longer pause starts a new
	/// window: after seconds of silence Whisper often ends the window early and drops the next sentence.
	/// A single span longer than 29 s stays whole, and whisper.cpp slides over it with real timestamps.
	static func chunks(_ spans: [Range<Int>]) -> [[Range<Int>]] {
		var chunks: [[Range<Int>]] = []
		for span in spans {
			if let start = chunks.last?.first?.lowerBound, let previous = chunks.last?.last,
				span.lowerBound - previous.upperBound <= maxPauseSamples, span.upperBound - start <= maxChunkSamples {
				chunks[chunks.count - 1].append(span)
			} else {
				chunks.append([span])
			}
		}
		return chunks
	}

	/// whisper.cpp logs every load step to stderr. Keep errors in Tiro's log; set TIRO_WHISPER_VERBOSE=1 to see everything.
	private static let logHandlerInstalled: Void = {
		let verbose = ProcessInfo.processInfo.environment["TIRO_WHISPER_VERBOSE"] == "1"
		if verbose {
			whisper_log_set({ _, text, _ in
				if let text { fputs(text, stderr) }
			}, nil)
		} else {
			whisper_log_set({ level, text, _ in
				guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
				let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
				// The framework always probes for an optional Core ML encoder next to the model, then falls back to Metal.
				guard !message.contains("Core ML model") else { return }
				Log.error("whisper: \(message)")
			}, nil)
		}
	}()
}

/// The Silero voice activity model, loaded once per job.
final class VoiceDetector {
	private let context: OpaquePointer

	init?(modelPath: URL) {
		var params = whisper_vad_default_context_params()
		params.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
		params.use_gpu = false
		guard let context = whisper_vad_init_from_file_with_params(modelPath.path, params) else { return nil }
		self.context = context
	}

	deinit {
		whisper_vad_free(context)
	}

	/// Speech as sample ranges, padded and clamped to the track.
	func speechSpans(_ samples: [Float]) -> [Range<Int>] {
		var params = whisper_vad_default_params()
		params.min_silence_duration_ms = 300
		params.speech_pad_ms = 200
		let segments = samples.withUnsafeBufferPointer { buffer in
			whisper_vad_segments_from_samples(context, params, buffer.baseAddress, Int32(buffer.count))
		}
		guard let segments else { return [] }
		defer { whisper_vad_free_segments(segments) }
		var spans: [Range<Int>] = []
		for index in 0..<whisper_vad_segments_n_segments(segments) {
			// Segment times are in centiseconds.
			let start = Int(Double(whisper_vad_segments_get_segment_t0(segments, index)) / 100 * AudioPreparer.sampleRate)
			let end = Int(Double(whisper_vad_segments_get_segment_t1(segments, index)) / 100 * AudioPreparer.sampleRate)
			let clamped = max(0, start)..<min(samples.count, end)
			guard !clamped.isEmpty else { continue }
			if let last = spans.last, clamped.lowerBound <= last.upperBound {
				spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, clamped.upperBound)
			} else {
				spans.append(clamped)
			}
		}
		return spans
	}
}
