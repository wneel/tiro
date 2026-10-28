import Foundation

/// Removes what Whisper invents on silence or noise: credits it learned from subtitled video, and stuck loops.
enum TranscriptFilter {
	/// Dropped when a segment is exactly one of these, ignoring case and punctuation.
	static let exactHallucinations = [
		"thank you for watching",
		"thanks for watching",
		"merci d'avoir regardé",
		"merci d'avoir regardé cette vidéo",
		"sous-titrage st' 501",
	]

	/// Dropped when a segment contains one of these: they never occur in real speech.
	static let containedHallucinations = [
		"sous-titrage société radio-canada",
		"amara.org",
		"sous-titres réalisés par",
		"sous-titrage fr",
	]

	static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
		var kept: [TranscriptSegment] = []
		var runKey = ""
		var runLength = 0
		for segment in segments {
			let key = normalized(segment.text)
			guard !key.isEmpty, !isHallucination(key) else { continue }
			if key == runKey {
				runLength += 1
			} else {
				runKey = key
				runLength = 1
			}
			kept.append(segment)
			// A third identical segment means a loop: keep only the first of the run.
			if runLength == 3 {
				kept.removeLast(2)
			} else if runLength > 3 {
				kept.removeLast()
			}
		}
		return kept
	}

	static func isHallucination(_ key: String) -> Bool {
		exactHallucinations.contains { normalized($0) == key }
			|| containedHallucinations.contains { key.contains(normalized($0)) }
	}

	/// Lowercased, punctuation other than inner apostrophes, dots and hyphens removed, spaces collapsed.
	static func normalized(_ text: String) -> String {
		let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'.- "))
		let stripped = String(String.UnicodeScalarView(lowered.unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
		return stripped
			.split(separator: " ")
			.joined(separator: " ")
			.trimmingCharacters(in: CharacterSet(charactersIn: ".-' "))
	}
}
