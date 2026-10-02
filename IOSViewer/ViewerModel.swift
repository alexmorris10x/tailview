import AVFoundation
import Network
import SwiftUI

final class ViewerModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var status = "Looking for your Mac…"
    @Published private(set) var microphoneStatus = "Microphone is off"
    @Published private(set) var inputLevelStatus = ""
    @Published private(set) var macAudioStatus = "Mac sound is off"
    @Published private(set) var macAudioOutputStatus = "Output: off"
    #if DEBUG
    @Published private(set) var debugStatus = "No diagnostic run yet"
    @Published private(set) var speakerTestStatus = "No speaker test run yet"
    #endif
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var isMicrophoneOn = false
    @Published private(set) var isMacAudioOn = false
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
    private let deliveryLock = NSLock()
    private var imageDeliveryPending = false
    private var audioDeliveriesPending = 0
    private let microphoneGate = AudioConnectionGate<NWConnection>()
    private var didReportCapture = false
    private var didReportConversionFailure = false
    private var didReportSend = false
    private var didReportNonSilentInput = false
    private var inputPeak = 0.0
    private var lastInputLevelReport = 0.0
    private var connection: NWConnection?
    private var reconnectProfile: SavedMac?
    private var reconnectWork: DispatchWorkItem?
    private var reconnectBackoff = ReconnectBackoff()
    private var reconnectGeneration: UInt64 = 0
    private var reconnectBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var reconnectBackgroundTimeRequested = false
    private var engine: AVAudioEngine?
    private var macAudioPlayer: AVAudioPlayerNode?
    private var inputTapInstalled = false
    private var queuedMacAudioFrames = 0
    private var macAudioGeneration: UInt64 = 0
    private var lastMacAudioLevelReport = 0.0
    private var routeChangeObserver: NSObjectProtocol?
    private var engineChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var audioInterrupted = false
    private var audioRecoveryAttempts = 0
    private var routeRecoveryWork: DispatchWorkItem?
    private var activeRouteSignature: String?
    private let macAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    #if DEBUG
    private var acousticTestPlayer: AVAudioPlayer?
    private var didReportBackgroundMacAudio = false
    private var didReportMacAudioPlayback = false
    private var runRecorderTestAfterConnect = false
    private var runSyntheticTestAfterConnect = false
    private var diagnosticRecorder: AVAudioRecorder?
    private var diagnosticTimer: Timer?
    private var diagnosticPeak = -90.0
    private var didRunAudioRecoveryDiagnostic = false
    private var transportDiagnosticTimer: Timer?
    private var playbackUnderruns = 0
    private var receivedMacAudioFrames = 0
    private var sentMicrophoneFrames = 0
    #endif
    private var startMicrophoneAfterConnect = false
    private var startMacAudioAfterConnect = false
    @Published private(set) var microphoneWanted = false
    @Published private(set) var macAudioWanted = false
    // The host's microphoneState packet grants both audio directions to one
    // paired viewer. Wait for it before activating an iOS audio session.
    private var audioRouteAllowed = false
    private var inputRouteName = "iPhone microphone"

    init() {
        do { savedMacs = try SavedMacStore.load() }
        catch { status = "Could not load saved Macs: \(error.localizedDescription)" }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshMacAudioOutput()
            #if DEBUG
            let session = AVAudioSession.sharedInstance()
            let input = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
            let output = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
            print("TailView route changed: \(input) → \(output), engine running: \(self.engine?.isRunning == true), mic on: \(self.isMicrophoneOn)")
            #endif
            self.scheduleAudioRouteRecovery()
        }
        engineChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let changedEngine = notification.object as? AVAudioEngine,
                  changedEngine === self.engine else { return }
            self.scheduleAudioRouteRecovery()
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.audioInterrupted = true
                self.routeRecoveryWork?.cancel()
                self.resetAudioGraph()
                self.microphoneStatus = "Audio paused by an interruption"
                self.macAudioStatus = "Audio paused by an interruption"
            } else {
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                self.audioInterrupted = !AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                self.audioRecoveryAttempts = 0
                if self.audioInterrupted {
                    self.microphoneStatus = "Return to TailView or tap Mic to resume audio"
                    self.macAudioStatus = "Return to TailView or tap Speaker to resume audio"
                } else { self.scheduleAudioRouteRecovery() }
            }
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.resetAudioGraph()
            self.audioRecoveryAttempts = 0
            self.scheduleAudioRouteRecovery()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--tailview-test-locked-audio") {
            transportDiagnosticTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.packetLock.lock()
                let sent = self.sentMicrophoneFrames
                self.packetLock.unlock()
                print("TailView health: background=\(UIApplication.shared.applicationState != .active) connected=\(self.isConnected) reconnecting=\(self.isReconnecting) microphone=\(self.isMicrophoneOn) playback=\(self.isMacAudioOn) queuedMs=\(self.queuedMacAudioFrames / 48) underruns=\(self.playbackUnderruns) receivedFrames=\(self.receivedMacAudioFrames) sentFrames=\(sent)")
            }
        }
        #endif
    }

    deinit {
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        if let engineChangeObserver { NotificationCenter.default.removeObserver(engineChangeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let mediaResetObserver { NotificationCenter.default.removeObserver(mediaResetObserver) }
        routeRecoveryWork?.cancel()
        reconnectWork?.cancel()
        #if DEBUG
        transportDiagnosticTimer?.invalidate()
        #endif
    }

    func pair(host: String, code: String, name: String, startMicrophoneOnConnect: Bool = true,
              startMacAudioOnConnect: Bool = true) {
        guard PairingRequest.validCode(code) else {
            status = "Enter the current session code shown on the Mac"
            return
        }
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = SavedMac(id: UUID(), name: title.isEmpty ? "My Mac" : String(title.prefix(40)),
                                   address: host, token: try SavedMacStore.newToken())
            beginConnection(host: host, credential: .pair(profile, code: code),
                            startMicrophoneOnConnect: startMicrophoneOnConnect,
                            startMacAudioOnConnect: startMacAudioOnConnect)
        } catch {
            status = "Could not create a pairing credential: \(error.localizedDescription)"
        }
    }

    func connect(profile: SavedMac, startMicrophoneOnConnect: Bool = true,
                 startMacAudioOnConnect: Bool = true) {
        guard connection == nil, !isReconnecting else { return }
        reconnectProfile = profile
        reconnectBackoff.reset()
        savedCredentialRejected = false
        beginConnection(host: profile.address, credential: .saved(profile),
                        startMicrophoneOnConnect: startMicrophoneOnConnect,
                        startMacAudioOnConnect: startMacAudioOnConnect)
    }

    func forget(profile: SavedMac) {
        if reconnectProfile?.id == profile.id { disconnect() }
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
                                 startMacAudioOnConnect: Bool = false,
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
        audioRouteAllowed = false
        startMicrophoneAfterConnect = startMicrophoneOnConnect
        startMacAudioAfterConnect = startMacAudioOnConnect
        if !isReconnecting {
            microphoneWanted = startMicrophoneOnConnect
            macAudioWanted = startMacAudioOnConnect
        }
        #if DEBUG
        runRecorderTestAfterConnect = runRecorderTestOnConnect
        runSyntheticTestAfterConnect = runSyntheticTestOnConnect
        #endif
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        tcp.connectionDropTime = 20
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                      using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    connection.send(content: Data(credential.request.line.utf8), completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self, let connection else { return }
                        if error != nil { self.failConnection(connection, message: "Could not authenticate; retrying…") }
                        else { self.receiveAuth(connection, credential: credential, partial: Data()) }
                    })
                case .failed(let error):
                    self.failConnection(connection, message: "Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    self.failConnection(connection, message: "Connection ended; reconnecting…")
                case .waiting:
                    self.failConnection(connection, message: "Waiting for network; reconnecting…")
                default: break
                }
            }
        }
        connection.start(queue: networkQueue)
        networkQueue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection, self.isConnecting else { return }
                self.failConnection(connection, message: "Connection timed out; reconnecting…")
            }
        }
    }

    func disconnect() {
        reconnectGeneration &+= 1
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectProfile = nil
        isReconnecting = false
        reconnectBackoff.reset()
        endReconnectBackgroundTask()
        reconnectBackgroundTimeRequested = false
        microphoneWanted = false
        macAudioWanted = false
        audioInterrupted = false
        tearDownConnection(keepingMicrophone: false)
        status = "Disconnected"
    }

    private func tearDownConnection(keepingMicrophone: Bool) {
        routeRecoveryWork?.cancel()
        routeRecoveryWork = nil
        audioRecoveryAttempts = 0
        let oldConnection = connection
        connection = nil
        microphoneGate.setConnection(nil)
        isConnected = false
        isConnecting = false
        isControlAllowed = false
        isPairedSession = false
        audioRouteAllowed = false
        image = nil
        startMicrophoneAfterConnect = false
        startMacAudioAfterConnect = false
        // Discard pending playback and microphone sends. Keep an already active,
        // user-requested mic running so a locked phone can reconnect. Samples
        // during the outage have no destination and are discarded immediately.
        macAudioGeneration &+= 1
        macAudioPlayer?.stop()
        queuedMacAudioFrames = 0
        if !keepingMicrophone {
            #if DEBUG
            stopDiagnostic()
            #endif
            resetAudioGraph()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        oldConnection?.cancel()
    }

    private func endReconnectBackgroundTask() {
        guard reconnectBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(reconnectBackgroundTask)
        reconnectBackgroundTask = .invalid
    }

    private func scheduleReconnect() {
        guard let profile = reconnectProfile, !savedCredentialRejected else { return }
        isReconnecting = true
        reconnectWork?.cancel()
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        let delay = reconnectBackoff.nextDelay()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.reconnectGeneration == generation,
                  self.connection == nil, self.isReconnecting else { return }
            self.beginConnection(host: profile.address, credential: .saved(profile),
                                 startMicrophoneOnConnect: self.microphoneWanted,
                                 startMacAudioOnConnect: self.macAudioWanted)
        }
        reconnectWork = work
        #if DEBUG
        print("TailView reconnect scheduled in \(delay)s; background=\(UIApplication.shared.applicationState != .active); microphone=\(isMicrophoneOn)")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func resumeAudioAfterForeground() {
        if isReconnecting, connection == nil {
            reconnectBackoff.reset()
            scheduleReconnect()
            return
        }
        guard isConnected, audioRouteAllowed else { return }
        audioInterrupted = false
        audioRecoveryAttempts = 0
        if macAudioWanted && !isMacAudioOn { startMacAudio(userInitiated: false) }
        if microphoneWanted && !isMicrophoneOn { startMicrophone(userInitiated: false) }
        scheduleAudioRouteRecovery()
    }

    private func failConnection(_ failed: NWConnection, message: String, rejected: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === failed else { return }
            if rejected || self.reconnectProfile == nil {
                self.disconnect()
                self.savedCredentialRejected = rejected
            } else {
                let keepMicrophone = self.microphoneWanted && self.isMicrophoneOn && self.engine?.isRunning == true
                if !keepMicrophone && !self.reconnectBackgroundTimeRequested {
                    self.reconnectBackgroundTimeRequested = true
                    self.reconnectBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Reconnect TailView") { [weak self] in
                        // iOS grants limited extra time for playback-only sessions.
                        // Ongoing microphone recording has its own audio allowance.
                        self?.endReconnectBackgroundTask()
                    }
                }
                self.tearDownConnection(keepingMicrophone: keepMicrophone)
                self.scheduleReconnect()
            }
            self.status = message
        }
    }

    private func receiveAuth(_ connection: NWConnection, credential: Credential, partial: Data) {
        let expected = credential.acknowledgment
        connection.receive(minimumIncompleteLength: 1, maximumLength: expected.count - partial.count) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            var partial = partial
            if let data { partial.append(data) }
            let isSaved: Bool
            if case .saved = credential { isSaved = true } else { isSaved = false }
            switch AuthenticationReply.parse(partial, expected: expected, savedCredential: isSaved,
                                             streamEnded: error != nil || complete || data?.isEmpty != false) {
            case .rejected:
                self.failConnection(connection, message: credential.rejectionMessage, rejected: true)
            case .invalid:
                self.failConnection(connection, message: "Invalid Mac response; retrying…")
            case .unavailable:
                self.failConnection(connection, message: "Mac unavailable during sign-in; retrying…")
            case .pending:
                self.receiveAuth(connection, credential: credential, partial: partial)
            case .accepted:
                DispatchQueue.main.async { [self] in
                    guard self.connection === connection else { return }
                    if case .pair(let profile, _) = credential {
                        do {
                            var profiles = try SavedMacStore.load()
                            profiles.removeAll { $0.id == profile.id }
                            profiles.append(profile)
                            try SavedMacStore.save(profiles)
                            self.savedMacs = profiles
                            self.reconnectProfile = profile
                        } catch {
                            self.disconnect()
                            self.status = "Mac paired, but this iPad could not save its profile: \(error.localizedDescription)"
                            return
                        }
                    }
                    self.isConnected = true
                    self.isConnecting = false
                    self.isReconnecting = false
                    self.reconnectWork?.cancel()
                    self.reconnectWork = nil
                    self.reconnectBackoff.reset()
                    #if DEBUG
                    print("TailView authenticated; background=\(UIApplication.shared.applicationState != .active)")
                    #endif
                    switch credential {
                    case .session: self.isPairedSession = false
                    case .saved, .pair: self.isPairedSession = true
                    }
                    self.status = "Viewing Mac screen"
                    if self.startMacAudioAfterConnect {
                        self.startMacAudioAfterConnect = false
                        self.macAudioWanted = true
                        self.macAudioStatus = "Waiting for this device's audio turn…"
                    }
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
                            self.microphoneWanted = true
                            self.microphoneStatus = "Waiting for this device's audio turn…"
                        }
                        #else
                        self.microphoneWanted = true
                        self.microphoneStatus = "Waiting for this device's audio turn…"
                        #endif
                    }
                    self.receiveFrames(connection, parser: PacketParser())
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--tailview-test-audio-recovery"),
                       !self.didRunAudioRecoveryDiagnostic {
                        self.didRunAudioRecoveryDiagnostic = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                            guard let self, self.isConnected, self.isMicrophoneOn else { return }
                            print("TailView diagnostic: stopping audio engine")
                            self.engine?.stop()
                            self.scheduleAudioRouteRecovery()
                        }
                    }
                    #endif
                }
            }
        }
    }

    private func receiveFrames(_ connection: NWConnection, parser: PacketParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            guard error == nil, !complete, let data, !data.isEmpty else {
                self.failConnection(connection, message: "Mac connection lost; reconnecting…")
                return
            }
            do {
                try parser.append(data) { kind, payload in
                    switch kind {
                    case .jpeg:
                        guard UIApplication.shared.applicationState == .active,
                              let image = UIImage(data: payload) else { return }
                        self.deliveryLock.lock()
                        let shouldDeliver = !self.imageDeliveryPending
                        if shouldDeliver { self.imageDeliveryPending = true }
                        self.deliveryLock.unlock()
                        guard shouldDeliver else { return }
                        DispatchQueue.main.async {
                            self.deliveryLock.lock()
                            self.imageDeliveryPending = false
                            self.deliveryLock.unlock()
                            if self.connection === connection { self.image = image }
                        }
                    case .controlState:
                        guard payload.count == 1, payload[0] <= 1 else { return }
                        DispatchQueue.main.async {
                            if self.connection === connection { self.isControlAllowed = payload[0] == 1 }
                        }
                    case .macAudio:
                        self.deliveryLock.lock()
                        // A delayed cellular burst can contain well over eight
                        // 20 ms packets. Give playback time to absorb the burst.
                        let shouldDeliver = self.audioDeliveriesPending < 150
                        if shouldDeliver { self.audioDeliveriesPending += 1 }
                        self.deliveryLock.unlock()
                        guard shouldDeliver else { return }
                        DispatchQueue.main.async {
                            self.deliveryLock.lock()
                            self.audioDeliveriesPending -= 1
                            self.deliveryLock.unlock()
                            if self.connection === connection { self.playMacAudio(payload) }
                        }
                    case .microphoneState:
                        guard payload.count == 1, payload[0] <= 1 else { return }
                        DispatchQueue.main.async {
                            if self.connection === connection {
                                self.setAudioRouteAllowed(payload[0] == 1)
                            }
                        }
                    case .microphone, .control, .microphoneRequest:
                        return
                    }
                }
                self.receiveFrames(connection, parser: parser)
            } catch {
                self.failConnection(connection, message: "Invalid screen data")
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
                self.failConnection(connection, message: "Mac connection lost while sending control")
            }
        })
    }

    func sendText(_ text: String, modifiers: [ControlCommand.Modifier]? = nil) {
        // A pasted or composed string is text, not a sequence of shortcuts.
        // Only a single key from the iOS keyboard gets modifier flags.
        let keyModifiers = text.count == 1 ? modifiers : nil
        var chunk = ""
        func flush() {
            if !chunk.isEmpty { sendControl(ControlCommand(kind: .text, text: chunk,
                                                           modifiers: keyModifiers)) }
            chunk = ""
        }
        for character in text {
            let next = String(character)
            if next == "\n" || next == "\r" {
                flush()
                sendControl(ControlCommand(kind: .key, key: .returnKey, modifiers: keyModifiers))
                continue
            }
            if next == "\t" {
                flush()
                sendControl(ControlCommand(kind: .key, key: .tab, modifiers: keyModifiers))
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

    func startMacAudio(userInitiated: Bool = true) {
        if userInitiated { audioInterrupted = false; audioRecoveryAttempts = 0 }
        macAudioWanted = true
        guard isConnected, !isMacAudioOn, !audioInterrupted else { return }
        guard audioRouteAllowed else {
            macAudioStatus = "Audio is active on another connected device"
            return
        }
        do {
            _ = try ensureAudioEngine(inputRequired: isMicrophoneOn)
            macAudioGeneration &+= 1
            queuedMacAudioFrames = 0
            lastMacAudioLevelReport = 0
            #if DEBUG
            didReportMacAudioPlayback = false
            #endif
            isMacAudioOn = true
            endReconnectBackgroundTask()
            reconnectBackgroundTimeRequested = false
            macAudioStatus = "Waiting for Mac sound…"
            activeRouteSignature = currentAudioRouteSignature()
            refreshMacAudioOutput()
        } catch {
            macAudioStatus = "Could not play Mac sound: \(error.localizedDescription)"
            scheduleAudioRouteRecovery()
        }
    }

    func stopMacAudio() {
        macAudioWanted = false
        suspendMacAudio()
        macAudioStatus = "Mac sound is off"
    }

    private func suspendMacAudio() {
        macAudioGeneration &+= 1
        macAudioPlayer?.stop()
        queuedMacAudioFrames = 0
        isMacAudioOn = false
        macAudioOutputStatus = "Output: off"
        if !isMicrophoneOn { stopAudioEngine() }
    }

    private func playMacAudio(_ payload: Data) {
        guard isConnected, isMacAudioOn, payload.count.isMultiple(of: 4),
              !payload.isEmpty, payload.count <= 65_536,
              let player = macAudioPlayer else { return }
        let frameCount = payload.count / 4
        #if DEBUG
        receivedMacAudioFrames += frameCount
        #endif
        guard let buffer = AVAudioPCMBuffer(pcmFormat: macAudioFormat,
                                             frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        var peak = 0.0
        for frame in 0..<frameCount {
            let offset = frame * 4
            let leftBits = UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
            let rightBits = UInt16(payload[offset + 2]) | (UInt16(payload[offset + 3]) << 8)
            let left = Float(Int16(bitPattern: leftBits)) / 32_768
            let right = Float(Int16(bitPattern: rightBits)) / 32_768
            channels[0][frame] = left
            channels[1][frame] = right
            peak = max(peak, Double(abs(left)), Double(abs(right)))
        }
        // Allow up to three seconds of delayed sound before discarding stale
        // playback. The old 350 ms cap repeatedly reset on cellular bursts.
        if queuedMacAudioFrames + frameCount > 144_000 {
            #if DEBUG
            print("TailView Mac sound buffer exceeded three seconds; dropping old sound")
            #endif
            macAudioGeneration &+= 1
            player.stop()
            queuedMacAudioFrames = 0
        }
        let generation = macAudioGeneration
        queuedMacAudioFrames += frameCount
        if queuedMacAudioFrames == frameCount {
            // A notification sound can be shorter than the pre-roll target.
            // Bound its wait even if capture stops producing packets in silence.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak player] in
                guard let self, let player, self.macAudioGeneration == generation,
                      self.isMacAudioOn, self.queuedMacAudioFrames > 0, !player.isPlaying else { return }
                player.play()
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.macAudioGeneration == generation else { return }
                #if DEBUG
                if peak > 0.01 && !self.didReportMacAudioPlayback {
                    self.didReportMacAudioPlayback = true
                    print("TailView played non-silent Mac sound")
                }
                #endif
                self.queuedMacAudioFrames = max(0, self.queuedMacAudioFrames - frameCount)
                if self.queuedMacAudioFrames == 0, self.isMacAudioOn,
                   self.macAudioPlayer === player {
                    #if DEBUG
                    self.playbackUnderruns += 1
                    print("TailView Mac sound buffer underrun; waiting to refill")
                    #endif
                    player.pause()
                }
            }
        }
        // Hold about 600 ms before starting or resuming after an underrun.
        if !player.isPlaying && queuedMacAudioFrames >= 28_800 { player.play() }
        #if DEBUG
        if UIApplication.shared.applicationState == .background,
           !didReportBackgroundMacAudio, peak > 0.01, player.isPlaying {
            didReportBackgroundMacAudio = true
            print("TailView played non-silent Mac sound while backgrounded")
        }
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMacAudioLevelReport >= 0.3 {
            lastMacAudioLevelReport = now
            let decibels = peak > 0 ? max(-90, Int((20 * log10(peak)).rounded())) : -90
            macAudioStatus = "Mac sound received · peak \(decibels) dBFS"
        }
    }

    private func ensureAudioEngine(inputRequired: Bool) throws -> AVAudioEngine {
        let session = AVAudioSession.sharedInstance()
        if inputRequired {
            // A2DP permits Bluetooth output while the built-in mic is active.
            // Without defaultToSpeaker, starting the mic switches an iPhone's
            // playback to its quiet receiver. Headphones still take precedence.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetoothA2DP, .defaultToSpeaker])
        } else {
            // Playback routes to selected A2DP devices automatically. Do not
            // keep playAndRecord active on the viewer that does not own the mic.
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
        if let engine {
            if !engine.isRunning { try engine.start() }
            return engine
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: macAudioFormat)
        try engine.start()
        self.engine = engine
        macAudioPlayer = player
        return engine
    }

    private func stopAudioEngine() {
        engine?.stop()
        engine = nil
        macAudioPlayer = nil
        activeRouteSignature = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func currentAudioRouteSignature() -> String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map(\.uid).joined(separator: ",")
        let outputs = session.currentRoute.outputs.map(\.uid).joined(separator: ",")
        return "\(inputs)|\(outputs)|\(session.sampleRate)|\(session.inputNumberOfChannels)|\(session.outputNumberOfChannels)"
    }

    private var audioNeedsRecovery: Bool {
        (microphoneCanRecover && !isMicrophoneOn) || (macAudioWanted && !isMacAudioOn) ||
            engine?.isRunning != true || activeRouteSignature != currentAudioRouteSignature()
    }

    private var microphoneCanRecover: Bool {
        microphoneWanted && AVAudioApplication.shared.recordPermission == .granted
    }

    private func scheduleAudioRouteRecovery() {
        guard isConnected, audioRouteAllowed, !audioInterrupted,
              microphoneCanRecover || macAudioWanted, audioNeedsRecovery,
              audioRecoveryAttempts < 5 else { return }
        routeRecoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recoverAudioRoute() }
        routeRecoveryWork = work
        // Let hardware settle; retry a failed rebuild without a notification storm.
        let delay = audioRecoveryAttempts == 0 ? 0.25 : min(4, Double(audioRecoveryAttempts))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetAudioGraph() {
        if inputTapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        microphoneGate.setConnection(nil)
        microphoneGate.resetCapture()
        macAudioGeneration &+= 1
        macAudioPlayer?.stop()
        queuedMacAudioFrames = 0
        engine?.stop()
        engine = nil
        macAudioPlayer = nil
        activeRouteSignature = nil
        isMicrophoneOn = false
        isMacAudioOn = false
        packetLock.lock()
        didReportNonSilentInput = false
        inputPeak = 0
        lastInputLevelReport = 0
        packetLock.unlock()
    }

    private func recoverAudioRoute() {
        routeRecoveryWork = nil
        guard isConnected, audioRouteAllowed, !audioInterrupted,
              microphoneCanRecover || macAudioWanted, audioNeedsRecovery else { return }
        audioRecoveryAttempts += 1
        #if DEBUG
        print("TailView rebuilding audio after route change (attempt \(audioRecoveryAttempts))")
        #endif
        resetAudioGraph()
        if microphoneCanRecover {
            beginCapture()
        }
        if macAudioWanted { startMacAudio(userInitiated: false) }
        if engine?.isRunning == true && (!microphoneCanRecover || isMicrophoneOn) && (!macAudioWanted || isMacAudioOn) {
            audioRecoveryAttempts = 0
        } else { scheduleAudioRouteRecovery() }
    }

    private func refreshMacAudioOutput() {
        guard isMacAudioOn else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let names = outputs.map(\.portName).joined(separator: ", ")
        macAudioOutputStatus = "Output: \(names.isEmpty ? "unavailable" : names)"
        #if DEBUG
        print("TailView \(macAudioOutputStatus)")
        #endif
    }

    func startMicrophone(userInitiated: Bool = true) {
        if userInitiated { audioInterrupted = false; audioRecoveryAttempts = 0 }
        microphoneWanted = true
        guard isConnected, !isMicrophoneOn, !audioInterrupted else { return }
        guard audioRouteAllowed else {
            microphoneStatus = "Audio is active on another connected device"
            return
        }
        microphoneStatus = "Requesting microphone permission…"
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.microphoneWanted, self.audioRouteAllowed, self.isConnected else { return }
                if allowed { self.beginCapture() }
                else { self.microphoneStatus = "Microphone access is required in Settings" }
            }
        }
    }

    func stopMicrophone() {
        microphoneWanted = false
        stopMicrophoneCapture()
    }

    var canTakeAudio: Bool {
        isConnected && isPairedSession && !audioRouteAllowed
    }

    func takeAudio() {
        guard canTakeAudio, let connection else { return }
        microphoneStatus = "Switching audio to this device…"
        connection.send(content: Packet.encode(.microphoneRequest, Data([1])),
                        completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                self.microphoneStatus = "Could not switch audio: Mac connection lost"
            }
        })
    }

    private func setAudioRouteAllowed(_ allowed: Bool) {
        audioRouteAllowed = allowed
        microphoneGate.setConnection(allowed ? connection : nil)
        if allowed {
            if macAudioWanted { startMacAudio(userInitiated: false) }
            if microphoneWanted { startMicrophone(userInitiated: false) }
        } else {
            suspendMacAudio()
            stopMicrophoneCapture()
            microphoneStatus = "Audio is active on another connected device"
            macAudioStatus = "Audio is active on another connected device"
        }
        if !allowed || isMicrophoneOn || isMacAudioOn || (!microphoneWanted && !macAudioWanted) {
            endReconnectBackgroundTask()
            reconnectBackgroundTimeRequested = false
        }
    }

    private func stopMicrophoneCapture() {
        microphoneGate.setConnection(nil)
        microphoneGate.resetCapture()
        #if DEBUG
        acousticTestPlayer?.stop()
        acousticTestPlayer = nil
        #endif
        if inputTapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        packetLock.lock()
        didReportCapture = false
        didReportConversionFailure = false
        didReportSend = false
        didReportNonSilentInput = false
        inputPeak = 0
        lastInputLevelReport = 0
        packetLock.unlock()
        isMicrophoneOn = false
        microphoneStatus = "Microphone is off"
        inputLevelStatus = ""
        if isMacAudioOn, isConnected {
            macAudioGeneration &+= 1
            macAudioPlayer?.stop()
            queuedMacAudioFrames = 0
            stopAudioEngine()
            do {
                _ = try ensureAudioEngine(inputRequired: false)
                macAudioStatus = "Waiting for Mac sound…"
                activeRouteSignature = currentAudioRouteSignature()
                refreshMacAudioOutput()
            } catch {
                isMacAudioOn = false
                macAudioStatus = "Could not play Mac sound: \(error.localizedDescription)"
                macAudioOutputStatus = "Output: off"
            }
        } else if !isMacAudioOn {
            stopAudioEngine()
        }
    }

    private func beginCapture() {
        guard let connection, isConnected, microphoneWanted, audioRouteAllowed,
              !isMicrophoneOn, !audioInterrupted else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            let engine = try ensureAudioEngine(inputRequired: true)
            // AVAudioEngine can abort when an input tap is attached to a running
            // playback graph. Stop it before starting both directions together.
            engine.stop()
            macAudioGeneration &+= 1
            macAudioPlayer?.stop()
            queuedMacAudioFrames = 0
            if let builtInMicrophone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtInMicrophone)
            }
            let outputRouteName = session.currentRoute.outputs.first?.portName ?? "Unknown output"
            inputRouteName = (session.currentRoute.inputs.first?.portName ?? "Unknown input") + " → " + outputRouteName
            #if DEBUG
            print("TailView microphone route: \(inputRouteName)")
            #endif
            let input = engine.inputNode
            let sourceFormat = input.outputFormat(forBus: 0)
            inputRouteName += " · \(sourceFormat.commonFormat) \(Int(sourceFormat.sampleRate)) Hz"
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                                   channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw MicrophoneError.unsupportedFormat
            }
            let generation = microphoneGate.resetCapture()
            microphoneGate.setConnection(connection)
            input.installTap(onBus: 0, bufferSize: 960, format: sourceFormat) { [weak self] buffer, _ in
                self?.sendMicrophone(buffer, converter: converter, format: targetFormat,
                                     generation: generation)
            }
            inputTapInstalled = true
            if !engine.isRunning { try engine.start() }
            isMicrophoneOn = true
            endReconnectBackgroundTask()
            reconnectBackgroundTimeRequested = false
            activeRouteSignature = currentAudioRouteSignature()
            refreshMacAudioOutput()
            microphoneStatus = "Waiting for samples from \(inputRouteName)…"
            inputLevelStatus = "Input peak: waiting for samples"
        } catch {
            stopMicrophoneCapture()
            microphoneStatus = "Microphone failed: \(error.localizedDescription)"
            scheduleAudioRouteRecovery()
        }
    }

    private func sendMicrophone(_ input: AVAudioPCMBuffer, converter: AVAudioConverter,
                                format: AVAudioFormat, generation: UInt64) {
        reportInputLevel(input)
        packetLock.lock()
        let firstCapture = !didReportCapture
        didReportCapture = true
        packetLock.unlock()
        if firstCapture {
            DispatchQueue.main.async { [weak self] in
                if self?.isMicrophoneOn == true { self?.microphoneStatus = "Captured microphone samples; converting…" }
            }
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48_000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
            return
        }
        let frames = Int(output.frameLength)
        guard let ticket = microphoneGate.reserve(frames: frames, capture: generation) else { return }
        let connection = ticket.connection
        let byteCount = frames * 2
        let payload = Data(bytes: channel, count: byteCount)
        connection.send(content: Packet.encode(.microphone, payload), completion: .contentProcessed { [weak self] error in
            self?.microphoneGate.complete(ticket)
            if error != nil {
                DispatchQueue.main.async {
                    guard self?.connection === connection else { return }
                    self?.failConnection(connection, message: "Mac connection lost; reconnecting…")
                }
            } else if let self {
                self.packetLock.lock()
                #if DEBUG
                self.sentMicrophoneFrames += frames
                #endif
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
        #if DEBUG
        let firstNonSilentInput = peak > 0.002 && !didReportNonSilentInput
        if firstNonSilentInput { didReportNonSilentInput = true }
        #endif
        inputPeak = max(inputPeak, peak)
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = now - lastInputLevelReport >= 0.2
        if shouldReport { lastInputLevelReport = now }
        let heldPeak = inputPeak
        packetLock.unlock()
        #if DEBUG
        if firstNonSilentInput {
            print("TailView microphone captured non-silent input: \(max(-90, Int((20 * log10(peak)).rounded()))) dBFS")
        }
        #endif
        if shouldReport {
            let decibels = heldPeak > 0 ? max(-90, Int((20 * log10(heldPeak)).rounded())) : -90
            DispatchQueue.main.async { [weak self] in
                if self?.isMicrophoneOn == true { self?.inputLevelStatus = "Input peak: \(decibels) dBFS" }
            }
        }
    }

    #if DEBUG
    func runSpeakerTest() {
        guard !isMicrophoneOn, !isMacAudioOn, diagnosticRecorder == nil else {
            speakerTestStatus = "Stop microphone and Mac sound before the speaker test"
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
        stopMacAudio()
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
                print("TailView \(self.debugStatus)")
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
