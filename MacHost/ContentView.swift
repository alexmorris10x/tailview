import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var host: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "display")
                    .font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("TailView")
                        .font(.largeTitle.bold())
                    Text("Ready for trusted devices while this app is running")
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
                        Text("Up to two paired devices can view the screen and control the mouse and keyboard. One device at a time hears Mac sound and sends its microphone to this Mac. Choose Use audio on this device in iOS Settings to switch both audio directions. Pause Access from the menu bar to disconnect both immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    ScrollView {
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
                    .frame(maxHeight: 140)
                }
            }
            if !host.pairingStatus.isEmpty {
                Text(host.pairingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

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
        .padding(24)
    }
}
