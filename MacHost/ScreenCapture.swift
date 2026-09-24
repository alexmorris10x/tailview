import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onError: ((Error) -> Void)?
    private var stream: SCStream?
    private var onFrame: ((Data) -> Void)?
    private var onAudio: ((Data) -> Void)?
    private var audioConverter: AVAudioConverter?
    private var audioInputFormat: AVAudioFormat?
    private var captureWidth = 0
    private var captureHeight = 0
    private var capturesAudio = false
    private let imageContext = CIContext(options: [.useSoftwareRenderer: false])
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                            channels: 2, interleaved: true)!

    func start(onFrame: @escaping (Data) -> Void, onAudio: @escaping (Data) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let scale = min(1.0, 1280.0 / Double(display.width))
        captureWidth = max(1, Int(Double(display.width) * scale))
        captureHeight = max(1, Int(Double(display.height) * scale))
        let config = makeConfiguration(capturesAudio: false)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "TailView.screenFrames"))
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "TailView.systemAudio"))
        self.onFrame = onFrame
        self.onAudio = onAudio
        self.stream = stream
        do { try await stream.startCapture() }
        catch { self.stream = nil; self.onFrame = nil; self.onAudio = nil; throw error }
    }

    /// System audio is captured only while a trusted viewer is connected.
    func setSystemAudioEnabled(_ enabled: Bool) async throws {
        guard let stream, capturesAudio != enabled else { return }
        try await stream.updateConfiguration(makeConfiguration(capturesAudio: enabled))
        capturesAudio = enabled
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        onFrame = nil
        onAudio = nil
        capturesAudio = false
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if outputType == .audio {
            handleAudio(sampleBuffer)
            return
        }
        guard outputType == .screen,
              let buffer = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus), status != .complete { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        onFrame?(data as Data)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFrame = nil
        onAudio = nil
        onError?(error)
    }

    private func makeConfiguration(capturesAudio: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = capturesAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate,
                                              channels: description.mChannelsPerFrame) else { return }
        if audioInputFormat?.isEqual(inputFormat) != true {
            audioInputFormat = inputFormat
            audioConverter = AVAudioConverter(from: inputFormat, to: audioFormat)
        }
        guard let audioConverter else { return }
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                               bufferListNoCopy: audioBufferList.unsafePointer) else { return }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / inputFormat.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: capacity) else { return }
            var provided = false
            var error: NSError?
            audioConverter.convert(to: output, error: &error) { _, status in
                if provided { status.pointee = .noDataNow; return nil }
                provided = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, output.frameLength > 0,
                  let samples = output.int16ChannelData?[0] else { return }
            let frameCount = Int(output.frameLength)
            for firstFrame in stride(from: 0, to: frameCount, by: 960) {
                let count = min(960, frameCount - firstFrame)
                onAudio?(Data(bytes: samples.advanced(by: firstFrame * 2), count: count * 4))
            }
        }
    }

    private enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display is available to share" }
    }
}
