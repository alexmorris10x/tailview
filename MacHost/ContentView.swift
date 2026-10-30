import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var host: HostModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                details
            }
            footer
        }
        .padding(24)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await host.refreshSetup() } }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "display")
                    .font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("TailView")
                        .font(.largeTitle.bold())
                    Text(host.isPaused
                         ? "Access is paused. Resume Access to connect from a paired device."
                         : (host.isSharing ? "Sharing with your paired devices over Tailscale" : "Set up this Mac, then choose Start sharing"))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            setupSection

            LabeledContent("Access", value: host.status)
            LabeledContent("Viewer", value: host.viewerStatus)
            LabeledContent("Viewer link", value: host.linkStatus)
            LabeledContent("Microphone", value: host.microphoneStatus)
            LabeledContent("Mac sound", value: host.systemAudioStatus)
            LabeledContent("Mac audio routing", value: host.audioRoutingStatus)
            LabeledContent("Remote control", value: host.isControlEnabled ? "Allowed" : host.controlStatus)

            if host.isSharing {
                GroupBox("Connect from TailView on iPhone or iPad") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Mac address", value: host.address)
                        LabeledContent("Port", value: "47820")
                        if host.isPairingOpen {
                            LabeledContent("Pairing code", value: host.sessionCode)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                HStack {
                    if host.isPairingOpen {
                        Button("Close pairing") { host.disablePairing() }
                    } else {
                        Button("Pair a new device") { host.enablePairing() }
                    }
                    Text(host.isPairingOpen ? "Enter this code once on your new device." : "Trusted devices connect automatically when TailView opens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            accessSection

            GroupBox("Paired devices") {
                if host.pairedDevices.isEmpty {
                    Text("Start sharing, choose Pair a new device, then enter the Mac address and pairing code in TailView on your iPhone or iPad.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 8) {
                        ForEach(host.pairedDevices) { device in
                            HStack {
                                Text(device.name)
                                Spacer()
                                Button("Revoke", role: .destructive) { host.revoke(device.id) }
                            }
                        }
                    }
                }
            }
            if !host.pairingStatus.isEmpty {
                Text(host.pairingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisplayPrivacySection()
        }
    }

    private var setupSection: some View {
        GroupBox("Set up your Mac") {
            VStack(alignment: .leading, spacing: 12) {
                Label("1. Connect Tailscale", systemImage: host.tailscaleAddress.isEmpty ? "network" : "checkmark.circle.fill")
                    .font(.headline)
                Text(host.tailscaleStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(host.isTailscaleInstalled ? "Open Tailscale" : "Get Tailscale") { host.openTailscale() }
                    Link("Tailscale setup guide", destination: URL(string: "https://tailscale.com/kb/1016/install-mac")!)
                }
                Divider()
                Label("2. Allow Screen Recording", systemImage: host.hasScreenRecordingPermission ? "checkmark.circle.fill" : "display")
                    .font(.headline)
                Text(host.hasScreenRecordingPermission
                     ? "Allowed. TailView captures your main display and Mac sound only while you are sharing."
                     : "Screen Recording lets your paired devices see your main display and hear Mac sound. Allow TailView Mac in System Settings; macOS may ask you to reopen the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !host.hasScreenRecordingPermission {
                    Button("Allow Screen Recording…") { host.requestScreenRecordingPermission() }
                }
                Divider()
                Label("3. Start sharing and pair your device", systemImage: host.isSharing ? "checkmark.circle.fill" : "iphone.and.arrow.forward")
                    .font(.headline)
                Text("Start sharing enables access while TailView runs. Your choice is remembered when the app reopens. Pause Access disconnects all viewers and keeps sharing off until you resume it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Check setup again") { Task { await host.refreshSetup() } }
                        .disabled(host.isCheckingSetup)
                    if host.isCheckingSetup { ProgressView().controlSize(.small) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var accessSection: some View {
        GroupBox("Optional access") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow paired devices to control this Mac", isOn: Binding(
                    get: { host.allowsRemoteControl },
                    set: { host.setRemoteControlAllowed($0) }
                ))
                Text("Enables taps, typing, shortcuts, and clipboard paste from paired devices. Turning this off keeps viewing available. macOS Accessibility permission is also required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Accessibility", value: host.hasAccessibilityPermission ? "Allowed by macOS" : "Not yet allowed · optional")
                if host.allowsRemoteControl && !host.hasAccessibilityPermission {
                    Button("Allow Accessibility…") { host.requestControlPermission() }
                }
                Divider()
                Toggle("Automatically route audio for the remote microphone", isOn: Binding(
                    get: { host.automaticAudioRouting },
                    set: { host.setAutomaticAudioRouting($0) }
                ))
                Text("While a paired viewer is connected, sends its microphone through BlackHole 2ch, selects BlackHole as the Mac’s default input, and keeps output on speakers or headphones to avoid feedback. TailView restores your previous input and output when you disconnect, pause, quit, or turn this off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("BlackHole is an optional, separate installation. Screen viewing and Mac sound work without it, with your Mac’s audio selections unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Get BlackHole 2ch", destination: URL(string: "https://existential.audio/blackhole/")!)
                Text("One viewer at a time handles Mac sound and microphone. Choose Audio device in the iPhone or iPad app to switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            if host.isPaused {
                Button("Resume Access") { host.resumeAccess() }
            } else if host.isSharing || host.isStarting {
                Button("Pause Access") { host.pauseAccess() }
            } else {
                Button(host.sharingWasEnabled ? "Start sharing again" : "Start sharing") { host.start() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            Text("Your main display · Tailscale only")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Built-in display blackout and local-input shield (formerly Display Control), plus app settings.
private struct DisplayPrivacySection: View {
    @EnvironmentObject private var display: DisplayControlModel
    @AppStorage(DockVisibility.key) private var showInDock = true

    var body: some View {
        GroupBox("Display privacy") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Keep this Mac’s built-in screen dark during a remote session without sleeping or locking it. TailView keeps sharing the screen while the backlight is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Backlight", value: backlightStatus)
                HStack {
                    Button(display.isBlackoutActive ? "Restore Display Backlight" : "Blackout Display") {
                        display.toggleBlackout()
                    }
                    .disabled(!display.isBlackoutSupported)
                    if display.isBuiltInDisconnected {
                        Button("Reconnect Built-In Display") { display.reconnectBuiltIn() }
                    } else {
                        Button("Disconnect Built-In Display…") { display.disconnectBuiltIn() }
                            .disabled(!display.isDisconnectSupported)
                    }
                    if display.isRecoveryCountdownActive {
                        Button("Keep Disconnected (\(display.recoverySecondsRemaining)s)") { display.keepDisconnected() }
                    }
                }
                Toggle("Block local keyboard & mouse when blacked out", isOn: Binding(
                    get: { display.blocksLocalInputWhenBlackedOut },
                    set: { display.setBlocksLocalInputWhenBlackedOut($0) }
                ))
                Text("Physical keyboard, brightness keys, mouse, and trackpad stop working; TailView remote control keeps working. Restoring the backlight releases local input. There is no physical keyboard escape.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        GroupBox("App") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(display.launchAtLoginStatus == .requiresApproval ? "Launch at login (approval required in System Settings)" : "Launch at login",
                       isOn: Binding(get: { display.launchAtLoginStatus == .enabled },
                                     set: { _ in display.toggleLaunchAtLogin() }))
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, shown in DockVisibility.apply(shown) }
                Text("When hidden, open TailView from its menu bar item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var backlightStatus: String {
        if !display.isBlackoutSupported { return "Unavailable on this Mac" }
        if display.isBuiltInDisconnected { return "Built-in display disconnected" }
        if display.isBlackoutActive {
            return display.isInputShieldActive ? "Off · local input blocked" : "Off"
        }
        return "On"
    }
}
