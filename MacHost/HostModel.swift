import AppKit
import CoreGraphics
import Foundation

@MainActor
final class HostModel: ObservableObject {
    @Published private(set) var status = "Stopped"
    @Published private(set) var viewerStatus = "Disconnected"
    @Published private(set) var microphoneStatus = "Start sharing to receive the device microphone"
    @Published private(set) var systemAudioStatus = "Waiting for a trusted viewer"
    @Published private(set) var audioRoutingStatus = "Waiting for a paired viewer"
    @Published private(set) var linkStatus = "No measurements yet"
    @Published private(set) var address = ""
    @Published private(set) var sessionCode = ""
    @Published private(set) var isSharing = false
    @Published private(set) var isStarting = false
    @Published private(set) var isPairingOpen = false
    @Published private(set) var pairedDevices = [PairedDeviceRecord]()
    @Published private(set) var pairingStatus = ""
    @Published private(set) var isControlEnabled = false
    @Published private(set) var controlStatus = "Control is off"
    @Published private(set) var isPaused = false
    @Published private(set) var sharingWasEnabled = false
    @Published private(set) var allowsRemoteControl = false
    @Published private(set) var automaticAudioRouting = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var tailscaleStatus = "Checking Tailscale…"
    @Published private(set) var tailscaleAddress = ""
    @Published private(set) var isTailscaleInstalled = false
    @Published private(set) var isCheckingSetup = false

    let display = DisplayControlModel()

    private let pairedStore: PairedDeviceStore
    private let consent: HostConsent
    private let controlInjector = ControlInjector()
    private let audioRouting = AudioRoutingController()
    private var capture: ScreenCapture?
    private var server: VideoServer?
    private var microphoneSink: AudioSink?
    private var peakMicrophoneLevel = 0.0
    private var pairingWindowID = UUID()
    private var launchGeneration: UInt64 = 0
    private var audioCaptureUpdate: Task<Void, Never>?
    private var isReplacingCapture = false
    private var lastCaptureRecovery = Date.distantPast

