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
    @Published private(set) var isBrowserAccessEnabled = UserDefaults.standard.bool(forKey: "tailview.browserAccess")
    @Published private(set) var browserStatus = "Off"
    @Published private(set) var browserURL = ""
    @Published private(set) var browserLogin = ""

    let display = DisplayControlModel()

    private let pairedStore = PairedDeviceStore()
    private let controlInjector = ControlInjector()
    private let audioRouting = AudioRoutingController()
    private var capture: ScreenCapture?
    private var server: VideoServer?
    private var webServer: WebViewerServer?
    private var browserGeneration: UInt64 = 0
    private var peakMicrophoneLevel = 0.0
    private var pairingWindowID = UUID()
    private var launchGeneration: UInt64 = 0
    private var audioCaptureUpdate: Task<Void, Never>?
    private var isReplacingCapture = false
    private var lastCaptureRecovery = Date.distantPast

    init() {
        audioRoutingStatus = audioRouting.status
        audioRouting.onStatus = { [weak self] in self?.audioRoutingStatus = $0 }
        display.onDisplayConfigurationChange = { [weak self] in self?.replaceCapture(reason: nil) }
        isPaused = UserDefaults.standard.bool(forKey: "tailview.accessPaused")
        reloadPairedDevices()
        if isPaused {
            status = "Access paused"
        } else {
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    func start() {
        guard !isPaused, !isSharing, !isStarting else { return }
        launchGeneration &+= 1
        let generation = launchGeneration
        isStarting = true
        peakMicrophoneLevel = 0
        status = "Starting screen capture…"
        Task { [self] in
            do {
                let ip = try Self.tailscaleIPv4()
                let code = UUID().uuidString.lowercased()
                let sink = try? AudioSink.blackHole()
                let server = try VideoServer(address: ip, code: code, audioSink: sink)
                let store = pairedStore
                let injector = controlInjector
                server.authenticateSaved = { id, token in store.authenticate(id: id, token: token) }
                server.isPreferredMicrophone = { id in
                    (try? store.list().first { $0.id == id })?.name
                        .localizedCaseInsensitiveContains("iPad") == true
                }
                server.authorizeTrustedControl = { [weak injector] in
                    guard ControlInjector.hasPermission(), let injector else { return false }
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
                        self.audioRouting.setConnected(server.hasAudioViewer)
                        if let capture = self.capture {
                            self.updateSystemAudioCapture(server.hasAudioViewer, on: capture)
                        }
                        self.isControlEnabled = server.isControlEnabled
                        self.controlStatus = count > 0
                            ? (server.isControlEnabled ? "Trusted device can control this Mac" : "Grant macOS control permission in TailView settings")
                            : "Control is off"
                        if count == 0 {
                            self.peakMicrophoneLevel = 0
                            self.microphoneStatus = sink == nil ? "Unavailable until BlackHole 2ch is installed" : "Ready through BlackHole 2ch"
                        }
                    }
                }
                server.onControlCommand = { command in injector.submit(command) }
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
                    sessionCode = code
                    microphoneStatus = sink == nil ? "Unavailable until BlackHole 2ch is installed" : "Ready through BlackHole 2ch"
                    viewerStatus = "Waiting for a viewer"
                    status = "Sharing main display"
                    isSharing = true
                    server.start()
                    if isBrowserAccessEnabled { startBrowserAccess(for: server) }
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
        disableControl()
        server?.disablePairing()
        stopBrowserAccess()
        server?.stop()
        server = nil
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
                updateSystemAudioCapture(server.hasAudioViewer, on: replacement)
            } catch {
                stop()
                status = "Screen capture stopped: \(error.localizedDescription)"
            }
        }
    }

    func pauseAccess() {
        guard !isPaused else { return }
        isPaused = true
        UserDefaults.standard.set(true, forKey: "tailview.accessPaused")
        stop()
        status = "Access paused"
    }

    func resumeAccess() {
        guard isPaused else { return }
        isPaused = false
        UserDefaults.standard.set(false, forKey: "tailview.accessPaused")
        start()
    }

    func enableControl() {
        guard isSharing, let server, server.hasPairedViewer else {
            controlStatus = "Connect with a saved, paired device before allowing control"
            return
        }
        guard ControlInjector.hasPermission() else {
            _ = ControlInjector.requestPermission()
            controlStatus = "Allow TailView Mac in the Privacy & Security pane macOS opened, then relaunch TailView Mac and try again"
            return
        }
        controlInjector.setEnabled(true)
        server.setControlEnabled(true)
        isControlEnabled = true
        controlStatus = "Control allowed for connected trusted devices until you turn it off or sharing ends"
    }

    func requestControlPermission() {
        guard ControlInjector.hasPermission() else {
            _ = ControlInjector.requestPermission()
            controlStatus = "Allow TailView Mac in macOS Privacy & Security, then relaunch TailView Mac"
            return
        }
        if server?.hasPairedViewer == true { enableControl() }
        else { controlStatus = "Control permission is ready for trusted devices" }
    }

    func disableControl() {
        controlInjector.setEnabled(false)
        server?.setControlEnabled(false)
        isControlEnabled = false
        controlStatus = "Control is off"
    }

    func enablePairing() {
        guard isSharing, let server else { return }
        server.enablePairing()
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

    func setBrowserAccess(_ enabled: Bool) {
        guard enabled != isBrowserAccessEnabled else { return }
        isBrowserAccessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "tailview.browserAccess")
        if enabled {
            if let server, isSharing { startBrowserAccess(for: server) }
            else { browserStatus = "Starts when sharing starts" }
        } else {
            stopBrowserAccess()
            browserURL = ""
            Task.detached { _ = try? Self.runTailscale(["serve", "--https=\(WebViewerServer.port)", "off"]) }
        }
    }

    /// Listens on 127.0.0.1 and publishes that port on this Mac's tailnet
    /// HTTPS name with `tailscale serve`, which adds the identity header the
    /// browser server requires. Nothing is reachable outside the tailnet.
    private func startBrowserAccess(for server: VideoServer) {
        stopBrowserAccess()
        browserGeneration &+= 1
        let generation = browserGeneration
        browserStatus = "Starting…"
        Task { [self] in
            do {
                guard let pageURL = Bundle.main.url(forResource: "viewer", withExtension: "html") else {
                    throw HostError.message("The browser viewer page is missing from the app")
                }
                let page = try Data(contentsOf: pageURL)
                let identity = try await Task.detached { try Self.tailscaleIdentity() }.value
                let authority = "\(identity.dnsName):\(WebViewerServer.port)"
                guard generation == browserGeneration, self.server === server, isBrowserAccessEnabled else { return }
                let web = WebViewerServer(allowedLogin: identity.login, authority: authority,
                                          ownAddress: address, page: page) {
                    [weak server] fd in server?.attachBrowserViewer(fd) ?? false
                }
                web.onStatus = { [weak self] summary in
                    Task { @MainActor in
                        guard let self, self.webServer === web else { return }
                        self.browserStatus = summary
                    }
                }
                try web.start()
                webServer = web
                try await Task.detached {
                    _ = try Self.runTailscale(["serve", "--bg", "--https=\(WebViewerServer.port)",
                                               "http://127.0.0.1:\(WebViewerServer.port)"])
                }.value
                guard webServer === web else { return }
                browserURL = "https://\(authority)/"
                browserLogin = identity.login
                browserStatus = "No browser connected"
            } catch {
                if generation == browserGeneration {
                    stopBrowserAccess()
                    browserStatus = "Could not start: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopBrowserAccess() {
        browserGeneration &+= 1
        webServer?.stop()
        webServer = nil
        browserStatus = isBrowserAccessEnabled ? "Starts when sharing starts" : "Off"
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

    private struct TailscaleIdentity {
        let dnsName: String
        let login: String
    }

    /// This Mac's MagicDNS name and the login of the user who owns it.
    private nonisolated static func tailscaleIdentity() throws -> TailscaleIdentity {
        let output = try runTailscale(["status", "--json"])
        guard let status = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              let me = status["Self"] as? [String: Any],
              let dnsName = (me["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              dnsName.hasSuffix(".ts.net"),
              let userID = (me["UserID"] as? NSNumber)?.stringValue,
              let users = status["User"] as? [String: Any],
              let user = users[userID] as? [String: Any],
              let login = user["LoginName"] as? String, !login.isEmpty else {
            throw HostError.message("Tailscale did not report this Mac's name and owner; turn on MagicDNS and HTTPS")
        }
        return TailscaleIdentity(dnsName: dnsName.lowercased(), login: login)
    }

    @discardableResult
    private nonisolated static func runTailscale(_ arguments: [String]) throws -> Data {
        let paths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw HostError.message("Tailscale CLI is unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // `tailscale serve` waits for consent if HTTPS is off for the tailnet.
        let deadline = DispatchTime.now() + 20
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData.isEmpty ? data : errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw HostError.message("tailscale \(arguments.first ?? "") failed\(message.isEmpty ? "" : ": " + message)")
        }
        return data
    }

    private enum HostError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value }
        }
    }
}
