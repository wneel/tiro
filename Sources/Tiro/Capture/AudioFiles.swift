import AudioToolbox
import Foundation

/// Byte-level CAF handling for files Tiro wrote itself.
enum CafFile {
	/// Offset of the data chunk's size field in the header CafWriter writes.
	static let dataSizeOffset = 56

	/// Makes a CAF left by a crashed writer exact: the data chunk size is set to the bytes actually on disk,
	/// floored to whole frames, and a torn trailing frame is cut off. Returns false when the file is not a CAF.
	static func repair(_ url: URL) throws -> Bool {
		let handle = try FileHandle(forUpdating: url)
		defer { try? handle.close() }
		let length = Int64(try handle.seekToEnd())
		func readBytes(at offset: Int64, _ count: Int) throws -> Data? {
			try handle.seek(toOffset: UInt64(offset))
			let data = try handle.read(upToCount: count) ?? Data()
			return data.count == count ? data : nil
		}
		func bigEndian<T: FixedWidthInteger>(_ data: Data, at index: Int, as: T.Type) -> T {
			data.subdata(in: index..<(index + MemoryLayout<T>.size)).reduce(T(0)) { $0 << 8 | T($1) }
		}
		guard let fileHeader = try readBytes(at: 0, 8), fileHeader.prefix(4) == Data("caff".utf8) else { return false }
		var offset: Int64 = 8
		var bytesPerFrame: Int64 = 0
		while offset + 12 <= length {
			guard let chunkHeader = try readBytes(at: offset, 12) else { return false }
			let type = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
			let size = bigEndian(chunkHeader, at: 4, as: Int64.self)
			if type == "desc", let desc = try readBytes(at: offset + 12, 32) {
				bytesPerFrame = Int64(bigEndian(desc, at: 16, as: UInt32.self))
			}
			if type == "data" {
				let start = offset + 12
				guard bytesPerFrame > 0, length >= start + 4 else { return false }
				let audioBytes = (length - start - 4) / bytesPerFrame * bytesPerFrame
				let exactSize = 4 + audioBytes
				if size != exactSize {
					try handle.seek(toOffset: UInt64(offset + 4))
					try handle.write(contentsOf: withUnsafeBytes(of: exactSize.bigEndian) { Data($0) })
				}
				if length != start + exactSize { try handle.truncate(atOffset: UInt64(start + exactSize)) }
				return true
			}
			guard size >= 0 else { return false }
			offset += 12 + size
		}
		return false
	}
}

/// Reads PCM files and encodes them to AAC through ExtAudioFile (which keeps both channels; the
/// AVAssetExportSession M4A preset may fold them).
enum AudioExport {
	struct Info {
		let frames: Int64
		let sampleRate: Double
		let channels: Int
		var duration: TimeInterval { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
	}

	static let bitRatePerChannel: UInt32 = 64_000

	static func info(of url: URL) throws -> Info {
		var file: ExtAudioFileRef?
		try AudioHAL.check(ExtAudioFileOpenURL(url as CFURL, &file), "ExtAudioFileOpenURL")
		guard let file else { throw CaptureError.file("Cannot open \(url.lastPathComponent)") }
		defer { ExtAudioFileDispose(file) }
		var format = AudioStreamBasicDescription()
		var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		try AudioHAL.check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format), "FileDataFormat")
		var frames: Int64 = 0
		size = UInt32(MemoryLayout<Int64>.size)
		try AudioHAL.check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames), "FileLengthFrames")
		return Info(frames: frames, sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame))
	}

	/// Encodes `source` to an AAC .m4a at `destination` with the same rate and channel count.
	static func encodeM4A(from source: URL, to destination: URL) throws {
		var input: ExtAudioFileRef?
		try AudioHAL.check(ExtAudioFileOpenURL(source as CFURL, &input), "ExtAudioFileOpenURL")
		guard let input else { throw CaptureError.file("Cannot open \(source.lastPathComponent)") }
		defer { ExtAudioFileDispose(input) }

		var fileFormat = AudioStreamBasicDescription()
		var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		try AudioHAL.check(ExtAudioFileGetProperty(input, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat), "FileDataFormat")
		let channels = fileFormat.mChannelsPerFrame
		var client = AudioStreamBasicDescription(
			mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
			mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
			mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
		try AudioHAL.check(ExtAudioFileSetProperty(input, kExtAudioFileProperty_ClientDataFormat, size, &client), "input ClientDataFormat")

		var aac = AudioStreamBasicDescription()
		aac.mSampleRate = fileFormat.mSampleRate
		aac.mFormatID = kAudioFormatMPEG4AAC
		aac.mChannelsPerFrame = channels
		aac.mFramesPerPacket = 1024
		var outputRef: ExtAudioFileRef?
		try AudioHAL.check(ExtAudioFileCreateWithURL(destination as CFURL, kAudioFileM4AType, &aac, nil, AudioFileFlags.eraseFile.rawValue, &outputRef), "ExtAudioFileCreateWithURL")
		guard let output = outputRef else { throw CaptureError.file("Cannot create \(destination.lastPathComponent)") }
		var outputOpen = true
		defer { if outputOpen { ExtAudioFileDispose(output) } }
		try AudioHAL.check(ExtAudioFileSetProperty(output, kExtAudioFileProperty_ClientDataFormat, size, &client), "output ClientDataFormat")
		setBitRate(on: output, bitRate: bitRatePerChannel * channels)

		let chunk: UInt32 = 8192
		let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(chunk * channels))
		defer { buffer.deallocate() }
		while true {
			var frames = chunk
			var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: chunk * 4 * channels, mData: buffer))
			try AudioHAL.check(ExtAudioFileRead(input, &frames, &list), "ExtAudioFileRead")
			if frames == 0 { break }
			try AudioHAL.check(ExtAudioFileWrite(output, frames, &list), "ExtAudioFileWrite")
		}
		outputOpen = false
		// Dispose writes the moov atom; its failure means an unusable file.
		try AudioHAL.check(ExtAudioFileDispose(output), "ExtAudioFileDispose")
	}

	private static func setBitRate(on file: ExtAudioFileRef, bitRate: UInt32) {
		var converter: AudioConverterRef?
		var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
		guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter else { return }
		var rate = bitRate
		let status = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
		if status != noErr {
			Log.error("AAC bit rate \(bitRate) refused (\(AudioHAL.describe(status))); using the encoder default")
			return
		}
		// A NULL converter config makes ExtAudioFile rebuild its converter with the new settings.
		var config: OpaquePointer?
		ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<OpaquePointer?>.size), &config)
	}
}
