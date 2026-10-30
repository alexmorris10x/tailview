import Combine
import AVKit
import SwiftUI

struct ViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("macAddress") private var macAddress = ""
    @AppStorage("preferredMacID") private var preferredMacID = ""
    @AppStorage("alignScreenToTop") private var alignScreenToTop = false
    @AppStorage("reverseScrollDirection") private var reverseScrollDirection = false
    @AppStorage("microphoneOnConnect") private var microphoneOnConnect = false
    @AppStorage("remoteControlConsent") private var remoteControlConsent = false
    @AppStorage("macAudioOnConnect") private var macAudioOnConnect = true
    @AppStorage("lockScreenControls") private var lockScreenControls = true
    @State private var code = ""
    @State private var profileName = "My Mac"
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var showPurchase = false
    @State private var showControlHelp = false
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
    @State private var nativeKeyboardVisible = false
    @State private var microphoneSessionEnabled = false
    @State private var macAudioSessionEnabled = true
    @State private var screenZoom: CGFloat = 1
    @State private var screenOffset = CGSize.zero
    @State private var modifierSelection = ModifierSelection()
    @State private var notice: String?
    @State private var noticeGeneration = 0
    @StateObject private var viewer = ViewerModel()
    @StateObject private var access = PurchaseAccess.shared

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
                    isActive: keyboardActive && viewer.isControlAllowed && !showSettings && !showPurchase,
                    focusRequest: keyboardFocusRequest,
                    onText: sendText,
                    onDelete: { sendKey(.delete) },
                    onReturn: { sendKey(.returnKey) },
                    onPaste: { pasteClipboard(fromKeyboard: true) },
                    onSoftwareKeyboardVisibilityChange: { nativeKeyboardVisible = $0 }
                )
                .frame(width: 1, height: 1)
            }
            .background(.black)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewer.isConnected {
                    controlBar
                }
            }
            .navigationTitle("TailView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openSettings) {
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
            .sheet(isPresented: $showPurchase, onDismiss: {
                if viewer.isControlAllowed && !keyboardUserHidden { showKeyboard() }
            }) {
                PurchaseView(access: access)
            }
            .alert(remoteControlConsent ? "Enable control on your Mac" : "Enable keyboard and pointer control?",
                   isPresented: $showControlHelp) {
                if !remoteControlConsent {
                    Button("Enable Control") {
                        keyboardUserHidden = false
                        remoteControlConsent = true
                        if viewer.isControlAllowed { showKeyboard() }
                    }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(remoteControlConsent
                     ? "On your Mac, open TailView, enable remote control, and allow Accessibility in System Settings. The keyboard will open when control is available."
                     : "Allow this device to send typing and pointer actions to your paired Mac. Your Mac must also enable remote control and allow Accessibility. You can turn this off in Settings.")
            }
        }
        .onChange(of: access.state) { _, _ in
            updateAccess()
            if access.streamAllowed {
                showPurchase = false
                connectPreferredIfNeeded()
            }
        }
        .onChange(of: remoteControlConsent) { _, enabled in
            viewer.setRemoteControlConsent(enabled)
        }
        .onChange(of: viewer.lastPairedMacID) { _, id in
            guard let id else { return }
            preferredMacID = id.uuidString
            showPairing = false
            automaticConnection = true
            code = ""
        }
        .onOpenURL { url in
            guard let route = WidgetRoute(url: url) else { return }
            if route == .settings {
                openSettings()
                return
            }
            showSettings = false
            showPairing = false
            automaticConnection = true
            if route == .keyboard { keyboardUserHidden = false }
            viewer.reloadSavedMacs()
            connectPreferredIfNeeded()
            if route == .keyboard && viewer.isControlAllowed { showKeyboard() }
        }
        .onChange(of: viewer.isConnected) { _, connected in
            if connected {
                microphoneSessionEnabled = viewer.microphoneWanted
                macAudioSessionEnabled = viewer.macAudioWanted
                showPairing = false
                automaticConnection = true
                code = ""
                // Reconnect targets the Mac this device last signed in to, so a
                // fresh pairing replaces an older, possibly revoked, profile.
                if let id = viewer.connectedMacID { preferredMacID = id.uuidString }
            } else {
                releaseFunctionKey()
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
                if !showSettings && !showPurchase && !keyboardUserHidden { showKeyboard() }
            } else {
                closeKeyboard()
                releaseFunctionKey()
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
        // Lock-screen controls can change either direction.
        .onChange(of: viewer.microphoneEnabled) { _, enabled in
            if viewer.isConnected { microphoneSessionEnabled = enabled }
        }
        .onChange(of: viewer.macAudioEnabled) { _, enabled in
            if viewer.isConnected { macAudioSessionEnabled = enabled }
        }
        .onChange(of: lockScreenControls) { _, _ in viewer.refreshLiveControls() }
        .onChange(of: macAudioOnConnect) { _, enabled in
            guard viewer.isConnected else { return }
            macAudioSessionEnabled = enabled
            if enabled { viewer.startMacAudio() }
            else { viewer.stopMacAudio() }
        }
        .onChange(of: scenePhase) { _, phase in
            DiagnosticLog.note("Scene phase: \(phase)")
            access.setForeground(phase == .active)
            updateAccess()
            viewer.setVideoActive(phase == .active)
            if phase == .active {
                viewer.reloadSavedMacs()
                connectPreferredIfNeeded()
                viewer.resumeAudioAfterForeground()
                if viewer.isControlAllowed && !showSettings && !showPurchase && !keyboardUserHidden {
                    showKeyboard()
                }
            }
            else {
                closeKeyboard()
                releaseHeldMouse()
                releaseFunctionKey()
                modifierSelection.reset()
            }
        }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            updateAccess()
            if !viewer.savedMacsLoaded { viewer.reloadSavedMacs() }
            connectPreferredIfNeeded()
        }
        .task {
            viewer.setRemoteControlConsent(remoteControlConsent)
            access.setForeground(scenePhase == .active)
            updateAccess()
            await access.refresh()
            updateAccess()
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

    private func updateAccess() {
        viewer.setStreamingAccess(allowed: access.streamAllowed, expiresAt: access.expirationDate)
    }

    private func openSettings() {
        releaseHeldMouse()
        releaseFunctionKey()
        modifierSelection.reset()
        closeKeyboard()
        showSettings = true
    }

    private var connectionView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ContentUnavailableView(viewer.savedMacs.isEmpty ? "Connect to your Mac" : "Your Mac is ready",
                                       systemImage: "display",
                                       description: Text(viewer.status))
                    .frame(maxWidth: .infinity)
                if viewer.savedMacs.isEmpty {
                    setupSteps
                }
                if !viewer.savedMacs.isEmpty && !access.streamAllowed {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(access.statusTitle).font(.headline)
                        Text(access.statusDetail).font(.subheadline).foregroundStyle(.secondary)
                        Button("Trial and lifetime access") { showPurchase = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("tailview.access")
                        Text("Your Mac stays paired. Starting a trial never charges you automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                }
                if viewer.isConnecting || viewer.isReconnecting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                    Button("Cancel connection") {
                        automaticConnection = false
                        viewer.disconnect()
                    }
                } else if !viewer.savedMacsLoaded && !showPairing {
                    Button("Try again") { viewer.reloadSavedMacs() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    Button("Pair a new Mac") { showPairing = true }
                        .frame(maxWidth: .infinity)
                } else if !viewer.savedMacs.isEmpty && !showPairing {
                    Button("Connect to \(preferredProfile?.name ?? "Mac")") {
                        guard access.streamAllowed else { showPurchase = true; return }
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
                if (viewer.savedMacsLoaded && viewer.savedMacs.isEmpty) || showPairing {
                    pairingForm
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("1. Connect both devices to Tailscale", systemImage: "network")
                .font(.headline)
            Text("Sign in to the same Tailscale network on this device and your Mac. TailView only connects through that private network.")
                .font(.subheadline).foregroundStyle(.secondary)
            Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
            Label("2. Set up the free Mac companion", systemImage: "desktopcomputer")
                .font(.headline)
            Text("On your Mac, open TailView, enable sharing, and allow Screen Recording. Enable remote control and microphone routing only if you want them.")
                .font(.subheadline).foregroundStyle(.secondary)
            Link("Mac download and setup", destination: URL(string: "https://alexmorris10x.github.io/tailview/setup.html")!)
            Label("3. Pair before you start your trial", systemImage: "link")
                .font(.headline)
            Text("Choose Pair a New Device on the Mac, then enter its Tailscale address and temporary code below. Your seven days start only when you choose Start Trial.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair a new Mac").font(.headline)
            Text("The Mac’s pairing code expires after five minutes and can be used once.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Profile name", text: $profileName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tailview.profile-name")
            TextField("Mac Tailscale address (100.x.x.x)", text: $macAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tailview.mac-address")
            SecureField("Pairing code shown on Mac", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tailview.pairing-code")
            Toggle("Enable keyboard and pointer control", isOn: $remoteControlConsent)
            Toggle("Send this device’s microphone on connect", isOn: $microphoneOnConnect)
            Text("Microphone audio is sent to your Mac only when enabled and permitted. The Mac must separately allow remote control and microphone routing. You can change these choices in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            Button(access.streamAllowed ? "Pair and connect" : "Pair Mac") {
                viewer.pair(host: macAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                            code: code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            name: profileName,
                            startMicrophoneOnConnect: microphoneOnConnect,
                            startMacAudioOnConnect: macAudioOnConnect)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("tailview.pair")
            .disabled(viewer.isConnecting || macAddress.isEmpty || code.isEmpty)
            if showPairing && !viewer.savedMacs.isEmpty && !viewer.isConnecting {
                Button("Back to saved Macs") {
                    showPairing = false
                    automaticConnection = true
                }
            }
        }
    }

    /// Every control in one row that scrolls sideways when it is wider
    /// than the screen, instead of hiding some behind an overflow menu.
    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    toggleKeyboard()
                } label: {
                    BarIcon("keyboard")
                }
                .accessibilityLabel(keyboardShown ? "Hide keyboard" : "Show keyboard")
                .accessibilityHint(viewer.isControlAllowed ? "" : "Explains how to enable keyboard and pointer control")
                .accessibilityIdentifier("tailview.keyboardButton")
                Button { pasteClipboard() } label: {
                    BarIcon("doc.on.clipboard")
                }
                .accessibilityLabel("Paste from this device")
                .accessibilityHint("Pastes the text you copied into the focused Mac app")
                .accessibilityIdentifier("tailview.pasteButton")
                .disabled(!viewer.isControlAllowed)
                ForEach(ControlCommand.Modifier.allCases, id: \.self) { modifier in
                    modifierButton(modifier)
                }
                Button {
                    microphoneSessionEnabled.toggle()
                    if microphoneSessionEnabled { viewer.startMicrophone() }
                    else { viewer.stopMicrophone() }
                } label: {
                    BarIcon(!microphoneSessionEnabled ? "mic.slash.fill"
                            : viewer.microphoneNeedsAttention ? "mic.badge.xmark" : "mic.fill")
                }
                // Orange: unmuted but not sending. Muting and unmuting retries.
                .tint(!microphoneSessionEnabled ? Color.red
                      : viewer.microphoneNeedsAttention ? Color.orange : nil)
                .accessibilityLabel(microphoneSessionEnabled ? "Mute microphone" : "Unmute microphone")
                .accessibilityValue(!microphoneSessionEnabled ? "Muted"
                                    : viewer.microphoneNeedsAttention ? "Not sending: \(viewer.microphoneStatus)" : "On")
                .accessibilityHint("Controls voice sent to the Mac when this device owns audio")
                .accessibilityIdentifier("tailview.microphoneMuteButton")
                Button {
                    macAudioSessionEnabled.toggle()
                    if macAudioSessionEnabled { viewer.startMacAudio() }
                    else { viewer.stopMacAudio() }
                } label: {
                    BarIcon(macAudioSessionEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .tint(macAudioSessionEnabled ? nil : Color.red)
                .accessibilityLabel(macAudioSessionEnabled ? "Mute Mac sound" : "Unmute Mac sound")
                .accessibilityValue(macAudioSessionEnabled ? "On" : "Muted")
                .accessibilityHint("Controls Mac sound played on this device when it owns audio")
                .accessibilityIdentifier("tailview.speakerMuteButton")
                spaceButtons
                windowButtons
                pointerButtons
                if screenZoom > 1.01 {
                    Button { isPanningView.toggle() } label: {
                        BarIcon(isPanningView ? "hand.point.up.left.fill" : "hand.point.up.left")
                    }
                    .barButtonStyle(prominent: isPanningView)
                    .accessibilityLabel(isPanningView ? "Stop panning view" : "Pan view")
                    .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
                    Button { screenZoom = 1; screenOffset = .zero } label: {
                        BarIcon("1.magnifyingglass")
                    }
                    .accessibilityLabel("Reset zoom")
                }
                ForEach(BarKey.allCases, id: \.self) { key in
                    Button { sendBarKey(key) } label: {
                        BarIcon(key.systemImage)
                    }
                    .accessibilityLabel(key.title)
                    .disabled(!viewer.isControlAllowed)
                }
            }
            .padding(8)
        }
        .buttonStyle(.bordered)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // Above the bar without resizing the Mac screen.
        .overlay(alignment: .top) {
            if let notice {
                Text(notice)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// Sends the copied text to the Mac in one piece, where it is pasted with
    /// Command-V. The bar's modifiers don't apply and stay selected. Returns
    /// false only for a keyboard paste to a Mac without paste support, which
    /// UIKit then types as before.
    @discardableResult
    private func pasteClipboard(fromKeyboard: Bool = false) -> Bool {
        guard viewer.isControlAllowed else { return true }
        guard viewer.macAcceptsPaste else {
            if fromKeyboard { return false }
            showNotice("Update TailView on the Mac to paste")
            return true
        }
        let pasteboard = UIPasteboard.general
        // These checks don't read the clipboard, so iOS doesn't ask first.
        guard pasteboard.numberOfItems > 0 else {
            showNotice("Clipboard is empty")
            return true
        }
        guard pasteboard.hasStrings || pasteboard.hasURLs else {
            showNotice("Clipboard has no text")
            return true
        }
        // Reading it may ask to allow pasting from another app.
        guard let text = pasteboard.hasStrings ? pasteboard.string : pasteboard.url?.absoluteString,
              !text.isEmpty else {
            showNotice("Could not read the clipboard")
            return true
        }
        guard text.utf8.count <= ClipboardPaste.maximumBytes else {
            showNotice("Clipboard text is over 1 MB")
            return true
        }
        if viewer.sendPaste(text) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            showNotice("Could not paste on the Mac")
        }
        return true
    }

    private func showNotice(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        UIAccessibility.post(notification: .announcement, argument: message)
        noticeGeneration += 1
        let generation = noticeGeneration
        withAnimation { notice = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard noticeGeneration == generation else { return }
            withAnimation { notice = nil }
        }
    }

    /// Control-arrow shortcuts for Spaces, Mission Control, and App windows.
    private var spaceButtons: some View {
        ForEach(MacNavigation.allCases, id: \.self) { action in
            Button { sendNavigation(action) } label: {
                BarIcon(action.systemImage)
            }
            .accessibilityLabel(action.title)
            .disabled(!viewer.isControlAllowed)
        }
    }

    /// Tiles the Mac's frontmost window on its screen.
    private var windowButtons: some View {
        ForEach(ControlCommand.WindowLayout.allCases, id: \.self) { layout in
            Button {
                guard viewer.isControlAllowed else { return }
                viewer.sendControl(ControlCommand(kind: .window, window: layout))
            } label: {
                BarIcon(layout.systemImage)
            }
            .accessibilityLabel(layout.title)
            .disabled(!viewer.isControlAllowed)
        }
    }

    private var pointerButtons: some View {
        Group {
            Button { sendPointer(.leftClick) } label: {
                BarIcon("cursorarrow.click")
            }
            .accessibilityLabel("Left click")
            .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
            Button { sendPointer(.rightClick) } label: {
                BarIcon("cursorarrow.click.2")
            }
            .accessibilityLabel("Right click")
            .disabled(!viewer.isControlAllowed || isDraggingRemote || isTouchDraggingRemote)
            Button { toggleDrag() } label: {
                BarIcon(isDraggingRemote ? "hand.raised.fill" : "hand.draw")
            }
            .barButtonStyle(prominent: isDraggingRemote)
            .accessibilityLabel(isDraggingRemote ? "Release drag" : "Start drag")
            .disabled(!viewer.isControlAllowed || isTouchDraggingRemote)
        }
    }

    private func modifierButton(_ modifier: ControlCommand.Modifier) -> some View {
        let mode = modifierSelection.mode(for: modifier)
        let latched = modifier == .function && viewer.functionLatched
        let tint: Color? = latched ? .green : mode == .held ? .orange : nil
        let value = latched ? "Held from lock screen" : mode == .held ? "Held" : mode == .next ? "Next action" : "Off"
        return Button {
            modifierSelection.tap(modifier)
        } label: {
            HStack(spacing: 2) {
                Text(modifier.symbol).font(.body.weight(.semibold))
                if mode == .held {
                    Image(systemName: "lock.fill").font(.system(size: 8))
                }
            }
            .frame(minWidth: BarIcon.size, minHeight: BarIcon.size)
        }
        .barButtonStyle(prominent: mode != .off || latched)
        .tint(tint)
        // SwiftUI long presses on a button in the scrolling bar end as soon as
        // they begin, so fn takes its touches through UIKit recognizers.
        .allowsHitTesting(modifier != .function)
        .overlay {
            if modifier == .function {
                PressGestureOverlay(isEnabled: viewer.isControlAllowed,
                                    title: modifier.symbol,
                                    onTap: {
                                        if viewer.functionLatched { viewer.setFunctionLatched(false) }
                                        else { modifierSelection.tap(.function) }
                                    },
                                    onPressBegan: pressFunctionKey,
                                    onPressEnded: releaseFunctionKey)
            }
        }
        .accessibilityLabel("\(modifier.title) modifier")
        .accessibilityValue(value)
        .accessibilityHint("Tap once for the next action. Double tap to hold. Tap a held modifier to release it.")
        .accessibilityAction(named: "Hold \(modifier.title)") {
            modifierSelection.hold(modifier)
        }
        .accessibilityIdentifier("tailview.modifier.\(modifier.rawValue)")
        .disabled(!viewer.isControlAllowed)
    }

    private func pressFunctionKey() -> Bool {
        guard viewer.pressFunction() else { return false }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return true
    }

    /// Ends a press on fn. Fn held from the lock screen stays down until
    /// released there or by tapping fn.
    private func releaseFunctionKey() {
        viewer.endFunctionPress()
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("TailView access") {
                    Text(access.statusTitle)
                    Text(access.statusDetail).font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Trial, purchase and restore") {
                        PurchaseView(access: access, embedded: true)
                    }
                }
                Section("Connection") {
                    Text(viewer.status)
                    if viewer.isConnected || viewer.isReconnecting {
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
                                guard access.streamAllowed else { return }
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
                Section("Lock screen") {
                    Toggle("Show lock screen controls", isOn: $lockScreenControls)
                    Text("Controls remain available while intentional audio is running. Muting stops that audio direction. If both are off, iOS may suspend the connection; open TailView to reconnect or turn audio back on.")
                }
                Section("Remote control") {
                    Toggle("Enable keyboard and pointer control", isOn: $remoteControlConsent)
                    Text("The Mac must also allow remote control. Turning this off keeps screen viewing available and stops input from this device.")
                }
                Section("Microphone") {
                    Toggle("Connect microphone automatically", isOn: $microphoneOnConnect)
                    Text("Sends this device’s microphone to the Mac. This requires microphone permission here and optional BlackHole setup and consent on the Mac.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text("Tap Control, Option, or Command once for the next key or click. Tap twice quickly to hold it for multiple actions; tap a held modifier again to release it. Blue means next action and orange means held.")
                }
                Section("Help") {
                    Link("Setup and troubleshooting", destination: URL(string: "https://alexmorris10x.github.io/tailview/setup.html")!)
                    Link("Privacy", destination: URL(string: "https://alexmorris10x.github.io/tailview/privacy.html")!)
                    Link("Support", destination: URL(string: "https://alexmorris10x.github.io/tailview/support.html")!)
                    Text("TailView \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                        .font(.caption).foregroundStyle(.secondary)
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

    /// The chosen Mac. If that Mac rejected this profile, the newest other
    /// profile for the same address, which is usually the pairing that replaced
    /// it; never a different Mac.
    private var preferredProfile: SavedMac? {
        let chosen = viewer.savedMacs.first { $0.id.uuidString == preferredMacID } ?? viewer.savedMacs.first
        guard let chosen, viewer.rejectedMacIDs.contains(chosen.id) else { return chosen }
        return viewer.savedMacs.last {
            $0.address == chosen.address && !viewer.rejectedMacIDs.contains($0.id)
        } ?? chosen
    }

    private func connectPreferredIfNeeded() {
        #if DEBUG
        // A recorder-only launch must not let the periodic reconnect timer
        // reactivate playback and interrupt the four-second microphone test.
        guard !ProcessInfo.processInfo.arguments.contains("--tailview-test-isolated-recorder") else { return }
        #endif
        guard access.streamAllowed, scenePhase == .active, automaticConnection, !showPairing, !diagnosticLaunch,
              !viewer.isConnected, !viewer.isConnecting, !viewer.isReconnecting,
              let profile = preferredProfile, !viewer.rejectedMacIDs.contains(profile.id) else { return }
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

    private func sendBarKey(_ key: BarKey) {
        switch key {
        case .scrollUp: sendControl(ControlCommand(kind: .scroll, amount: -3))
        case .scrollDown: sendControl(ControlCommand(kind: .scroll, amount: 3))
        case .returnKey: sendKey(.returnKey)
        case .tab: sendKey(.tab)
        case .delete: sendKey(.delete)
        case .escape: sendKey(.escape)
        case .left: sendKey(.left)
        case .right: sendKey(.right)
        case .up: sendKey(.up)
        case .down: sendKey(.down)
        }
    }

    /// Sends Control plus an arrow, independent of the bar's modifier buttons.
    private func sendNavigation(_ action: MacNavigation) {
        guard viewer.isControlAllowed else { return }
        viewer.sendControl(ControlCommand(kind: .key, key: action.key, modifiers: [.control]))
    }

    private func showKeyboard() {
        keyboardUserHidden = false
        keyboardActive = true
        keyboardFocusRequest += 1
    }

    private func closeKeyboard() {
        nativeKeyboardVisible = false
        keyboardActive = false
    }

    /// Focus alone does not mean an onscreen keyboard is visible.
    private var keyboardShown: Bool {
        nativeKeyboardVisible
    }

    private func toggleKeyboard() {
        guard viewer.isControlAllowed else {
            keyboardUserHidden = false
            showControlHelp = true
            return
        }
        if keyboardShown {
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
        case .move, .leftDown, .leftDrag, .window, .functionDown, .functionUp:
            break
        }
    }
}

/// Keys and scrolling that were in the former overflow menu. These use
/// the bar's modifier buttons, like typed keys.
private enum BarKey: CaseIterable {
    case scrollUp, scrollDown, returnKey, tab, delete, escape, left, right, up, down

    var title: String {
        switch self {
        case .scrollUp: "Scroll up"
        case .scrollDown: "Scroll down"
        case .returnKey: "Return"
        case .tab: "Tab"
        case .delete: "Delete"
        case .escape: "Escape"
        case .left: "Left arrow"
        case .right: "Right arrow"
        case .up: "Up arrow"
        case .down: "Down arrow"
        }
    }

    var systemImage: String {
        switch self {
        case .scrollUp: "chevron.up.circle"
        case .scrollDown: "chevron.down.circle"
        case .returnKey: "return"
        case .tab: "arrow.right.to.line"
        case .delete: "delete.left"
        case .escape: "escape"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }
}

/// macOS's default Control-arrow shortcuts.
private enum MacNavigation: CaseIterable {
    case previousSpace, nextSpace, missionControl, appWindows

    var key: ControlCommand.Key {
        switch self {
        case .previousSpace: .left
        case .nextSpace: .right
        case .missionControl: .up
        case .appWindows: .down
        }
    }

    var title: String {
        switch self {
        case .previousSpace: "Previous Space"
        case .nextSpace: "Next Space"
        case .missionControl: "Mission Control"
        case .appWindows: "App windows"
        }
    }

    var systemImage: String {
        switch self {
        case .previousSpace: "rectangle.lefthalf.inset.filled.arrow.left"
        case .nextSpace: "rectangle.righthalf.inset.filled.arrow.right"
        case .missionControl: "rectangle.3.group"
        case .appWindows: "macwindow.on.rectangle"
        }
    }
}

/// A control-bar icon sized so every bar button has the same shape.
/// Tap and press-and-hold for a bar button. Once the long press begins it
/// keeps the touch, so the bar cannot scroll it away. The press draws its
/// own highlight because rebuilding the button mid-press loses the release.
private struct PressGestureOverlay: UIViewRepresentable {
    var isEnabled: Bool
    var title: String
    var onTap: () -> Void
    /// Returns whether the press was accepted and should show as held.
    var onPressBegan: () -> Bool
    var onPressEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PressView {
        let view = PressView()
        view.coordinator = context.coordinator
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.35
        press.allowableMovement = 12
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: press)
        view.addGestureRecognizer(press)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PressView, context: Context) {
        context.coordinator.parent = self
        view.label.text = title
        view.isUserInteractionEnabled = isEnabled
    }

    static func dismantleUIView(_ view: PressView, coordinator: Coordinator) {
        coordinator.endPress(in: view)
    }

    final class PressView: UIView {
        weak var coordinator: Coordinator?
        let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.isHidden = true
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func layoutSubviews() {
            super.layoutSubviews()
            label.frame = bounds
            layer.cornerRadius = bounds.height / 2
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { coordinator?.endPress(in: self) }
        }

        func showPressed(_ pressed: Bool) {
            backgroundColor = pressed ? .systemGreen : .clear
            label.isHidden = !pressed
        }
    }

    final class Coordinator: NSObject {
        var parent: PressGestureOverlay
        private var pressing = false

        init(_ parent: PressGestureOverlay) { self.parent = parent }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { parent.onTap() }
        }

        @objc func press(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view as? PressView else { return }
            switch recognizer.state {
            case .began:
                guard parent.onPressBegan() else { return }
                pressing = true
                view.showPressed(true)
            case .ended, .cancelled, .failed:
                endPress(in: view)
            default:
                break
            }
        }

        func endPress(in view: PressView) {
            guard pressing else { return }
            pressing = false
            view.showPressed(false)
            parent.onPressEnded()
        }
    }
}

private struct BarIcon: View {
    static let size: CGFloat = 26
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .frame(minWidth: Self.size, minHeight: Self.size)
    }
}

private extension View {
    /// Bordered like every bar button; filled while a state is active.
    @ViewBuilder func barButtonStyle(prominent: Bool) -> some View {
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

private extension ControlCommand.WindowLayout {
    var title: String {
        switch self {
        case .leftHalf: "Move window to left half"
        case .rightHalf: "Move window to right half"
        case .fill: "Fill screen with window"
        }
    }

    var systemImage: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .fill: "rectangle.inset.filled"
        }
    }
}

private extension ControlCommand.Modifier {
    var title: String {
        switch self {
        case .function: "Function"
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        }
    }

    var symbol: String {
        switch self {
        case .function: "fn"
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
