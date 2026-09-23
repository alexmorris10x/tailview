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
                    Text("Share this Mac with your iPhone or iPad")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            LabeledContent("Screen", value: host.status)
            LabeledContent("Viewer", value: host.viewerStatus)
            LabeledContent("Microphone", value: host.microphoneStatus)
            LabeledContent("Remote control", value: host.isControlEnabled ? "Allowed" : "Off")

            if host.isSharing {
                GroupBox("Connect from TailView on iPhone or iPad") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Mac address", value: host.address)
                        LabeledContent("Port", value: "47820")
                        LabeledContent("Session code", value: host.sessionCode)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                HStack {
                    if host.isPairingOpen {
                        Button("Close pairing") { host.disablePairing() }
                    } else {
                        Button("Pair a new device") { host.enablePairing() }
                            .disabled(host.viewerStatus == "Connected")
                    }
                    Text(host.isPairingOpen ? "Enter the session code once on your device." : "Saved devices can connect while sharing is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GroupBox("Remote control") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if host.isControlEnabled {
                                Button("Stop Control", role: .destructive) { host.disableControl() }
                            } else {
                                Button("Allow Control") { host.enableControl() }
                                    .disabled(host.viewerStatus != "Connected")
                            }
                            Text("Only a connected, paired device can control this Mac. Approval ends when sharing stops or the device disconnects.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(host.controlStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                if host.isSharing {
                    Button("Stop sharing") { host.stop() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start sharing") { host.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(host.isStarting)
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
