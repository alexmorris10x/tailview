import Combine
import AVKit
import SwiftUI

struct ViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("macAddress") private var macAddress = ""
    @AppStorage("preferredMacID") private var preferredMacID = ""
    @AppStorage("alignScreenToTop") private var alignScreenToTop = false
    @AppStorage("reverseScrollDirection") private var reverseScrollDirection = false
    @AppStorage("microphoneOnConnect") private var microphoneOnConnect = true
    @AppStorage("macAudioOnConnect") private var macAudioOnConnect = true
    @AppStorage("useTailViewTouchKeyboard") private var useTailViewTouchKeyboard = false
    @State private var code = ""
    @State private var profileName = "My Mac"
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var automaticConnection = true
    @State private var didRunDebugLaunch = false
    @State private var diagnosticLaunch = false
    @State private var pointer = CGPoint(x: 0.5, y: 0.5)
    @State private var isDraggingRemote = false
    @State private var isTouchDraggingRemote = false
    @State private var isPanningView = false
    @State private var keyboardActive = false
    @State private var keyboardUserHidden = false
    @State private var keyboardFocusRequest = 0
    @State private var keyboardOpenRequest = 0
    @State private var nativeKeyboardVisible = false
    @State private var fallbackKeyboardVisible = false
    @State private var microphoneSessionEnabled = true
    @State private var macAudioSessionEnabled = true
    @State private var screenZoom: CGFloat = 1
    @State private var screenOffset = CGSize.zero
    @State private var modifierSelection = ModifierSelection()
    @StateObject private var viewer = ViewerModel()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomLeading) {
                if let image = viewer.image {
                    RemoteScreenView(image: image, alignTop: alignScreenToTop,
                                     controlAllowed: viewer.isControlAllowed,
                                     isDraggingRemote: isDraggingRemote,
                                     panView: isPanningView,
                                     reverseScrollDirection: reverseScrollDirection,
                                     isTouchDraggingRemote: $isTouchDraggingRemote,
                                     pointer: $pointer, zoom: $screenZoom, offset: $screenOffset,
                                     onCommand: sendControl)
                } else {
                    connectionView
                }
                RemoteKeyboardInput(
                    isActive: keyboardActive && viewer.isControlAllowed && !showSettings,
                    useTailViewKeyboard: useTailViewTouchKeyboard,
                    focusRequest: keyboardFocusRequest,
                    onText: sendText,
                    onDelete: { sendKey(.delete) },
                    onReturn: { sendKey(.returnKey) },
                    onSoftwareKeyboardVisibilityChange: { visible in
                        nativeKeyboardVisible = visible
                        if visible { fallbackKeyboardVisible = false }
                    }
                )
                .frame(width: 1, height: 1)
            }
            .background(.black)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewer.isConnected {
                    VStack(spacing: 0) {
                        if fallbackKeyboardVisible && viewer.isControlAllowed {
                            RemoteFallbackKeyboard(
                                onText: sendText,
                                onDelete: { sendKey(.delete) },
                                onReturn: { sendKey(.returnKey) },
                                onDismiss: hideKeyboard
                            )
                        }
                        controlBar
                    }
                }
            }
            .navigationTitle("TailView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        releaseHeldMouse()
                        modifierSelection.reset()
                        closeKeyboard()
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("tailview.settings")
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                if viewer.isControlAllowed && !keyboardUserHidden { showKeyboard() }
            }) {
                settingsView
            }
        }
        .onChange(of: viewer.isConnected) { _, connected in
            if connected {
                microphoneSessionEnabled = microphoneOnConnect
                macAudioSessionEnabled = macAudioOnConnect
                showPairing = false
                automaticConnection = true
                code = ""
                if preferredMacID.isEmpty, let profile = viewer.savedMacs.last {
                    preferredMacID = profile.id.uuidString
                }
            } else {
                modifierSelection.reset()
                closeKeyboard()
                keyboardUserHidden = false
                isDraggingRemote = false
                isTouchDraggingRemote = false
                isPanningView = false
                screenZoom = 1
                screenOffset = .zero
            }
        }
        .onChange(of: viewer.isControlAllowed) { _, allowed in
            if allowed {
                if !showSettings && !keyboardUserHidden { showKeyboard() }
            } else {
                closeKeyboard()
                modifierSelection.reset()
                isDraggingRemote = false
                isTouchDraggingRemote = false
                isPanningView = false
            }
        }
        .onChange(of: screenZoom) { _, value in
            if value <= 1.01 { isPanningView = false }
        }
        .onChange(of: microphoneOnConnect) { _, enabled in
            guard viewer.isConnected else { return }
            microphoneSessionEnabled = enabled
            if enabled { viewer.startMicrophone() }
            else { viewer.stopMicrophone() }
        }
        .onChange(of: macAudioOnConnect) { _, enabled in
            guard viewer.isConnected else { return }
            macAudioSessionEnabled = enabled
            if enabled { viewer.startMacAudio() }
            else { viewer.stopMacAudio() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                connectPreferredIfNeeded()
                viewer.resumeAudioAfterForeground()
                if viewer.isControlAllowed && !showSettings && !keyboardUserHidden {
                    showKeyboard()
                }
            }
            else {
                closeKeyboard()
                releaseHeldMouse()
                modifierSelection.reset()
            }
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
        HStack(spacing: 6) {
            Button {
                toggleKeyboard()
            } label: {
                Image(systemName: "keyboard")
            }
            .accessibilityLabel(nativeKeyboardVisible || fallbackKeyboardVisible
                                ? "Hide keyboard" : "Show keyboard")
            .accessibilityIdentifier("tailview.keyboardButton")
            .disabled(!viewer.isControlAllowed)
            ForEach(ControlCommand.Modifier.allCases, id: \.self) { modifier in
                modifierButton(modifier)
            }
            Button {
                microphoneSessionEnabled.toggle()
                if microphoneSessionEnabled { viewer.startMicrophone() }
                else { viewer.stopMicrophone() }
            } label: {
                Image(systemName: microphoneSessionEnabled ? "mic.fill" : "mic.slash.fill")
                    .frame(minWidth: 34, minHeight: 32)
            }
            .tint(microphoneSessionEnabled ? .primary : .red)
            .accessibilityLabel(microphoneSessionEnabled ? "Mute microphone" : "Unmute microphone")
            .accessibilityValue(microphoneSessionEnabled ? "On" : "Muted")
            .accessibilityHint("Controls voice sent to the Mac when this device owns audio")
            .accessibilityIdentifier("tailview.microphoneMuteButton")
            Button {
                macAudioSessionEnabled.toggle()
                if macAudioSessionEnabled { viewer.startMacAudio() }
                else { viewer.stopMacAudio() }
            } label: {
                Image(systemName: macAudioSessionEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(minWidth: 34, minHeight: 32)
            }
            .tint(macAudioSessionEnabled ? .primary : .red)
            .accessibilityLabel(macAudioSessionEnabled ? "Mute Mac sound" : "Unmute Mac sound")
            .accessibilityValue(macAudioSessionEnabled ? "On" : "Muted")
            .accessibilityHint("Controls Mac sound played on this device when it owns audio")
            .accessibilityIdentifier("tailview.speakerMuteButton")
            if horizontalSizeClass != .compact {
                pointerButtons
                if screenZoom > 1.01 {
                    Button { isPanningView.toggle() } label: {
                        Image(systemName: isPanningView ? "hand.point.up.left.fill" : "hand.point.up.left")
                    }
                    .accessibilityLabel(isPanningView ? "Stop panning view" : "Pan view")
                    .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if horizontalSizeClass == .compact {
                    Button("Left click", systemImage: "cursorarrow.click") { sendPointer(.leftClick) }
                        .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
                    Button("Right click", systemImage: "cursorarrow.click.2") { sendPointer(.rightClick) }
                        .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
                    Button(isDraggingRemote ? "Release drag" : "Start drag",
                           systemImage: isDraggingRemote ? "hand.raised.fill" : "hand.draw") {
                        toggleDrag()
                    }
                    .disabled(!viewer.isControlAllowed || isTouchDraggingRemote)
                    if screenZoom > 1.01 {
                        Button(isPanningView ? "Stop panning view" : "Pan view") { isPanningView.toggle() }
                            .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
                    }
                    Divider()
                }
                Button("Scroll up") { sendControl(ControlCommand(kind: .scroll, amount: -3)) }
                Button("Scroll down") { sendControl(ControlCommand(kind: .scroll, amount: 3)) }
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

    private var pointerButtons: some View {
        Group {
            Button { sendPointer(.leftClick) } label: {
                Image(systemName: "cursorarrow.click")
            }
            .accessibilityLabel("Left click")
            .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
            Button { sendPointer(.rightClick) } label: {
                Image(systemName: "cursorarrow.click.2")
            }
            .accessibilityLabel("Right click")
            .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
            Button { toggleDrag() } label: {
                Image(systemName: isDraggingRemote ? "hand.raised.fill" : "hand.draw")
            }
            .accessibilityLabel(isDraggingRemote ? "Release drag" : "Start drag")
            .disabled(!viewer.isControlAllowed || isTouchDraggingRemote)
        }
    }

    private func modifierButton(_ modifier: ControlCommand.Modifier) -> some View {
        let mode = modifierSelection.mode(for: modifier)
        return Button {
            modifierSelection.tap(modifier)
        } label: {
            HStack(spacing: 2) {
                Text(modifier.symbol).font(.system(size: 18, weight: .semibold))
                if mode == .held {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                }
            }
            .frame(minWidth: 34, minHeight: 32)
            .foregroundStyle(mode == .off ? Color.primary : Color.white)
            .background(mode == .held ? Color.orange :
                        mode == .next ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(modifier.title) modifier")
        .accessibilityValue(mode == .held ? "Held" : mode == .next ? "Next action" : "Off")
        .accessibilityHint("Tap once for the next action. Double tap to hold. Tap a held modifier to release it.")
        .accessibilityAction(named: "Hold \(modifier.title)") {
            modifierSelection.hold(modifier)
        }
        .accessibilityIdentifier("tailview.modifier.\(modifier.rawValue)")
        .disabled(!viewer.isControlAllowed)
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
                Section("Audio device") {
                    if viewer.canTakeAudio {
                        Button("Use audio on this device") { viewer.takeAudio() }
                        Text("Moves both Mac sound and microphone input here. The other device keeps its screen and controls.")
                    } else if viewer.isConnected {
                        Text("This device has the audio route.")
                    }
                    Text("Use Mic and Speaker in the floating bar to mute either direction for this connection.")
                }
                Section("Microphone") {
                    Toggle("Connect microphone automatically", isOn: $microphoneOnConnect)
                    Text(viewer.microphoneStatus)
                    Text(viewer.inputLevelStatus)
                }
                Section("Mac sound") {
                    Toggle("Hear Mac sound automatically", isOn: $macAudioOnConnect)
                    Text(viewer.macAudioStatus)
                    Text(viewer.macAudioOutputStatus)
                    HStack {
                        Text("Choose audio output")
                        Spacer()
                        AudioOutputPicker()
                            .frame(width: 44, height: 44)
                    }
                }
                Section("Screen") {
                    Toggle("Align screen to top", isOn: $alignScreenToTop)
                    Toggle("Reverse two-finger scroll direction", isOn: $reverseScrollDirection)
                    Text("Tap to click, slide one finger to move the Mac pointer, or press and hold then move to drag. Swipe two fingers to scroll the Mac. Pinch to zoom; while zoomed, use Pan view in the control bar to move the screen with two fingers.")
                }
                Section("Keyboard") {
                    Toggle("Use TailView touch keyboard", isOn: $useTailViewTouchKeyboard)
                    Text("The iOS keyboard is used by default. TailView shows touch keys if iPadOS hides it. Turn this on to use TailView's keys every time.")
                    Text("Tap Control, Option, or Command once for the next key or click. Tap twice quickly to hold it for multiple actions; tap a held modifier again to release it. Blue means next action and orange means held.")
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
        #if DEBUG
        // A recorder-only launch must not let the periodic reconnect timer
        // reactivate playback and interrupt the four-second microphone test.
        guard !ProcessInfo.processInfo.arguments.contains("--tailview-test-isolated-recorder") else { return }
        #endif
        guard scenePhase == .active, automaticConnection, !showPairing, !diagnosticLaunch,
              !viewer.isConnected, !viewer.isConnecting, !viewer.savedCredentialRejected,
              let profile = preferredProfile else { return }
        viewer.connect(profile: profile, startMicrophoneOnConnect: microphoneOnConnect,
                       startMacAudioOnConnect: macAudioOnConnect)
    }

    private func sendPointer(_ kind: ControlCommand.Kind) {
        sendControl(ControlCommand(kind: kind, x: Double(pointer.x), y: Double(pointer.y)))
    }

    private func toggleDrag() {
        isDraggingRemote.toggle()
        sendPointer(isDraggingRemote ? .leftDown : .leftUp)
    }

    private func releaseHeldMouse() {
        if isDraggingRemote || isTouchDraggingRemote { sendPointer(.leftUp) }
        isDraggingRemote = false
        isTouchDraggingRemote = false
    }

    private func sendKey(_ key: ControlCommand.Key) {
        sendControl(ControlCommand(kind: .key, key: key))
    }

    private func showKeyboard() {
        keyboardUserHidden = false
        keyboardOpenRequest += 1
        if useTailViewTouchKeyboard {
            keyboardActive = true
            keyboardFocusRequest += 1
            nativeKeyboardVisible = false
            fallbackKeyboardVisible = true
            return
        }
        keyboardActive = true
        keyboardFocusRequest += 1
        let request = keyboardOpenRequest
        // An attached keyboard can give UIKit a first responder and a narrow
        // accessory strip without showing the software keys. Offer our own
        // remote keys if no full keyboard arrives after UIKit's transition.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard request == keyboardOpenRequest, viewer.isControlAllowed,
                  !showSettings, !nativeKeyboardVisible else { return }
            fallbackKeyboardVisible = true
        }
    }

    private func closeKeyboard() {
        keyboardOpenRequest += 1
        fallbackKeyboardVisible = false
        nativeKeyboardVisible = false
        keyboardActive = false
    }

    private func toggleKeyboard() {
        if nativeKeyboardVisible || fallbackKeyboardVisible {
            hideKeyboard()
        } else {
            showKeyboard()
        }
    }

    private func hideKeyboard() {
        keyboardUserHidden = true
        closeKeyboard()
    }

    private func sendText(_ text: String) {
        guard viewer.isControlAllowed else { return }
        viewer.sendText(text, modifiers: modifierSelection.active)
        modifierSelection.consumeNext()
    }

    private func sendControl(_ original: ControlCommand) {
        guard viewer.isControlAllowed else { return }
        var command = original
        command.modifiers = modifierSelection.active
        viewer.sendControl(command)
        switch command.kind {
        case .leftClick, .rightClick, .leftUp, .scroll, .text, .key:
            modifierSelection.consumeNext()
        case .move, .leftDown, .leftDrag:
            break
        }
    }
}

private extension ControlCommand.Modifier {
    var title: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        }
    }
}

private struct AudioOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .systemBlue
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
