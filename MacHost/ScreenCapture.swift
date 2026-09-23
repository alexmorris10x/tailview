import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onError: ((Error) -> Void)?
    private var stream: SCStream?
    private var onFrame: ((Data) -> Void)?
    private let imageContext = CIContext(options: [.useSoftwareRenderer: false])

    func start(onFrame: @escaping (Data) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1.0, 1280.0 / Double(display.width))
        config.width = max(1, Int(Double(display.width) * scale))
        config.height = max(1, Int(Double(display.height) * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "TailView.screenFrames"))
        self.onFrame = onFrame
        self.stream = stream
        do { try await stream.startCapture() }
        catch { self.stream = nil; self.onFrame = nil; throw error }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        onFrame = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
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
        onError?(error)
    }

    private enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display is available to share" }
    }
}
