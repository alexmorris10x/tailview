import AVFoundation
import Network
import SwiftUI

final class ViewerModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var status = "Start sharing on the Mac, then connect here."
    @Published private(set) var microphoneStatus = "Microphone is off"
    @Published private(set) var isConnected = false
    @Published private(set) var isMicrophoneOn = false

    private let networkQueue = DispatchQueue(label: "TailView.viewerNetwork")
    private let packetLock = NSLock()
    private var pendingPackets = 0
    private var connection: NWConnection?
    private var engine: AVAudioEngine?

    func connect(host: String, code: String) {
        guard connection == nil else { return }
        guard host.hasPrefix("100."), code.count == 36,
              let port = NWEndpoint.Port(rawValue: 47_820) else {
            status = "Enter the Mac Tailscale address and session code"
            return
        }
        status = "Connecting…"
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    connection.send(content: Data((code + "\n").utf8), completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self, let connection else { return }
                        if error != nil { DispatchQueue.main.async { self.disconnect(); self.status = "Could not authenticate" } }
                        else { self.receiveAuth(connection, partial: Data()) }
                    })
                case .failed(let error):
                    self.disconnect()
                    self.status = "Connection failed: \(error.localizedDescription)"
                case .cancelled: self.disconnect()
                default: break
                }
            }
        }
        connection.start(queue: networkQueue)
    }

    func disconnect() {
        stopMicrophone()
        connection?.cancel()
        connection = nil
        image = nil
        isConnected = false
        status = "Disconnected"
    }

    private func receiveAuth(_ connection: NWConnection, partial: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 3 - partial.count) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            guard error == nil, !complete, let data, !data.isEmpty else {
                DispatchQueue.main.async { self.disconnect(); self.status = "Mac closed the connection" }
                return
            }
            var partial = partial
            partial.append(data)
            guard partial.count <= 3 else {
                DispatchQueue.main.async { self.disconnect(); self.status = "Invalid Mac response" }
                return
            }
            if partial.count == 3 {
                guard partial == Data("OK\n".utf8) else {
                    DispatchQueue.main.async { self.disconnect(); self.status = "Session code rejected" }
                    return
                }
                DispatchQueue.main.async {
                    guard self.connection === connection else { return }
                    self.isConnected = true
                    self.status = "Viewing Mac screen"
                }
                self.receiveFrames(connection, parser: PacketParser())
            } else { self.receiveAuth(connection, partial: partial) }
        }
    }

    private func receiveFrames(_ connection: NWConnection, parser: PacketParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            guard error == nil, !complete, let data, !data.isEmpty else {
                DispatchQueue.main.async { self.disconnect(); self.status = "Mac connection lost" }
                return
            }
            do {
                try parser.append(data) { kind, payload in
                    guard kind == .jpeg, UIApplication.shared.applicationState == .active,
                          let image = UIImage(data: payload) else { return }
                    DispatchQueue.main.async {
                        if self.connection === connection { self.image = image }
                    }
                }
                self.receiveFrames(connection, parser: parser)
            } catch {
                DispatchQueue.main.async { self.disconnect(); self.status = "Invalid screen data" }
            }
        }
    }

    func startMicrophone() {
        guard isConnected, !isMicrophoneOn else { return }
        microphoneStatus = "Requesting microphone permission…"
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                if allowed { self.beginCapture() }
                else { self.microphoneStatus = "Microphone access is required in Settings" }
            }
        }
    }

    func stopMicrophone() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        packetLock.lock(); pendingPackets = 0; packetLock.unlock()
        isMicrophoneOn = false
        microphoneStatus = "Microphone is off"
    }

    private func beginCapture() {
        guard let connection, isConnected else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let sourceFormat = input.outputFormat(forBus: 0)
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                                   channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw MicrophoneError.unsupportedFormat
            }
            input.installTap(onBus: 0, bufferSize: 960, format: sourceFormat) { [weak self] buffer, _ in
                self?.sendMicrophone(buffer, converter: converter, format: targetFormat, connection: connection)
            }
            try engine.start()
            self.engine = engine
            isMicrophoneOn = true
            microphoneStatus = "Sending microphone to Mac"
        } catch {
            stopMicrophone()
            microphoneStatus = "Microphone failed: \(error.localizedDescription)"
        }
    }

    private func sendMicrophone(_ input: AVAudioPCMBuffer, converter: AVAudioConverter,
                                format: AVAudioFormat, connection: NWConnection) {
        packetLock.lock()
        if pendingPackets >= 8 { packetLock.unlock(); return }
        pendingPackets += 1
        packetLock.unlock()
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { packetDone(); return }
        var provided = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { packetDone(); return }
        let byteCount = Int(output.frameLength) * 2
        let payload = Data(bytes: channel, count: byteCount)
        connection.send(content: Packet.encode(.microphone, payload), completion: .contentProcessed { [weak self] error in
            self?.packetDone()
            if error != nil {
                DispatchQueue.main.async {
                    guard self?.connection === connection else { return }
                    self?.disconnect()
                    self?.status = "Mac connection lost"
                }
            }
        })
    }

    private func packetDone() {
        packetLock.lock(); pendingPackets = max(0, pendingPackets - 1); packetLock.unlock()
    }

    private enum MicrophoneError: LocalizedError {
        case unsupportedFormat
        var errorDescription: String? { "Audio format is unavailable" }
    }
}
