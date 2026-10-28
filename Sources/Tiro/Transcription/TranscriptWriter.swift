import Foundation

/// Writes the merged transcript next to the recording: a readable .txt and a .srt for players.
enum TranscriptWriter {
	struct Line {
		var speaker: String?
		var segment: TranscriptSegment
	}

	/// `channels[i]` holds the segments of speaker `speakers[i]`. A nil speaker prints no label.
	static func merge(_ channels: [[TranscriptSegment]], speakers: [String?]) -> [Line] {
		zip(channels, speakers)
			.flatMap { segments, speaker in segments.map { Line(speaker: speaker, segment: $0) } }
			.sorted { $0.segment.start < $1.segment.start }
	}

	static func text(_ lines: [Line]) -> String {
		var turns: [(start: Double, speaker: String?, text: String)] = []
		for line in lines {
			if let last = turns.last, last.speaker == line.speaker {
				turns[turns.count - 1].text += " " + line.segment.text
			} else {
				turns.append((line.segment.start, line.speaker, line.segment.text))
			}
		}
		return turns.map { turn in
			let label = turn.speaker.map { "\($0): " } ?? ""
			return "[\(clock(turn.start))] \(label)\(turn.text)"
		}
		.joined(separator: "\n") + (turns.isEmpty ? "" : "\n")
	}

	static func srt(_ lines: [Line]) -> String {
		lines.enumerated().map { index, line in
			let label = line.speaker.map { "\($0): " } ?? ""
			let end = max(line.segment.end, line.segment.start + 0.5)
			return "\(index + 1)\n\(srtTime(line.segment.start)) --> \(srtTime(end))\n\(label)\(line.segment.text)\n"
		}
		.joined(separator: "\n")
	}

	/// Returns the URL of the .txt.
	static func write(_ lines: [Line], nextTo audioURL: URL) throws -> URL {
		let base = audioURL.deletingPathExtension()
		let txtURL = base.appendingPathExtension("txt")
		try Data(text(lines).utf8).write(to: txtURL, options: .atomic)
		try Data(srt(lines).utf8).write(to: base.appendingPathExtension("srt"), options: .atomic)
		return txtURL
	}

	static func clock(_ seconds: Double) -> String {
		let total = Int(seconds.rounded(.down))
		return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
	}

	static func srtTime(_ seconds: Double) -> String {
		let millis = Int((seconds * 1000).rounded())
		return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
	}
}
