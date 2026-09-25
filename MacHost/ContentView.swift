import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var host: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                details
            }
            footer
        }
        .padding(24)
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
                         : "Ready for trusted devices while this app is running")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            LabeledContent("Access", value: host.status)
            LabeledContent("Viewer", value: host.viewerStatus)
            LabeledContent("Microphone", value: host.microphoneStatus)
            LabeledContent("Mac sound", value: host.systemAudioStatus)
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
                GroupBox("Trusted device control") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paired devices can view and control this Mac. One device at a time handles sound and microphone. Use Audio device in iOS Settings to switch it. Pause Access to disconnect both immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(host.controlStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !ControlInjector.hasPermission() {
                            Button("Grant Mac control permission") { host.requestControlPermission() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            GroupBox("Paired devices") {
                if host.pairedDevices.isEmpty {
                    Text("No saved devices yet")
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

    private var footer: some View {
        HStack {
            if host.isPaused {
                Button("Resume Access") { host.resumeAccess() }
            } else {
                Button("Pause Access") { host.pauseAccess() }
                if !host.isSharing && !host.isStarting {
                    Button("Retry sharing") { host.start() }
                }
            }
            Spacer()
            Text("Main display • up to 8 fps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Built-in display blackout and local-input shield, formerly Display Control.
private struct DisplayPrivacySection: View {
    @EnvironmentObject private var display: DisplayControlModel

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
                Toggle(display.launchAtLoginStatus == .requiresApproval ? "Launch at login (approval required in System Settings)" : "Launch at login",
                       isOn: Binding(get: { display.launchAtLoginStatus == .enabled },
                                     set: { _ in display.toggleLaunchAtLogin() }))
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
