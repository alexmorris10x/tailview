import AVFoundation

/// AAC-LC at 48 kHz. Raw PCM needs 768 kbps for the mono microphone and
/// 1,536 kbps for stereo Mac sound; on cellular that saturated the uplink and
/// delayed control input behind queued voice. AAC uses about 64 and 128 kbps.
/// Each packet carries 1,024 frames and decodes without a magic cookie.
enum AACAudio {
    static let framesPerPacket = 1_024
    static let maximumPacketBytes = 8_192

    /// Both peers send their capabilities after sign-in, so AAC is used only
    /// when each side can decode it. Older peers never send this packet.
    static let capability: UInt8 = 1

    static let isAvailable: Bool = AACEncoder(channels: 2, bitRate: 128_000) != nil &&
        AACDecoder(channels: 1) != nil

    static func pcmFormat(channels: AVAudioChannelCount) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                      channels: channels, interleaved: true)
    }

    static func compressedFormat(channels: AVAudioChannelCount) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }
}

/// Interleaved signed 16-bit PCM in, complete AAC packets out. Partial packets
/// wait for more samples. Use from one queue at a time.
final class AACEncoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let compressedFormat: AVAudioFormat
    private let bytesPerFrame: Int
    private var pending = [AVAudioPCMBuffer]()

    init?(channels: AVAudioChannelCount, bitRate: Int) {
        guard let pcmFormat = AACAudio.pcmFormat(channels: channels),
              let compressedFormat = AACAudio.compressedFormat(channels: channels),
              let converter = AVAudioConverter(from: pcmFormat, to: compressedFormat) else { return nil }
        converter.bitRate = bitRate
        self.converter = converter
        self.pcmFormat = pcmFormat
        self.compressedFormat = compressedFormat
        bytesPerFrame = Int(channels) * 2
    }

    func encode(_ pcm: Data) -> [Data] {
        let frames = pcm.count / bytesPerFrame
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                        frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.int16ChannelData?[0] else { return [] }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { bytes in
            UnsafeMutableRawPointer(samples).copyMemory(from: bytes.baseAddress!, byteCount: frames * bytesPerFrame)
        }
        pending.append(buffer)
        var packets = [Data]()
        while true {
            let output = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 8,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, inputStatus in
                guard !pending.isEmpty else { inputStatus.pointee = .noDataNow; return nil }
                inputStatus.pointee = .haveData
                return pending.removeFirst()
            }
            if error != nil { pending.removeAll(); return packets }
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let description = descriptions[index]
                    packets.append(Data(bytes: output.data.advanced(by: Int(description.mStartOffset)),
                                        count: Int(description.mDataByteSize)))
                }
            }
            guard status == .haveData, output.packetCount > 0 else { return packets }
        }
    }
}

/// One AAC packet in, interleaved signed 16-bit PCM out. Use from one queue.
final class AACDecoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let compressedFormat: AVAudioFormat
    private let bytesPerFrame: Int

    init?(channels: AVAudioChannelCount) {
        guard let pcmFormat = AACAudio.pcmFormat(channels: channels),
              let compressedFormat = AACAudio.compressedFormat(channels: channels),
              let converter = AVAudioConverter(from: compressedFormat, to: pcmFormat) else { return nil }
        self.converter = converter
        self.pcmFormat = pcmFormat
        self.compressedFormat = compressedFormat
        bytesPerFrame = Int(channels) * 2
    }

    func decode(_ packet: Data) -> Data? {
        guard !packet.isEmpty, packet.count <= AACAudio.maximumPacketBytes else { return nil }
        let input = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 1,
                                            maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                            frameCapacity: AVAudioFrameCount(AACAudio.framesPerPacket * 2)),
              let samples = output.int16ChannelData?[0] else { return nil }
        var provided = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, inputStatus in
            if provided { inputStatus.pointee = .noDataNow; return nil }
            provided = true
            inputStatus.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * bytesPerFrame)
    }
}
