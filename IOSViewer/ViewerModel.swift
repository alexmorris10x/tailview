import AVFoundation
import Network
import SwiftUI

final class ViewerModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var status = "Looking for your Mac…"
    @Published private(set) var microphoneStatus = "Microphone is off"
    @Published private(set) var inputLevelStatus = ""
    #if DEBUG
    @Published private(set) var debugStatus = "No diagnostic run yet"
    @Published private(set) var speakerTestStatus = "No speaker test run yet"
    #endif
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isMicrophoneOn = false
    @Published private(set) var isPairedSession = false
    @Published private(set) var isControlAllowed = false
    @Published private(set) var savedMacs = [SavedMac]()
    @Published private(set) var savedCredentialRejected = false

    private enum Credential {
        case session(String)
        case saved(SavedMac)
        case pair(SavedMac, code: String)

        var request: PairingRequest {
            switch self {
            case .session(let code): return .session(code: code)
            case .saved(let profile): return .authenticate(id: profile.id, token: profile.token)
            case .pair(let profile, let code):
                return .pair(code: code, id: profile.id, token: profile.token,
                             deviceName: UIDevice.current.name)
            }
        }

        var acknowledgment: Data {
            switch self {
            case .pair: return Data("PAIRED\n".utf8)
            default: return Data("OK\n".utf8)
            }
        }

        var rejectionMessage: String {
            switch self {
            case .session: return "Session code rejected"
            case .saved: return "Saved Mac was rejected; it may have been revoked"
            case .pair: return "Pairing rejected; open Pair a new device on the Mac"
            }
        }
    }

    private let networkQueue = DispatchQueue(label: "TailView.viewerNetwork")
    private let packetLock = NSLock()
    private var pendingPackets = 0
    private var didReportCapture = false
    private var didReportConversionFailure = false
    private var didReportSend = false
    private var inputPeak = 0.0
    private var lastInputLevelReport = 0.0
    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    #if DEBUG
    private var acousticTestPlayer: AVAudioPlayer?
    private var runRecorderTestAfterConnect = false
    private var runSyntheticTestAfterConnect = false
    private var diagnosticRecorder: AVAudioRecorder?
    private var diagnosticTimer: Timer?
    private var diagnosticPeak = -90.0
    #endif
    private var startMicrophoneAfterConnect = false
    private var inputRouteName = "iPhone microphone"

    init() {
        do { savedMacs = try SavedMacStore.load() }
        catch { status = "Could not load saved Macs: \(error.localizedDescription)" }
    }

    func pair(host: String, code: String, name: String, startMicrophoneOnConnect: Bool = true) {
        guard PairingRequest.validCode(code) else {
            status = "Enter the current session code shown on the Mac"
            return
        }
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = SavedMac(id: UUID(), name: title.isEmpty ? "My Mac" : String(title.prefix(40)),
                                   address: host, token: try SavedMacStore.newToken())
            beginConnection(host: host, credential: .pair(profile, code: code),
                            startMicrophoneOnConnect: startMicrophoneOnConnect)
        } catch {
            status = "Could not create a pairing credential: \(error.localizedDescription)"
        }
    }

    func connect(profile: SavedMac, startMicrophoneOnConnect: Bool = true) {
        savedCredentialRejected = false
        beginConnection(host: profile.address, credential: .saved(profile),
                        startMicrophoneOnConnect: startMicrophoneOnConnect)
    }

    func forget(profile: SavedMac) {
        do {
            let remaining = savedMacs.filter { $0.id != profile.id }
            try SavedMacStore.save(remaining)
            savedMacs = remaining
            savedCredentialRejected = false
            status = "Profile removed from this device; revoke it on the Mac to remove access there"
        } catch {
            status = "Could not remove profile: \(error.localizedDescription)"
        }
    }

    func connect(host: String, code: String, startMicrophoneOnConnect: Bool = false,
                 runRecorderTestOnConnect: Bool = false,
                 runSyntheticTestOnConnect: Bool = false) {
        guard PairingRequest.validCode(code) else {
            status = "Enter the current session code shown on the Mac"
            return
        }
        beginConnection(host: host, credential: .session(code),
                        startMicrophoneOnConnect: startMicrophoneOnConnect,
                        runRecorderTestOnConnect: runRecorderTestOnConnect,
                        runSyntheticTestOnConnect: runSyntheticTestOnConnect)
    }

    private func beginConnection(host: String, credential: Credential,
                                 startMicrophoneOnConnect: Bool = false,
                                 runRecorderTestOnConnect: Bool = false,
                                 runSyntheticTestOnConnect: Bool = false) {
        guard connection == nil else { return }
        guard host.hasPrefix("100."),
              let port = NWEndpoint.Port(rawValue: 47_820) else {
            status = "Enter the Mac Tailscale address (100.x.x.x)"
            return
        }
        status = "Connecting…"
        isConnecting = true
        isControlAllowed = false
        isPairedSession = false
        startMicrophoneAfterConnect = startMicrophoneOnConnect
        #if DEBUG
        runRecorderTestAfterConnect = runRecorderTestOnConnect
        runSyntheticTestAfterConnect = runSyntheticTestOnConnect
        #endif
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    connection.send(content: Data(credential.request.line.utf8), completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self, let connection else { return }
                        if error != nil { DispatchQueue.main.async { self.disconnect(); self.status = "Could not authenticate" } }
                        else { self.receiveAuth(connection, credential: credential, partial: Data()) }
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
        networkQueue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection, self.isConnecting else { return }
                self.disconnect()
                self.status = "Connection timed out"
            }
        }
    }

    func disconnect() {
        #if DEBUG
        stopDiagnostic()
        #endif
        stopMicrophone()
        connection?.cancel()
        connection = nil
        image = nil
        isConnected = false
        isConnecting = false
        isControlAllowed = false
        isPairedSession = false
        startMicrophoneAfterConnect = false
        status = "Disconnected"
    }

    private func receiveAuth(_ connection: NWConnection, credential: Credential, partial: Data) {
        let expected = credential.acknowledgment
        connection.receive(minimumIncompleteLength: 1, maximumLength: expected.count - partial.count) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            guard error == nil, !complete, let data, !data.isEmpty else {
                DispatchQueue.main.async {
                    self.disconnect()
                    if case .saved = credential { self.savedCredentialRejected = true }
                    self.status = credential.rejectionMessage
                }
                return
            }
            var partial = partial
            partial.append(data)
            guard partial.count <= expected.count else {
                DispatchQueue.main.async { self.disconnect(); self.status = "Invalid Mac response" }
                return
            }
            if partial.count == expected.count {
                guard partial == expected else {
                    DispatchQueue.main.async {
                        self.disconnect()
                        if case .saved = credential { self.savedCredentialRejected = true }
                        self.status = credential.rejectionMessage
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard self.connection === connection else { return }
                    if case .pair(let profile, _) = credential {
                        do {
                            var profiles = try SavedMacStore.load()
                            profiles.removeAll { $0.id == profile.id }
                            profiles.append(profile)
                            try SavedMacStore.save(profiles)
                            self.savedMacs = profiles
                        } catch {
                            self.disconnect()
                            self.status = "Mac paired, but this iPad could not save its profile: \(error.localizedDescription)"
                            return
                        }
                    }
                    self.isConnected = true
                    self.isConnecting = false
                    switch credential {
                    case .session: self.isPairedSession = false
                    case .saved, .pair: self.isPairedSession = true
                    }
                    self.status = "Viewing Mac screen"
                    if self.startMicrophoneAfterConnect {
                        self.startMicrophoneAfterConnect = false
                        #if DEBUG
                        if self.runRecorderTestAfterConnect {
                            self.runRecorderTestAfterConnect = false
                            self.runRecorderTest()
                        } else if self.runSyntheticTestAfterConnect {
                            self.runSyntheticTestAfterConnect = false
                            self.sendSyntheticAudioTest()
                        } else {
                            self.startMicrophone()
                        }
                        #else
                        self.startMicrophone()
                        #endif
                    }
                    self.receiveFrames(connection, parser: PacketParser())
                }
            } else { self.receiveAuth(connection, credential: credential, partial: partial) }
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
                    switch kind {
                    case .jpeg:
                        guard UIApplication.shared.applicationState == .active,
                              let image = UIImage(data: payload) else { return }
                        DispatchQueue.main.async {
                            if self.connection === connection { self.image = image }
                        }
                    case .controlState:
                        guard payload.count == 1, payload[0] <= 1 else { return }
                        DispatchQueue.main.async {
                            if self.connection === connection { self.isControlAllowed = payload[0] == 1 }
                        }
                    case .microphone, .control:
                        return
                    }
                }
                self.receiveFrames(connection, parser: parser)
            } catch {
                DispatchQueue.main.async { self.disconnect(); self.status = "Invalid screen data" }
            }
        }
    }

    func sendControl(_ command: ControlCommand) {
        guard isConnected, isPairedSession, isControlAllowed,
              let connection, let payload = command.encoded() else { return }
        connection.send(content: Packet.encode(.control, payload), completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                self.disconnect()
                self.status = "Mac connection lost while sending control"
            }
        })
    }

    func sendText(_ text: String) {
        var chunk = ""
        func flush() {
            if !chunk.isEmpty { sendControl(ControlCommand(kind: .text, text: chunk)) }
            chunk = ""
        }
        for character in text {
            let next = String(character)
            if next == "\n" || next == "\r" {
                flush()
                sendControl(ControlCommand(kind: .key, key: .returnKey))
                continue
            }
            if next == "\t" {
                flush()
                sendControl(ControlCommand(kind: .key, key: .tab))
                continue
            }
            guard next.utf16.count <= 64,
                  !next.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            if chunk.utf16.count + next.utf16.count > 64 {
                flush()
            }
            chunk += next
        }
        flush()
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
        #if DEBUG
        acousticTestPlayer?.stop()
        acousticTestPlayer = nil
        #endif
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        packetLock.lock()
        pendingPackets = 0
        didReportCapture = false
        didReportConversionFailure = false
        didReportSend = false
        inputPeak = 0
        lastInputLevelReport = 0
        packetLock.unlock()
        isMicrophoneOn = false
        microphoneStatus = "Microphone is off"
        inputLevelStatus = ""
    }

    private func beginCapture() {
        guard let connection, isConnected else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            if let builtInMicrophone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtInMicrophone)
            }
            let outputRouteName = session.currentRoute.outputs.first?.portName ?? "Unknown output"
            inputRouteName = (session.currentRoute.inputs.first?.portName ?? "Unknown input") + " → " + outputRouteName
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let sourceFormat = input.outputFormat(forBus: 0)
            inputRouteName += " · \(sourceFormat.commonFormat) \(Int(sourceFormat.sampleRate)) Hz"
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
            microphoneStatus = "Waiting for samples from \(inputRouteName)…"
            inputLevelStatus = "Input peak: waiting for samples"
        } catch {
            stopMicrophone()
            microphoneStatus = "Microphone failed: \(error.localizedDescription)"
        }
    }

    private func sendMicrophone(_ input: AVAudioPCMBuffer, converter: AVAudioConverter,
                                format: AVAudioFormat, connection: NWConnection) {
        reportInputLevel(input)
        packetLock.lock()
        let firstCapture = !didReportCapture
        didReportCapture = true
        if pendingPackets >= 8 { packetLock.unlock(); return }
        pendingPackets += 1
        packetLock.unlock()
        if firstCapture {
            DispatchQueue.main.async { [weak self] in
                if self?.isMicrophoneOn == true { self?.microphoneStatus = "Captured microphone samples; converting…" }
            }
        }
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
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else {
            packetLock.lock()
            let firstFailure = !didReportConversionFailure && !didReportSend
            didReportConversionFailure = true
            packetLock.unlock()
            if firstFailure {
                DispatchQueue.main.async { [weak self] in
                    if self?.isMicrophoneOn == true { self?.microphoneStatus = "Microphone conversion produced no audio" }
                }
            }
            packetDone()
            return
        }
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
            } else if let self {
                self.packetLock.lock()
                let firstSend = !self.didReportSend
                self.didReportSend = true
                self.packetLock.unlock()
                if firstSend {
                    DispatchQueue.main.async {
                        if self.isMicrophoneOn { self.microphoneStatus = "Audio packets sent to Mac · \(self.inputRouteName)" }
                    }
                }
            }
        })
    }

    private func reportInputLevel(_ input: AVAudioPCMBuffer) {
        var peak = 0.0
        if let channel = input.floatChannelData?[0] {
            for index in 0..<Int(input.frameLength) { peak = max(peak, abs(Double(channel[index]))) }
        } else if let channel = input.int16ChannelData?[0] {
            for index in 0..<Int(input.frameLength) { peak = max(peak, abs(Double(channel[index]) / 32768.0)) }
        } else if let channel = input.int32ChannelData?[0] {
            for index in 0..<Int(input.frameLength) { peak = max(peak, abs(Double(channel[index]) / 2147483648.0)) }
        }
        packetLock.lock()
        inputPeak = max(inputPeak, peak)
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = now - lastInputLevelReport >= 0.2
        if shouldReport { lastInputLevelReport = now }
        let heldPeak = inputPeak
        packetLock.unlock()
        if shouldReport {
            let decibels = heldPeak > 0 ? max(-90, Int((20 * log10(heldPeak)).rounded())) : -90
            DispatchQueue.main.async { [weak self] in
                if self?.isMicrophoneOn == true { self?.inputLevelStatus = "Input peak: \(decibels) dBFS" }
            }
        }
    }

    private func packetDone() {
        packetLock.lock(); pendingPackets = max(0, pendingPackets - 1); packetLock.unlock()
    }

    #if DEBUG
    func runSpeakerTest() {
        guard !isMicrophoneOn, diagnosticRecorder == nil else {
            speakerTestStatus = "Stop microphone or recording before the speaker test"
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            try playTestTone()
            speakerTestStatus = "Playing speaker tone; microphone is not involved"
            guard let player = acousticTestPlayer else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self, self.acousticTestPlayer === player, !self.isMicrophoneOn else { return }
                self.acousticTestPlayer = nil
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                self.speakerTestStatus = "Speaker test finished; microphone was not tested"
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            speakerTestStatus = "Speaker test failed: \(error.localizedDescription)"
        }
    }

    private func playTestTone() throws {
            // This tone only checks speaker playback and is never sent to the Mac.
            let sampleRate = 48_000
            let sampleCount = sampleRate * 2
            var pcm = Data(capacity: sampleCount * 2)
            for sample in 0..<sampleCount {
                let envelope = min(1.0, Double(sample) / 2_400, Double(sampleCount - sample) / 2_400)
                let value = Int16((sin(2 * .pi * 750 * Double(sample) / Double(sampleRate)) * envelope * 1_000).rounded())
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
            }
            var wave = Data()
            func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) } }
            func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) } }
            wave.append(contentsOf: "RIFF".utf8)
            append32(UInt32(36 + pcm.count))
            wave.append(contentsOf: "WAVEfmt ".utf8)
            append32(16)
            append16(1)
            append16(1)
            append32(UInt32(sampleRate))
            append32(UInt32(sampleRate * 2))
            append16(2)
            append16(16)
            wave.append(contentsOf: "data".utf8)
            append32(UInt32(pcm.count))
            wave.append(pcm)
            acousticTestPlayer = try AVAudioPlayer(data: wave)
            acousticTestPlayer?.prepareToPlay()
            guard acousticTestPlayer?.play() == true else { throw MicrophoneError.testPlaybackFailed }
    }

    func runRecorderTest(isolated: Bool = false) {
        guard diagnosticRecorder == nil else { return }
        stopMicrophone()
        debugStatus = "Requesting microphone permission…"
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else { self.debugStatus = "Microphone permission denied"; return }
                self.beginRecorderTest(isolated: isolated)
            }
        }
    }

    private func stopDiagnostic() {
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        diagnosticRecorder?.stop()
        diagnosticRecorder = nil
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("tailview-mic-diagnostic.caf"))
    }

    private func beginRecorderTest(isolated: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            if isolated {
                try session.setCategory(.record, mode: .default)
            } else {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            }
            try session.setActive(true)
            if !isolated { try session.overrideOutputAudioPort(.speaker) }
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)
            }
            let route = "\(session.currentRoute.inputs.first?.portName ?? "No input") → \(session.currentRoute.outputs.first?.portName ?? "No output") · volume \(Int((session.outputVolume * 100).rounded()))%"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tailview-mic-diagnostic.caf")
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                                           AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: 4) else { throw MicrophoneError.testRecordingFailed }
            diagnosticRecorder = recorder
            diagnosticPeak = -90
            debugStatus = "Recorder test running: \(route)"
            diagnosticTimer?.invalidate()
            diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self, let recorder = self.diagnosticRecorder else { timer.invalidate(); return }
                recorder.updateMeters()
                self.diagnosticPeak = max(self.diagnosticPeak, Double(recorder.peakPower(forChannel: 0)))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.diagnosticRecorder === recorder else { return }
                guard !isolated else { return }
                do { try self.playTestTone() }
                catch { self.debugStatus = "Tone playback failed: \(error.localizedDescription)" }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
                guard let self, self.diagnosticRecorder === recorder else { return }
                self.diagnosticTimer?.invalidate()
                self.diagnosticTimer = nil
                recorder.stop()
                self.diagnosticRecorder = nil
                self.acousticTestPlayer?.stop()
                self.acousticTestPlayer = nil
                let fileFrames = (try? AVAudioFile(forReading: url).length) ?? 0
                let recordedSeconds = Double(fileFrames) / 48_000
                let filePeak = self.recordedFilePeak(url)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                try? FileManager.default.removeItem(at: url)
                self.debugStatus = "\(isolated ? "Isolated recorder" : "Recorder") meter: \(Int(self.diagnosticPeak.rounded())) dBFS · file: \(filePeak) dBFS (\(fileFrames) frames, \(fileSize) bytes, \(String(format: "%.1f", recordedSeconds))s) · inputAvailable: \(session.isInputAvailable) · inputChannels: \(session.inputNumberOfChannels) · \(route)"
                if isolated,
                   let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? self.debugStatus.write(to: directory.appendingPathComponent("tailview-mic-diagnostic.txt"),
                                                atomically: true, encoding: .utf8)
                }
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            debugStatus = "Recorder test failed: \(error.localizedDescription)"
        }
    }

    private func recordedFilePeak(_ url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(min(file.length, 240_000))),
              (try? file.read(into: buffer)) != nil else { return -90 }
        var peak = 0.0
        for channelIndex in 0..<Int(buffer.format.channelCount) {
            if let channel = buffer.floatChannelData?[channelIndex] {
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(Double(channel[index]))) }
            } else if let channel = buffer.int16ChannelData?[channelIndex] {
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(Double(channel[index]) / 32768.0)) }
            }
        }
        return peak > 0 ? max(-90, Int((20 * log10(peak)).rounded())) : -90
    }

    func sendSyntheticAudioTest() {
        guard let connection, isConnected else {
            debugStatus = "Connect to the Mac before testing transport"
            return
        }
        debugStatus = "Sending generated PCM to Mac (microphone bypassed)…"
        let packetCount = 100
        for packet in 0..<packetCount {
            networkQueue.asyncAfter(deadline: .now() + Double(packet) * 0.02) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                var samples = Data(capacity: 960 * 2)
                for index in 0..<960 {
                    let sample = packet * 960 + index
                    let value = Int16((sin(2 * .pi * 750 * Double(sample) / 48_000) * 8_000).rounded())
                    withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
                }
                connection.send(content: Packet.encode(.microphone, samples), completion: .contentProcessed { _ in })
                if packet == packetCount - 1 {
                    DispatchQueue.main.async { self.debugStatus = "Generated PCM sent to Mac; check Mac peak (mic bypassed)" }
                }
            }
        }
    }
    #endif

    private enum MicrophoneError: LocalizedError {
        case unsupportedFormat, testPlaybackFailed, testRecordingFailed
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Audio format is unavailable"
            case .testPlaybackFailed: "Could not play through the iPhone speaker"
            case .testRecordingFailed: "Could not start a temporary diagnostic recording"
            }
        }
    }
}
