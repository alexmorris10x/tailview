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
