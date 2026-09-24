import SwiftUI

struct ViewerView: View {
    @AppStorage("macAddress") private var macAddress = ""
    @AppStorage("alignScreenToTop") private var alignScreenToTop = false
    @State private var code = ""
    @State private var profileName = "My Mac"
    @State private var showPairing = false
    @State private var didRunDebugLaunch = false
    @State private var interactionMode: ViewerInteractionMode = .view
    @State private var pointer = CGPoint(x: 0.5, y: 0.5)
    @State private var isDraggingRemote = false
    @State private var remoteText = ""
    @State private var screenZoom: CGFloat = 1
    @State private var screenOffset = CGSize.zero
    @FocusState private var remoteTextFocused: Bool
    @StateObject private var viewer = ViewerModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image = viewer.image {
                    RemoteScreenView(image: image, alignTop: alignScreenToTop,
                                     mode: interactionMode, isDraggingRemote: isDraggingRemote,
                                     pointer: $pointer, zoom: $screenZoom, offset: $screenOffset,
                                     onCommand: viewer.sendControl)
                } else {
                    ContentUnavailableView("No screen yet", systemImage: "display",
                                           description: Text(viewer.status))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 10) {
                    if !viewer.isConnected {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if !viewer.savedMacs.isEmpty {
                                    Text("Saved Macs").font(.headline)
                                    ForEach(viewer.savedMacs) { profile in
                                        HStack {
                                            Button {
                                                viewer.connect(profile: profile)
                                            } label: {
                                                Label {
                                                    VStack(alignment: .leading) {
                                                        Text(profile.name)
                                                        Text(profile.address).font(.caption).foregroundStyle(.secondary)
                                                    }
                                                } icon: { Image(systemName: "desktopcomputer") }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(viewer.isConnecting)
                                            Menu {
                                                Button("Forget on this device", role: .destructive) {
                                                    viewer.forget(profile: profile)
                                                }
                                            } label: { Image(systemName: "ellipsis.circle") }
                                        }
                                    }
                                    Button(showPairing ? "Hide pairing" : "Pair another Mac") {
                                        showPairing.toggle()
                                    }
                                    .disabled(viewer.isConnecting)
                                }
                                if viewer.savedMacs.isEmpty || showPairing {
                                    Text("Pair once").font(.headline)
                                    Text("Start sharing and choose Pair a new device on the Mac.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextField("Profile name", text: $profileName)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Mac Tailscale address (100.x.x.x)", text: $macAddress)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .keyboardType(.numbersAndPunctuation)
                                        .textFieldStyle(.roundedBorder)
                                    SecureField("Session code shown on Mac", text: $code)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .textFieldStyle(.roundedBorder)
                                    HStack {
                                        Button("Pair and connect") {
                                            viewer.pair(host: macAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        code: code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                                                        name: profileName)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        Button("Connect once") {
                                            viewer.connect(host: macAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           code: code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                                        }
                                    }
                                    .disabled(viewer.isConnecting || macAddress.isEmpty || code.isEmpty)
                                }
                                if viewer.isConnecting {
                                    Button("Cancel connection") { viewer.disconnect() }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 330)
                    } else {
                        if viewer.isControlAllowed {
                            Picker("Screen interaction", selection: $interactionMode) {
                                ForEach(ViewerInteractionMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("tailview.interactionMode")
                        } else {
                            Text(viewer.isPairedSession
                                 ? "View only · press Allow Control in TailView Mac to use mouse and keyboard"
                                 : "View only · pair this device to enable Mac control")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Zoom out") { screenZoom = max(1, screenZoom / 1.5); screenOffset = .zero }
                                .disabled(screenZoom <= 1)
                            Button("Zoom in") { screenZoom = min(4, screenZoom * 1.5); screenOffset = .zero }
                                .disabled(screenZoom >= 4)
                            Button("Reset") { screenZoom = 1; screenOffset = .zero }
                                .disabled(screenZoom == 1)
                            Spacer()
                            Text(String(format: "%.1f×", Double(screenZoom)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.bordered)
                        if interactionMode == .control && viewer.isControlAllowed {
                            ScrollView(.horizontal) {
                                HStack {
                                    Button("Left click") { sendPointer(.leftClick) }
                                        .disabled(isDraggingRemote)
                                    Button("Right click") { sendPointer(.rightClick) }
                                        .disabled(isDraggingRemote)
                                    Button(isDraggingRemote ? "Release drag" : "Start drag") {
                                        isDraggingRemote.toggle()
                                        sendPointer(isDraggingRemote ? .leftDown : .leftUp)
                                    }
                                    Button("Scroll ↑") { viewer.sendControl(ControlCommand(kind: .scroll, amount: -3)) }
                                    Button("Scroll ↓") { viewer.sendControl(ControlCommand(kind: .scroll, amount: 3)) }
                                    Menu("Keys") {
                                        Button("Return") { sendKey(.returnKey) }
                                        Button("Tab") { sendKey(.tab) }
                                        Button("Delete") { sendKey(.delete) }
                                        Button("Escape") { sendKey(.escape) }
                                        Button("←") { sendKey(.left) }
                                        Button("→") { sendKey(.right) }
                                        Button("↑") { sendKey(.up) }
                                        Button("↓") { sendKey(.down) }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .scrollIndicators(.hidden)
                            HStack {
                                Button {
                                    remoteTextFocused = true
                                } label: {
                                    Label("Keyboard", systemImage: "keyboard")
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("tailview.keyboardButton")
                                TextField("Type text on Mac", text: $remoteText)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.send)
                                    .focused($remoteTextFocused)
                                    .onSubmit(sendRemoteText)
                                    .accessibilityIdentifier("tailview.remoteText")
                                Button("Send text", action: sendRemoteText)
                                    .disabled(remoteText.isEmpty)
                            }
                            Text("Tap to click, or tap Keyboard to type into the focused Mac app. Drag one finger to move the pointer; use two fingers to pan and pinch to zoom.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(viewer.isMicrophoneOn ? "Stop microphone" : "Start microphone") {
                                viewer.isMicrophoneOn ? viewer.stopMicrophone() : viewer.startMicrophone()
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                            Button("Disconnect", role: .destructive) { viewer.disconnect() }
                        }
                        Text(viewer.microphoneStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewer.inputLevelStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #if DEBUG
                        Text(viewer.debugStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #endif
                    }
                    Text(viewer.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("TailView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        Form {
                            Section("Screen") {
                                Toggle("Align screen to top", isOn: $alignScreenToTop)
                                Text("Pinch to zoom. Pan with one finger in View mode or two fingers in Control mode.")
                            }
                            #if DEBUG
                            Section("Microphone input") {
                                Text("Stops streaming and records four seconds with the same record-only audio session used for live microphone capture. The temporary audio is deleted after measuring it.")
                                Button("Record-only microphone check") { viewer.runRecorderTest(isolated: true) }
                                Text(viewer.debugStatus)
                                Text(viewer.inputLevelStatus)
                                Text(viewer.microphoneStatus)
                            }
                            Section("Speaker output") {
                                Text("Plays a tone through this device's speaker. This does not test microphone capture.")
                                Button("Play speaker test tone") { viewer.runSpeakerTest() }
                                    .disabled(viewer.isMicrophoneOn)
                                Text(viewer.speakerTestStatus)
                            }
                            Section("Transport test") {
                                Text("Sends generated PCM to the Mac without using the microphone. This verifies the connection and receiver only.")
                                Button("Send generated audio") { viewer.sendSyntheticAudioTest() }
                                    .disabled(!viewer.isConnected)
                            }
                            #endif
                        }
                        .navigationTitle("Settings")
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
        .onChange(of: viewer.isConnected) { _, connected in
            if connected { showPairing = false; code = "" }
            else {
                interactionMode = .view
                isDraggingRemote = false
                remoteTextFocused = false
                screenZoom = 1
                screenOffset = .zero
            }
        }
        .onChange(of: viewer.isControlAllowed) { _, allowed in
            if !allowed { interactionMode = .view; isDraggingRemote = false; remoteTextFocused = false }
        }
        .onChange(of: interactionMode) { _, mode in
            if mode == .view, isDraggingRemote {
                sendPointer(.leftUp)
                isDraggingRemote = false
            }
        }
        .task {
            #if DEBUG
            guard !didRunDebugLaunch else { return }
            didRunDebugLaunch = true
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--tailview-test-isolated-recorder") {
                viewer.runRecorderTest(isolated: true)
                return
            }
            if arguments.contains("--tailview-test-saved-microphone"),
               let profile = viewer.savedMacs.first {
                viewer.connect(profile: profile, startMicrophoneOnConnect: true)
                return
            }
            if let index = arguments.firstIndex(of: "--tailview-test-connect"),
               arguments.count > index + 2 {
                macAddress = arguments[index + 1]
                code = arguments[index + 2]
                viewer.connect(host: macAddress, code: code, startMicrophoneOnConnect: true,
                               runRecorderTestOnConnect: arguments.contains("--tailview-test-recorder"),
                               runSyntheticTestOnConnect: arguments.contains("--tailview-test-synthetic"))
            }
            #endif
        }
    }

    private func sendPointer(_ kind: ControlCommand.Kind) {
        viewer.sendControl(ControlCommand(kind: kind, x: Double(pointer.x), y: Double(pointer.y)))
    }

    private func sendKey(_ key: ControlCommand.Key) {
        viewer.sendControl(ControlCommand(kind: .key, key: key))
    }

    private func sendRemoteText() {
        guard !remoteText.isEmpty else { return }
        viewer.sendText(remoteText)
        remoteText = ""
    }
}
