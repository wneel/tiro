import Foundation

/// The whisper.cpp ggml models Tiro offers to download.
enum WhisperModel: String, CaseIterable, Identifiable {
	case base = "base-q5_1"
	case small = "small-q5_1"
	case largeV3Turbo = "large-v3-turbo-q5_0"

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .base: String(localized: "Fast (base)")
		case .small: String(localized: "Balanced (small)")
		case .largeV3Turbo: String(localized: "Best (large-v3 turbo)")
		}
	}

	/// Rounded to 10 MB and formatted for the current locale ("60 MB", "60 Mo").
	var approximateSize: String {
		let formatter = ByteCountFormatter()
		formatter.allowedUnits = [.useMB]
		formatter.countStyle = .file
		formatter.isAdaptive = false
		let rounded = (Double(publishedBytes) / 10_000_000).rounded() * 10_000_000
		return formatter.string(fromByteCount: Int64(rounded))
	}

	var fileName: String { "ggml-\(rawValue).bin" }

	var downloadURL: URL {
		URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
	}

	/// Size of the file on Hugging Face when this list was written (2026-10-28).
	var publishedBytes: Int64 {
		switch self {
		case .base: 59_707_625
		case .small: 190_085_487
		case .largeV3Turbo: 574_041_195
		}
	}

	/// Anything smaller is a truncated download or an error page, even if upstream re-uploads the file.
	var minimumBytes: Int64 { publishedBytes * 8 / 10 }
}

/// The Silero voice activity model whisper.cpp uses to skip silence before decoding.
enum VADModel {
	static let fileName = "ggml-silero-v6.2.0.bin"
	static let downloadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(fileName)")!
	static let minimumBytes: Int64 = 700_000
}
