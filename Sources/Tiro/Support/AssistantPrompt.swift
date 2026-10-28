import AppKit

/// A prompt the user pastes once into an AI assistant (Claude or another one that can read files on
/// this Mac), so that "pick up my last meeting notes" points it at the Tiro folder. Always English,
/// whatever the app language; only the speaker labels follow it, because they are what the transcripts contain.
enum AssistantPrompt {
	static func text(folder: URL) -> String {
		let you = String(localized: "You")
		let others = String(localized: "Others")
		return "Remember this for our future conversations: I record my calls with Tiro, a Mac app. Each call is saved in the folder \(folder.path) as an audio file named by date, time and app, like 2026-10-28_1430_Teams.m4a. In the audio, the left channel is me and the right channel is everyone else. When transcription is on, a transcript with the same name sits next to it: a .txt where each line starts with the time and the speaker (\(you) or \(others)), and a .srt. When I ask for my last meeting, my meeting notes, or a call from a given day or app, look in that folder, pick the matching file by its name, and read its .txt transcript. If there is no transcript yet, tell me: you can transcribe the audio yourself if you have a tool for it, or I can turn on transcription in Tiro's settings."
	}

	static func copy(folder: URL) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text(folder: folder), forType: .string)
		Log.info("Assistant prompt copied")
	}
}
