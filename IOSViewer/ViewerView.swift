import Combine
import SwiftUI

struct ViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("macAddress") private var macAddress = ""
    @AppStorage("preferredMacID") private var preferredMacID = ""
    @AppStorage("alignScreenToTop") private var alignScreenToTop = false
    @AppStorage("microphoneOnConnect") private var microphoneOnConnect = true
    @AppStorage("macAudioOnConnect") private var macAudioOnConnect = true
    @State private var code = ""
    @State private var profileName = "My Mac"
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var automaticConnection = true
    @State private var didRunDebugLaunch = false
    @State private var diagnosticLaunch = false
    @State private var pointer = CGPoint(x: 0.5, y: 0.5)
    @State private var isDraggingRemote = false
    @State private var keyboardActive = false
    @State private var keyboardFocusRequest = 0
    @State private var screenZoom: CGFloat = 1
    @State private var screenOffset = CGSize.zero
    @StateObject private var viewer = ViewerModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomLeading) {
                if let image = viewer.image {
                    RemoteScreenView(image: image, alignTop: alignScreenToTop,
                                     controlAllowed: viewer.isControlAllowed,
                                     isDraggingRemote: isDraggingRemote,
                                     pointer: $pointer, zoom: $screenZoom, offset: $screenOffset,
                                     onCommand: viewer.sendControl)
                } else {
                    connectionView
                }
                RemoteKeyboardInput(
                    isActive: keyboardActive && viewer.isControlAllowed && !showSettings,
                    focusRequest: keyboardFocusRequest,
                    onText: viewer.sendText,
                    onDelete: { sendKey(.delete) },
                    onReturn: { sendKey(.returnKey) }
                )
                .frame(width: 1, height: 1)
            }
            .background(.black)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewer.isConnected { controlBar }
            }
            .navigationTitle("TailView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        keyboardActive = false
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("tailview.settings")
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                if viewer.isControlAllowed {
                    keyboardActive = true
                    keyboardFocusRequest += 1
                }
            }) {
                settingsView
            }
        }
        .onChange(of: viewer.isConnected) { _, connected in
            if connected {
                showPairing = false
                automaticConnection = true
                code = ""
                if preferredMacID.isEmpty, let profile = viewer.savedMacs.last {
                    preferredMacID = profile.id.uuidString
                }
            } else {
                keyboardActive = false
                isDraggingRemote = false
                screenZoom = 1
                screenOffset = .zero
            }
        }
        .onChange(of: viewer.isControlAllowed) { _, allowed in
            keyboardActive = allowed && !showSettings
            if allowed { keyboardFocusRequest += 1 }
            else { isDraggingRemote = false }
        }
        .onChange(of: microphoneOnConnect) { _, enabled in
            guard viewer.isConnected else { return }
            if enabled { viewer.startMicrophone() }
            else { viewer.stopMicrophone() }
        }
        .onChange(of: macAudioOnConnect) { _, enabled in
            guard viewer.isConnected else { return }
            if enabled { viewer.startMacAudio() }
            else { viewer.stopMacAudio() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connectPreferredIfNeeded() }
        }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            connectPreferredIfNeeded()
        }
        .task {
            #if DEBUG
            if !didRunDebugLaunch {
                didRunDebugLaunch = true
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--tailview-test-isolated-recorder") {
                    diagnosticLaunch = true
                    viewer.runRecorderTest(isolated: true)
                    return
                }
                if arguments.contains("--tailview-test-saved-microphone"),
                   let profile = viewer.savedMacs.first {
                    diagnosticLaunch = true
                    viewer.connect(profile: profile, startMicrophoneOnConnect: true,
                                   startMacAudioOnConnect: false)
                    return
                }
                if let index = arguments.firstIndex(of: "--tailview-test-connect"),
                   arguments.count > index + 2 {
                    diagnosticLaunch = true
                    macAddress = arguments[index + 1]
                    code = arguments[index + 2]
                    viewer.connect(host: macAddress, code: code, startMicrophoneOnConnect: true,
                                   runRecorderTestOnConnect: arguments.contains("--tailview-test-recorder"),
                                   runSyntheticTestOnConnect: arguments.contains("--tailview-test-synthetic"))
                    return
                }
            }
            #endif
            connectPreferredIfNeeded()
        }
    }

    private var connectionView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ContentUnavailableView("Waiting for Mac", systemImage: "display",
                                       description: Text(viewer.status))
                    .frame(maxWidth: .infinity)
                if viewer.isConnecting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                    Button("Cancel connection") {
                        automaticConnection = false
                        viewer.disconnect()
                    }
                } else if !viewer.savedMacs.isEmpty && !showPairing {
                    Button("Reconnect to \(preferredProfile?.name ?? "Mac")") {
                        automaticConnection = true
                        if let profile = preferredProfile {
                            viewer.connect(profile: profile, startMicrophoneOnConnect: microphoneOnConnect,
                                           startMacAudioOnConnect: macAudioOnConnect)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    Button("Pair another Mac") {
                        automaticConnection = false
                        showPairing = true
                    }
                    .frame(maxWidth: .infinity)
                }
                if viewer.savedMacs.isEmpty || showPairing {
                    pairingForm
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair a new Mac").font(.headline)
            Text("Choose Pair a New Device in the Mac menu bar once, then enter its address and code here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Profile name", text: $profileName)
                .textFieldStyle(.roundedBorder)
            TextField("Mac Tailscale address (100.x.x.x)", text: $macAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
            SecureField("Pairing code shown on Mac", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button("Pair and connect") {
                viewer.pair(host: macAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                            code: code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            name: profileName,
                            startMicrophoneOnConnect: microphoneOnConnect,
                            startMacAudioOnConnect: macAudioOnConnect)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewer.isConnecting || macAddress.isEmpty || code.isEmpty)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button {
                keyboardActive = true
                keyboardFocusRequest += 1
            } label: {
                Image(systemName: "keyboard")
            }
            .accessibilityLabel("Keyboard")
            .accessibilityIdentifier("tailview.keyboardButton")
            .disabled(!viewer.isControlAllowed)
            Button { sendPointer(.leftClick) } label: {
                Image(systemName: "cursorarrow.click")
            }
            .accessibilityLabel("Left click")
            .disabled(!viewer.isControlAllowed || isDraggingRemote)
            Button { sendPointer(.rightClick) } label: {
                Image(systemName: "cursorarrow.click.2")
            }
            .accessibilityLabel("Right click")
            .disabled(!viewer.isControlAllowed || isDraggingRemote)
            Button {
                isDraggingRemote.toggle()
                sendPointer(isDraggingRemote ? .leftDown : .leftUp)
            } label: {
                Image(systemName: isDraggingRemote ? "hand.raised.fill" : "hand.draw")
            }
            .accessibilityLabel(isDraggingRemote ? "Release drag" : "Start drag")
            .disabled(!viewer.isControlAllowed)
            Spacer(minLength: 0)
            Menu {
                Button("Scroll up") { viewer.sendControl(ControlCommand(kind: .scroll, amount: -3)) }
                Button("Scroll down") { viewer.sendControl(ControlCommand(kind: .scroll, amount: 3)) }
                Divider()
                Button("Return") { sendKey(.returnKey) }
                Button("Tab") { sendKey(.tab) }
                Button("Delete") { sendKey(.delete) }
                Button("Escape") { sendKey(.escape) }
                Button("Left arrow") { sendKey(.left) }
                Button("Right arrow") { sendKey(.right) }
                Button("Up arrow") { sendKey(.up) }
                Button("Down arrow") { sendKey(.down) }
                Divider()
                Button("Reset zoom") { screenZoom = 1; screenOffset = .zero }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More controls")
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Text(viewer.status)
                    if viewer.isConnected {
                        Button("Disconnect") {
                            automaticConnection = false
                            viewer.disconnect()
                            showSettings = false
                        }
                    }
                    ForEach(viewer.savedMacs) { profile in
                        HStack {
                            Button(profile.name) {
                                preferredMacID = profile.id.uuidString
                                automaticConnection = true
                                viewer.disconnect()
                                viewer.connect(profile: profile, startMicrophoneOnConnect: microphoneOnConnect,
                                               startMacAudioOnConnect: macAudioOnConnect)
                                showSettings = false
                            }
                            Spacer()
                            Button("Forget", role: .destructive) { viewer.forget(profile: profile) }
                        }
                    }
                    Button("Pair another Mac") {
                        automaticConnection = false
                        viewer.disconnect()
                        showPairing = true
                        showSettings = false
                    }
                }
                Section("Microphone") {
                    Toggle("Connect microphone automatically", isOn: $microphoneOnConnect)
                    Text(viewer.microphoneStatus)
                    Text(viewer.inputLevelStatus)
                }
                Section("Mac sound") {
                    Toggle("Hear Mac sound automatically", isOn: $macAudioOnConnect)
                    Text(viewer.macAudioStatus)
                }
                Section("Screen") {
                    Toggle("Align screen to top", isOn: $alignScreenToTop)
                    Text("Pinch to zoom. Drag one finger to move the Mac pointer, or two fingers to pan the screen.")
                }
                #if DEBUG
                Section("Microphone input test") {
                    Button("Record-only microphone check") { viewer.runRecorderTest(isolated: true) }
                    Text(viewer.debugStatus)
                }
                Section("Speaker output test") {
                    Button("Play speaker test tone") { viewer.runSpeakerTest() }
                        .disabled(viewer.isMicrophoneOn || viewer.isMacAudioOn)
                    Text(viewer.speakerTestStatus)
                }
                Section("Transport test") {
                    Button("Send generated audio") { viewer.sendSyntheticAudioTest() }
                        .disabled(!viewer.isConnected)
                }
                #endif
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    private var preferredProfile: SavedMac? {
        viewer.savedMacs.first { $0.id.uuidString == preferredMacID } ?? viewer.savedMacs.first
    }

    private func connectPreferredIfNeeded() {
        guard scenePhase == .active, automaticConnection, !showPairing, !diagnosticLaunch,
              !viewer.isConnected, !viewer.isConnecting, !viewer.savedCredentialRejected,
              let profile = preferredProfile else { return }
        viewer.connect(profile: profile, startMicrophoneOnConnect: microphoneOnConnect,
                       startMacAudioOnConnect: macAudioOnConnect)
    }

    private func sendPointer(_ kind: ControlCommand.Kind) {
        viewer.sendControl(ControlCommand(kind: kind, x: Double(pointer.x), y: Double(pointer.y)))
    }

    private func sendKey(_ key: ControlCommand.Key) {
        viewer.sendControl(ControlCommand(kind: .key, key: key))
    }
}
