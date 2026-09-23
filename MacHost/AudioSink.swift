import AudioToolbox
import CoreAudio
import Foundation

final class AudioSink {
    private let lock = NSLock()
    private var samples = [Int16]()
    private var queue: AudioQueueRef?
    private let framesPerBuffer = 960

    static func blackHole() throws -> AudioSink {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try ids.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!))
        }
        for id in ids {
            guard let name = stringProperty(id, selector: kAudioObjectPropertyName),
                  name.localizedCaseInsensitiveContains("BlackHole 2ch"),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else { continue }
            return try AudioSink(deviceUID: uid)
        }
        throw SinkError.unavailable
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private init(deviceUID: String) throws {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000,
                                                 mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: 4,
                                                 mFramesPerPacket: 1,
                                                 mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 2,
                                                 mBitsPerChannel: 16,
                                                 mReserved: 0)
        try Self.check(AudioQueueNewOutput(&format, { context, queue, buffer in
            let sink = Unmanaged<AudioSink>.fromOpaque(context!).takeUnretainedValue()
            sink.fill(queue: queue, buffer: buffer)
        }, Unmanaged.passUnretained(self).toOpaque(), nil, nil, 0, &queue))
        guard let queue else { throw SinkError.unavailable }
        var uid: CFString = deviceUID as CFString
        let status = withUnsafePointer(to: &uid) {
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, UnsafeRawPointer($0), UInt32(MemoryLayout<CFString>.size))
        }
        try Self.check(status)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try Self.check(AudioQueueAllocateBuffer(queue, UInt32(framesPerBuffer * 4), &buffer))
            fill(queue: queue, buffer: buffer!)
        }
        try Self.check(AudioQueueStart(queue, nil))
    }

    deinit { if let queue { AudioQueueStop(queue, true); AudioQueueDispose(queue, true) } }

    func append(_ data: Data) {
        guard data.count.isMultiple(of: 2) else { return }
        lock.lock()
        if samples.count > 24_000 { samples.removeFirst(samples.count - 9_600) }
        data.withUnsafeBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 2) {
                samples.append(Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)))
            }
        }
        lock.unlock()
    }

    func clear() { lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock() }

    private func fill(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let output = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        lock.lock()
        let count = min(framesPerBuffer, samples.count)
        for index in 0..<framesPerBuffer {
            let value: Int16 = index < count ? samples[index] : 0
            output[index * 2] = value
            output[index * 2 + 1] = value
        }
        if count > 0 { samples.removeFirst(count) }
        lock.unlock()
        buffer.pointee.mAudioDataByteSize = UInt32(framesPerBuffer * 4)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SinkError.audioStatus(status) }
    }

    private enum SinkError: LocalizedError {
        case unavailable, audioStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "BlackHole 2ch is unavailable"
            case .audioStatus(let status): return "Audio output failed (\(status))"
            }
        }
    }
}