    init() {
        let store = PairedDeviceStore()
        pairedStore = store
        consent = HostConsent(hasPairedDevices: (try? store.list().isEmpty) == false)
        allowsRemoteControl = consent.remoteControlAllowed
        automaticAudioRouting = consent.automaticAudioRoutingEnabled
        sharingWasEnabled = consent.sharingEnabled
        audioRoutingStatus = audioRouting.status
        audioRouting.onStatus = { [weak self] in self?.audioRoutingStatus = $0 }
        audioRouting.setEnabled(automaticAudioRouting)
        display.onDisplayConfigurationChange = { [weak self] in self?.replaceCapture(reason: nil) }
        isPaused = UserDefaults.standard.bool(forKey: "tailview.accessPaused")
        reloadPairedDevices()
        status = isPaused ? "Access paused" : "Sharing is off"
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSetup()
            if self.consent.sharingEnabled && !self.isPaused { self.beginSharing() }
        }
    }

    /// This is a deliberate user action. Startup uses beginSharing only when a
    /// previous sharing choice exists; a fresh install never starts capture.
    func start() {
        consent.sharingEnabled = true
        sharingWasEnabled = true
        isPaused = false
        UserDefaults.standard.set(false, forKey: "tailview.accessPaused")
        if !CGPreflightScreenCaptureAccess() { requestScreenRecordingPermission() }
        beginSharing()
    }

    private func beginSharing() {
        guard !isPaused, !isSharing, !isStarting else { return }
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        guard hasScreenRecordingPermission else {
            status = "Allow Screen Recording in System Settings, then start sharing. macOS may ask you to reopen TailView."
            return
        }
        launchGeneration &+= 1
        let generation = launchGeneration
        isStarting = true
        peakMicrophoneLevel = 0
        status = "Starting screen capture…"
        Task { [self] in
            do {
                let setup = await TailscaleSetup.check()
                applyTailscaleSetup(setup)
                guard generation == launchGeneration, !isPaused else { return }
                guard let ip = setup.address else { throw HostError.message(setup.message) }
                let server = try VideoServer(address: ip, audioSink: nil)
                let store = pairedStore
                let injector = controlInjector
                let consent = self.consent
                server.authenticateSaved = { [weak self] id, token in
                    let result = store.authenticate(id: id, token: token)
                    if result == .unavailable {
                        Task { @MainActor in
                            self?.pairingStatus = "Could not read paired devices; they will retry"
                        }
                    }
                    return result
                }
                server.isPreferredMicrophone = { id in
                    (try? store.list().first { $0.id == id })?.name
                        .localizedCaseInsensitiveContains("iPad") == true
                }
                server.authorizeTrustedControl = { [weak injector] in
                    guard consent.remoteControlAllowed, ControlInjector.hasPermission(), let injector else { return false }
                    injector.setEnabled(true)
                    return true
                }
                server.onControlSessionEnded = { [weak injector] in injector?.setEnabled(false) }
                server.onPairingRequest = { [weak self] id, name, token in
                    do {
                        try store.add(id: id, name: name, token: token)
                        return true
                    } catch {
                        Task { @MainActor in self?.pairingStatus = "Could not save pairing: \(error.localizedDescription)" }
                        return false
                    }
                }
                server.onPairingSuccess = { [weak self] _, name in
                    Task { @MainActor in
                        self?.reloadPairedDevices()
                        self?.isPairingOpen = false
                        self?.sessionCode = ""
                        self?.pairingStatus = "Paired \(name)"
                    }
                }
                server.onViewerStatus = { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.isSharing, self.server === server else { return }
                        let count = server.viewerCount
                        self.viewerStatus = count == 0 ? "Disconnected" :
                            "\(count) viewer\(count == 1 ? "" : "s") connected"
                        if count == 0 { self.linkStatus = "No measurements yet" }
                        self.audioRouting.setConnected(server.hasPairedViewer)
                        if let capture = self.capture {
                            self.updateSystemAudioCapture(server.hasPairedViewer, on: capture)
                        }
                        self.updateControlStatus()
                        if count == 0 {
                            self.peakMicrophoneLevel = 0
                            self.updateMicrophoneStatus()
                        }
                    }
                }
                server.onControlCommand = { command in injector.submit(command) }
                server.onPaste = { text in injector.paste(text) }
                server.onMicrophonePacket = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.automaticAudioRouting else { return }
                        self.microphoneStatus = "Receiving voice through BlackHole 2ch"
                    }
                }
                server.onMicrophoneLevel = { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.automaticAudioRouting else { return }
                        self.peakMicrophoneLevel = max(self.peakMicrophoneLevel, level)
                        let decibels = level > 0 ? max(-90, Int((20 * log10(level)).rounded())) : -90
                        let peak = self.peakMicrophoneLevel > 0 ? max(-90, Int((20 * log10(self.peakMicrophoneLevel)).rounded())) : -90
                        self.microphoneStatus = "Voice \(decibels) dBFS · peak \(peak) dBFS · BlackHole 2ch"
                    }
                }
                server.onLinkStats = { [weak self] summary in
                    Task { @MainActor in self?.linkStatus = summary }
                }
                server.onError = { [weak self] message in
                    Task { @MainActor in self?.stop(); self?.status = message }
                }
                let capture = try await startCapture(for: server)
                if generation != launchGeneration || isPaused {
                    await capture.stop()
                } else {
                    self.capture = capture
                    self.server = server
                    address = ip
                    sessionCode = ""
                    viewerStatus = "Waiting for a viewer"
                    status = "Sharing main display"
                    isSharing = true
                    updateMicrophoneRouting()
                    updateControlStatus()
                    server.start()
                }
            } catch {
                if generation == launchGeneration { status = "Could not start: \(error.localizedDescription)" }
            }
            if generation == launchGeneration { isStarting = false }
        }
    }

    func stop() {
        guard isSharing || isStarting else { return }
        launchGeneration &+= 1
        controlInjector.setEnabled(false)
        server?.setControlEnabled(false)
        isControlEnabled = false
        controlStatus = "Control is off"
        server?.disablePairing()
        server?.stop()
        server?.setAudioSink(nil)
        server = nil
        microphoneSink = nil
        audioRouting.setConnected(false)
        let capture = self.capture
        self.capture = nil
        let audioCaptureUpdate = self.audioCaptureUpdate
        self.audioCaptureUpdate = nil
        Task { await audioCaptureUpdate?.value; await capture?.stop() }
        isSharing = false
        isStarting = false
        status = isPaused ? "Access paused" : "Stopped"
        viewerStatus = "Disconnected"
        microphoneStatus = "Start sharing to receive the device microphone"
        systemAudioStatus = "Waiting for a trusted viewer"
        peakMicrophoneLevel = 0
        sessionCode = ""
        isPairingOpen = false
    }

    /// Starts a stream on the current main display. A stream that fails
    /// (for example, because its display disconnected) is replaced once.
    private func startCapture(for server: VideoServer) async throws -> ScreenCapture {
        let capture = ScreenCapture()
        capture.onError = { [weak self, weak capture] error in
            Task { @MainActor in
                guard let self, let capture, self.capture === capture else { return }
                self.replaceCapture(reason: error)
            }
        }
        try await capture.start(onFrame: { frame in server.publish(frame) },
                                onAudio: { pcm in server.publishAudio(pcm) })
        return capture
    }

    /// Moves sharing to the current main display while viewers stay connected.
    private func replaceCapture(reason: Error?) {
        guard isSharing, let server, let previous = capture, !isReplacingCapture else { return }
        if let reason, Date().timeIntervalSince(lastCaptureRecovery) < 5 {
            stop()
            status = "Screen capture stopped: \(reason.localizedDescription)"
            return
        }
        if reason != nil { lastCaptureRecovery = Date() }
        isReplacingCapture = true
        status = "Switching to the current main display…"
        Task { [self] in
            defer { isReplacingCapture = false }
            // Let macOS finish reconfiguring displays before choosing one.
            try? await Task.sleep(for: .seconds(1))
            await audioCaptureUpdate?.value
            guard isSharing, self.server === server, capture === previous else { return }
            capture = nil
            await previous.stop()
            do {
                let replacement = try await startCapture(for: server)
                guard isSharing, self.server === server else {
                    await replacement.stop()
                    return
                }
                capture = replacement
                status = "Sharing main display"
                updateSystemAudioCapture(server.hasPairedViewer, on: replacement)
            } catch {
                stop()
                status = "Screen capture stopped: \(error.localizedDescription)"
            }
        }
    }

    func pauseAccess() {
        guard !isPaused else { return }
        isPaused = true
        consent.sharingEnabled = false
        UserDefaults.standard.set(true, forKey: "tailview.accessPaused")
        stop()
        status = "Access paused"
    }

    func resumeAccess() { start() }

    func setRemoteControlAllowed(_ allowed: Bool) {
        consent.remoteControlAllowed = allowed
        allowsRemoteControl = allowed
        if allowed && !ControlInjector.hasPermission() { requestControlPermission() }
        synchronizeControlPermission()
    }

    func requestControlPermission() {
        if !ControlInjector.hasPermission() {
            _ = ControlInjector.requestPermission()
            openSettings("Privacy_Accessibility")
        }
        hasAccessibilityPermission = ControlInjector.hasPermission()
        synchronizeControlPermission()
    }

    private func synchronizeControlPermission() {
        hasAccessibilityPermission = ControlInjector.hasPermission()
        let enabled = allowsRemoteControl && hasAccessibilityPermission && server?.hasPairedViewer == true
        controlInjector.setEnabled(enabled)
        server?.setControlEnabled(enabled)
        updateControlStatus()
    }

    private func updateControlStatus() {
        isControlEnabled = server?.isControlEnabled == true
        if !allowsRemoteControl { controlStatus = "View only · remote control is off" }
        else if !hasAccessibilityPermission { controlStatus = "Allow Accessibility in System Settings to use remote control" }
        else if isControlEnabled { controlStatus = "Paired devices can control this Mac" }
        else { controlStatus = "Ready · control starts when a paired viewer connects" }
    }

    func setAutomaticAudioRouting(_ enabled: Bool) {
        consent.automaticAudioRoutingEnabled = enabled
        automaticAudioRouting = enabled
        audioRouting.setEnabled(enabled)
        updateMicrophoneRouting()
    }

    private func updateMicrophoneRouting() {
        guard let server else { updateMicrophoneStatus(); return }
        guard automaticAudioRouting else {
            server.setAudioSink(nil)
            microphoneSink = nil
            updateMicrophoneStatus()
            return
        }
        guard microphoneSink == nil else { return }
        do {
            let sink = try AudioSink.blackHole()
            microphoneSink = sink
            server.setAudioSink(sink)
            microphoneStatus = "Ready through BlackHole 2ch"
        } catch {
            server.setAudioSink(nil)
            microphoneStatus = "Install BlackHole 2ch separately, then check setup again"
        }
    }

    private func updateMicrophoneStatus() {
        microphoneStatus = automaticAudioRouting
            ? "Remote microphone enabled · BlackHole 2ch is required"
            : "Off · enable automatic audio routing to use a viewer’s microphone in Mac apps"
    }

    func refreshSetup() async {
        guard !isCheckingSetup else { return }
        isCheckingSetup = true
        defer { isCheckingSetup = false }
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        synchronizeControlPermission()
        applyTailscaleSetup(await TailscaleSetup.check())
        if isSharing { updateMicrophoneRouting() }
    }

    private func applyTailscaleSetup(_ setup: TailscaleSetup) {
        tailscaleStatus = setup.message
        tailscaleAddress = setup.address ?? ""
        isTailscaleInstalled = setup.isInstalled
    }

    func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        if !hasScreenRecordingPermission { openSettings("Privacy_ScreenCapture") }
    }

    func openTailscale() {
        if let path = TailscaleSetup.applicationPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let url = URL(string: "https://tailscale.com/download/mac") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }

    func enablePairing() {
        guard isSharing, let server else { return }
        sessionCode = server.enablePairing()
        pairingWindowID = UUID()
        let windowID = pairingWindowID
        isPairingOpen = true
        pairingStatus = "Pairing is open for five minutes or until one device pairs"
        Task { [weak self, weak server] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, self.server === server, self.isPairingOpen,
                  self.pairingWindowID == windowID else { return }
            self.disablePairing()
        }
    }

    func disablePairing() {
        server?.disablePairing()
        isPairingOpen = false
        sessionCode = ""
        pairingWindowID = UUID()
        pairingStatus = "Pairing closed"
    }

    func revoke(_ id: UUID) {
        do {
            try pairedStore.revoke(id: id)
            server?.disconnectPairedDevice(id)
            reloadPairedDevices()
            pairingStatus = "Device access revoked"
        } catch {
            pairingStatus = "Could not revoke device: \(error.localizedDescription)"
        }
    }

    private func reloadPairedDevices() {
        do { pairedDevices = try pairedStore.list() }
        catch { pairingStatus = "Could not read paired devices: \(error.localizedDescription)" }
    }

    private func updateSystemAudioCapture(_ enabled: Bool, on capture: ScreenCapture) {
        systemAudioStatus = enabled ? "Starting Mac sound capture…" : "Waiting for a trusted viewer"
        let previous = audioCaptureUpdate
        audioCaptureUpdate = Task { [weak self, weak capture] in
            await previous?.value
            guard let self, let capture, self.capture === capture, self.isSharing else { return }
            do {
                try await capture.setSystemAudioEnabled(enabled)
                if self.capture === capture {
                    self.systemAudioStatus = enabled ? "Sending Mac sound to the selected audio device" : "Waiting for a trusted viewer"
                }
            } catch {
                if self.capture === capture {
                    self.systemAudioStatus = "Mac sound capture failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private enum HostError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value }
        }
    }
}
