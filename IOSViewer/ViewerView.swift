import SwiftUI

struct ViewerView: View {
    @AppStorage("macAddress") private var macAddress = ""
    @State private var code = ""
    @StateObject private var viewer = ViewerModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image = viewer.image {
                    GeometryReader { geometry in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .background(.black)
                } else {
                    ContentUnavailableView("No screen yet", systemImage: "display",
                                           description: Text(viewer.status))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 10) {
                    if !viewer.isConnected {
                        TextField("Mac Tailscale address (100.x.x.x)", text: $macAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Session code shown on Mac", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button(viewer.isConnecting ? "Cancel connection" : "Connect") {
                            if viewer.isConnecting {
                                viewer.disconnect()
                            } else {
                                viewer.connect(host: macAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                                               code: code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewer.isConnecting && (macAddress.isEmpty || code.isEmpty))
                    } else {
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
        }
    }
}
