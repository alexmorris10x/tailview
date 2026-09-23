import Foundation

@MainActor
final class HostModel: ObservableObject {
    @Published private(set) var status = "Stopped"
    @Published private(set) var viewerStatus = "Disconnected"
    @Published private(set) var microphoneStatus = "Unavailable until BlackHole 2ch is installed"
    @Published private(set) var address = ""
    @Published private(set) var sessionCode = ""
    @Published private(set) var isSharing = false
    @Published private(set) var isStarting = false

    private var capture: ScreenCapture?
    private var server: VideoServer?
    private var peakMicrophoneLevel = 0.0

    func start() {
        guard !isSharing, !isStarting else { return }
        isStarting = true
        peakMicrophoneLevel = 0
        status = "Starting screen capture…"
        Task { [self] in
            do {
                let ip = try Self.tailscaleIPv4()
                let code = UUID().uuidString.lowercased()
                let capture = ScreenCapture()
                capture.onError = { [weak self] error in
                    Task { @MainActor in self?.stop(); self?.status = "Screen capture stopped: \(error.localizedDescription)" }
                }
                let sink = try? AudioSink.blackHole()
                let server = try VideoServer(address: ip, code: code, audioSink: sink)
                server.onViewerStatus = { [weak self] message in
                    Task { @MainActor in
                        self?.viewerStatus = message
                        if message == "Disconnected" {
                            self?.peakMicrophoneLevel = 0
                            self?.microphoneStatus = sink == nil ? "Unavailable until BlackHole 2ch is installed" : "Ready through BlackHole 2ch"
                        }
                    }
                }
                server.onMicrophonePacket = { [weak self] in
                    Task { @MainActor in
                        self?.microphoneStatus = sink == nil ? "Receiving voice; install BlackHole 2ch to route it" : "Receiving voice through BlackHole 2ch"
                    }
                }
                server.onMicrophoneLevel = { [weak self] level in
                    Task { @MainActor in
                        guard let self else { return }
                        self.peakMicrophoneLevel = max(self.peakMicrophoneLevel, level)
                        let decibels = level > 0 ? max(-90, Int((20 * log10(level)).rounded())) : -90
                        let peak = self.peakMicrophoneLevel > 0 ? max(-90, Int((20 * log10(self.peakMicrophoneLevel)).rounded())) : -90
                        let routing = sink == nil ? " · BlackHole 2ch needed for Mac input" : " · BlackHole 2ch"
                        self.microphoneStatus = "Voice \(decibels) dBFS · peak \(peak) dBFS\(routing)"
                    }
                }
                server.onError = { [weak self] message in
                    Task { @MainActor in self?.stop(); self?.status = message }
                }
                try await capture.start { frame in server.publish(frame) }
                server.start()
                self.capture = capture
                self.server = server
                address = ip
                sessionCode = code
                microphoneStatus = sink == nil ? "Unavailable until BlackHole 2ch is installed" : "Ready through BlackHole 2ch"
                viewerStatus = "Waiting for a viewer"
                status = "Sharing main display"
                isSharing = true
            } catch {
                status = "Could not start: \(error.localizedDescription)"
            }
            isStarting = false
        }
    }

    func stop() {
        guard isSharing || isStarting else { return }
        server?.stop()
        server = nil
        let capture = self.capture
        self.capture = nil
        Task { await capture?.stop() }
        isSharing = false
        isStarting = false
        status = "Stopped"
        viewerStatus = "Disconnected"
        microphoneStatus = "Unavailable until BlackHole 2ch is installed"
        peakMicrophoneLevel = 0
        sessionCode = ""
    }

    private static func tailscaleIPv4() throws -> String {
        let paths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw HostError.message("Tailscale CLI is unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["ip", "-4"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              ip.hasPrefix("100.") else { throw HostError.message("Connect this Mac to Tailscale") }
        return ip
    }

    private enum HostError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value }
        }
    }
}
