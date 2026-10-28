import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
	case alreadyRecording
	case coreAudio(String, OSStatus)
	case noAudioDevice
	case unexpectedStreams(String)
	case file(String)

	var errorDescription: String? {
		switch self {
		case .alreadyRecording: return "A recording is already running."
		case let .coreAudio(call, status): return "\(call) failed (\(AudioHAL.describe(status)))."
		case .noAudioDevice: return "No audio device is available."
		case let .unexpectedStreams(detail): return "Unexpected audio stream layout: \(detail)."
		case let .file(detail): return detail
		}
	}
}

/// Thin helpers over the AudioObject property API. Every reader returns nil instead of throwing:
/// a missing property is routine (a device unplugged between two calls).
enum AudioHAL {
	static let system = AudioObjectID(kAudioObjectSystemObject)

	static func check(_ status: OSStatus, _ call: String) throws {
		if status != noErr { throw CaptureError.coreAudio(call, status) }
	}

	/// OSStatus values are often four-char codes ('!dev', 'nope'); show them that way when printable.
	static func describe(_ status: OSStatus) -> String {
		let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
		if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
			return "'\(String(decoding: bytes, as: UTF8.self))' \(status)"
		}
		return "\(status)"
	}

	static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
	}

	/// Reads a fixed-size (plain data) property.
	static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
		var addr = address(selector, scope)
		var value = initial
		var size = UInt32(MemoryLayout<T>.size)
		let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
		return status == noErr ? value : nil
	}

	static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
		var addr = address(selector)
		var value: Unmanaged<CFString>?
		var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
		let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
		guard status == noErr, let value else { return nil }
		return value.takeRetainedValue() as String
	}

	static func readIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
		var addr = address(selector, scope)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
		var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
		guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
		return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
	}

	static func defaultDevice(input: Bool) -> AudioObjectID? {
		let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
		guard let id = read(system, selector, initial: AudioObjectID(kAudioObjectUnknown)), id != kAudioObjectUnknown else { return nil }
		return id
	}

	static func deviceUID(_ device: AudioObjectID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
	static func name(_ object: AudioObjectID) -> String { readString(object, kAudioObjectPropertyName) ?? "#\(object)" }

	static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
		read(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
	}

	/// Channel count of each input stream, in IOProc buffer order.
	static func inputStreamChannels(_ device: AudioObjectID) -> [Int] {
		var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
		let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
		defer { raw.deallocate() }
		guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
		return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
	}

	/// The device itself, or for an aggregate its active subdevices that have input streams.
	static func physicalInputDevices(_ device: AudioObjectID) -> [AudioObjectID] {
		guard read(device, kAudioObjectPropertyClass, initial: AudioClassID(0)) == kAudioAggregateDeviceClassID else { return [device] }
		return readIDs(device, kAudioAggregateDevicePropertyActiveSubDeviceList).filter { !inputStreamChannels($0).isEmpty }
	}

	static func inputStreamFormats(_ device: AudioObjectID) -> [AudioStreamBasicDescription] {
		readIDs(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).compactMap {
			read($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
		}
	}

	/// The HAL's object for a process, or nil when the process has never touched audio.
	static func processObject(forPID pid: pid_t) -> AudioObjectID? {
		var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
		var qualifier = pid
		var object = AudioObjectID(kAudioObjectUnknown)
		var size = UInt32(MemoryLayout<AudioObjectID>.size)
		let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
		return status == noErr && object != kAudioObjectUnknown ? object : nil
	}

	static let hostTicksPerSecond: Double = {
		var info = mach_timebase_info_data_t()
		mach_timebase_info(&info)
		return 1_000_000_000 * Double(info.denom) / Double(info.numer)
	}()
}

/// A property listener block, kept so it can be removed: AudioObjectRemovePropertyListenerBlock matches by block identity.
final class PropertyListener {
	private let object: AudioObjectID
	private var addr: AudioObjectPropertyAddress
	private let queue: DispatchQueue
	private let block: AudioObjectPropertyListenerBlock
	private var installed = false

	init(object: AudioObjectID, selector: AudioObjectPropertySelector, queue: DispatchQueue, handler: @escaping () -> Void) {
		self.object = object
		addr = AudioHAL.address(selector)
		self.queue = queue
		block = { _, _ in handler() }
		installed = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr
	}

	func remove() {
		guard installed else { return }
		installed = false
		AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
	}

	deinit { remove() }
}
