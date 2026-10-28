import Foundation

/// Transcribes finished recordings one at a time, at background priority, so the Mac stays usable.
@MainActor
final class TranscriptionQueue: ObservableObject {
	static let shared = TranscriptionQueue()

	@Published private(set) var isTranscribing = false
	/// Recordings waiting their turn, not counting the one in progress.
	@Published private(set) var pendingCount = 0
	/// Called with the URL of the written .txt.
	var onFinished: ((URL) -> Void)?
	/// Called with the audio URL and a reason to show the user.
	var onFailed: ((URL, String) -> Void)?

	private struct Pending {
		var audioURL: URL
		var preferences: Preferences
	}

	private let modelStore: ModelStore
	private var queue: [Pending] = []
	private var current: URL?
	private var draining = false
	private static let worker = DispatchQueue(label: "org.animalert.tiro.transcription", qos: .background)

	init(modelStore: ModelStore? = nil) {
		self.modelStore = modelStore ?? .shared
	}

	func enqueue(_ audioURL: URL, preferences: Preferences) {
		guard current != audioURL, !queue.contains(where: { $0.audioURL == audioURL }) else { return }
		queue.append(Pending(audioURL: audioURL, preferences: preferences))
		pendingCount = queue.count
		if !draining {
			draining = true
			Task { await drain() }
		}
	}

	private func drain() async {
		while !queue.isEmpty {
			let next = queue.removeFirst()
			current = next.audioURL
			pendingCount = queue.count
			isTranscribing = true
			await process(next)
			current = nil
		}
		isTranscribing = false
		draining = false
	}

	private func process(_ item: Pending) async {
		guard let modelPath = modelStore.resolvedModelPath(preferences: item.preferences) else {
			Log.info("No transcription model installed, skipped \(item.audioURL.lastPathComponent)")
			return
		}
		var vadPath: URL?
		do {
			vadPath = try await modelStore.vadModelPath()
		} catch {
			Log.error("VAD model unavailable, transcribing without it: \(error)")
		}
		let job = Transcriber.Job(audioURL: item.audioURL, modelPath: modelPath, vadModelPath: vadPath, language: item.preferences.language)
		Log.info("Transcription started: \(item.audioURL.lastPathComponent) with \(modelPath.lastPathComponent)")

		let result: Result<URL, Transcriber.Failure> = await withCheckedContinuation { continuation in
			Self.worker.async {
				do {
					continuation.resume(returning: .success(try Transcriber.run(job)))
				} catch let failure as Transcriber.Failure {
					continuation.resume(returning: .failure(failure))
				} catch {
					continuation.resume(returning: .failure(.inference("\(error)")))
				}
			}
		}
		switch result {
		case .success(let txtURL):
			onFinished?(txtURL)
		case .failure(let failure):
			Log.error("Transcription failed for \(item.audioURL.lastPathComponent): \(failure.detail)")
			onFailed?(item.audioURL, failure.reason)
		}
	}
}
