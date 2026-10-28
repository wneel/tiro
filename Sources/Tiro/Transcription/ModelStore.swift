import Foundation

/// Downloads, lists and deletes the whisper models in ~/Library/Application Support/Tiro/Models/.
@MainActor
final class ModelStore: ObservableObject {
	static let shared = ModelStore()

	nonisolated static var defaultDirectory: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Tiro/Models", isDirectory: true)
	}

	/// Present while a model downloads, from 0 to 1.
	@Published private(set) var downloadProgress: [WhisperModel: Double] = [:]
	@Published private(set) var lastError: String?

	let directory: URL
	private var tasks: [WhisperModel: URLSessionDownloadTask] = [:]
	private var vadTask: Task<URL, Error>?

	init(directory: URL = ModelStore.defaultDirectory) {
		self.directory = directory
		removeStaleStagingFiles()
	}

	func url(for model: WhisperModel) -> URL {
		directory.appendingPathComponent(model.fileName)
	}

	func isInstalled(_ model: WhisperModel) -> Bool {
		Self.fileSize(url(for: model)) >= model.minimumBytes
	}

	func download(_ model: WhisperModel) async {
		guard tasks[model] == nil, !isInstalled(model) else { return }
		lastError = nil
		downloadProgress[model] = 0
		Log.info("Model download started: \(model.fileName)")
		do {
			try await fetch(
				from: model.downloadURL,
				to: url(for: model),
				minimumBytes: model.minimumBytes,
				onStart: { [weak self] task in self?.tasks[model] = task },
				onProgress: { [weak self] value in
					guard let self, self.tasks[model] != nil else { return }
					self.downloadProgress[model] = value
				}
			)
			Log.info("Model download finished: \(model.fileName)")
			// Fetch the VAD now, while online: without it, silence turns into invented sentences.
			_ = try? await vadModelPath()
		} catch let error as URLError where error.code == .cancelled {
			Log.info("Model download cancelled: \(model.fileName)")
		} catch {
			Log.error("Model download failed: \(model.fileName): \(error)")
			lastError = String(localized: "The model could not be downloaded. Check your connection and try again.")
		}
		tasks[model] = nil
		downloadProgress[model] = nil
	}

	func cancelDownload(_ model: WhisperModel) {
		tasks[model]?.cancel()
	}

	func delete(_ model: WhisperModel) {
		cancelDownload(model)
		do {
			if FileManager.default.fileExists(atPath: url(for: model).path) {
				try FileManager.default.removeItem(at: url(for: model))
				Log.info("Model deleted: \(model.fileName)")
			}
		} catch {
			Log.error("Model delete failed: \(model.fileName): \(error)")
			lastError = String(localized: "The model could not be deleted.")
		}
		objectWillChange.send()
	}

	/// The custom model path if set and present, else the selected model if installed, else nil.
	func resolvedModelPath(preferences: Preferences) -> URL? {
		if let custom = preferences.customModelPath?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
			let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
			if FileManager.default.fileExists(atPath: url.path) { return url }
			Log.error("Custom model not found at \(url.path), falling back to the selected model")
		}
		guard let model = WhisperModel(rawValue: preferences.modelID), isInstalled(model) else { return nil }
		return url(for: model)
	}

	/// Downloads the Silero VAD model on first use. Concurrent callers share one download.
	func vadModelPath() async throws -> URL {
		let destination = directory.appendingPathComponent(VADModel.fileName)
		if Self.fileSize(destination) >= VADModel.minimumBytes { return destination }
		if let vadTask { return try await vadTask.value }
		let task = Task { @MainActor in
			Log.info("VAD model download started: \(VADModel.fileName)")
			try await self.fetch(from: VADModel.downloadURL, to: destination, minimumBytes: VADModel.minimumBytes, onStart: { _ in }, onProgress: { _ in })
			Log.info("VAD model download finished")
			return destination
		}
		vadTask = task
		defer { vadTask = nil }
		return try await task.value
	}

	// MARK: Download

	private func fetch(
		from source: URL,
		to destination: URL,
		minimumBytes: Int64,
		onStart: (URLSessionDownloadTask) -> Void,
		onProgress: @escaping @MainActor (Double) -> Void
	) async throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let staging = destination.appendingPathExtension(Self.stagingExtension)
		try? FileManager.default.removeItem(at: staging)
		defer { try? FileManager.default.removeItem(at: staging) }

		let delegate = DownloadDelegate(staging: staging) { value in
			Task { @MainActor in onProgress(value) }
		}
		let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }

		let expectedLength: Int64 = try await withCheckedThrowingContinuation { continuation in
			delegate.continuation = continuation
			let task = session.downloadTask(with: source)
			onStart(task)
			task.resume()
		}
		let size = Self.fileSize(staging)
		guard size >= minimumBytes else { throw DownloadError.tooSmall(size) }
		if expectedLength > 0, size != expectedLength { throw DownloadError.truncated(size, expectedLength) }
		guard Self.hasGGMLMagic(staging) else { throw DownloadError.notAModel }
		if FileManager.default.fileExists(atPath: destination.path) {
			_ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
		} else {
			try FileManager.default.moveItem(at: staging, to: destination)
		}
	}

	private static let stagingExtension = "download"

	private func removeStaleStagingFiles() {
		let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
		for file in files where file.pathExtension == Self.stagingExtension {
			try? FileManager.default.removeItem(at: file)
		}
	}

	nonisolated static func fileSize(_ url: URL) -> Int64 {
		let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
	}

	/// ggml files start with the little-endian magic 0x67676d6c; an HTML error page does not.
	nonisolated static func hasGGMLMagic(_ url: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? handle.close() }
		return (try? handle.read(upToCount: 4)) == Data("lmgg".utf8)
	}
}

enum DownloadError: Error, CustomStringConvertible {
	case http(Int)
	case tooSmall(Int64)
	case truncated(Int64, Int64)
	case notAModel

	var description: String {
		switch self {
		case .http(let status): "HTTP \(status)"
		case .tooSmall(let size): "file too small (\(size) bytes)"
		case .truncated(let size, let expected): "truncated (\(size) of \(expected) bytes)"
		case .notAModel: "not a ggml model file"
		}
	}
}

/// Moves the finished file to the staging path before URLSession deletes it, and reports progress in 0.5% steps.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	let staging: URL
	let onProgress: @Sendable (Double) -> Void
	var continuation: CheckedContinuation<Int64, Error>?
	private var lastReported = -1.0
	private var moveError: Error?
	private var expectedLength: Int64 = -1

	init(staging: URL, onProgress: @escaping @Sendable (Double) -> Void) {
		self.staging = staging
		self.onProgress = onProgress
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard totalBytesExpectedToWrite > 0 else { return }
		let value = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
		if value - lastReported >= 0.005 {
			lastReported = value
			onProgress(value)
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
			moveError = DownloadError.http(response.statusCode)
			return
		}
		expectedLength = downloadTask.response?.expectedContentLength ?? -1
		do {
			try? FileManager.default.removeItem(at: staging)
			try FileManager.default.moveItem(at: location, to: staging)
		} catch {
			moveError = error
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard let continuation else { return }
		self.continuation = nil
		if let error {
			continuation.resume(throwing: error)
		} else if let moveError {
			continuation.resume(throwing: moveError)
		} else {
			continuation.resume(returning: expectedLength)
		}
	}
}
