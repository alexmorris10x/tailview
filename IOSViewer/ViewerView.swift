import SwiftUI

struct ViewerView: View {
    @AppStorage("macAddress") private var macAddress = ""
    @State private var code = ""
    @State private var didRunDebugLaunch = false
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
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        Form {
                            Section("Acoustic microphone test") {
                                Text("Plays a two-second tone through this device's speaker. Its microphone must capture that sound and send it to the Mac; the tone is never sent directly.")
                                Button("Play test tone") { viewer.runAcousticTest() }
                                    .disabled(!viewer.isMicrophoneOn)
                                Button("Compare with system recorder") { viewer.runRecorderTest() }
                                Text(viewer.debugStatus)
                                Text(viewer.inputLevelStatus)
                                Text(viewer.microphoneStatus)
                            }
                            Section("Transport test") {
                                Text("Sends generated PCM to the Mac without using the microphone. This verifies the connection and receiver only.")
                                Button("Send generated audio") { viewer.sendSyntheticAudioTest() }
                                    .disabled(!viewer.isConnected)
                            }
                        }
                        .navigationTitle("Debug Settings")
                    } label: {
                        Label("Debug Settings", systemImage: "gearshape")
                    }
                }
            }
            #endif
        }
        .task {
            #if DEBUG
            guard !didRunDebugLaunch else { return }
            didRunDebugLaunch = true
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--tailview-test-connect"),
               arguments.count > index + 2 {
                macAddress = arguments[index + 1]
                code = arguments[index + 2]
                viewer.connect(host: macAddress, code: code, startMicrophoneOnConnect: true,
                               runAcousticTestOnConnect: arguments.contains("--tailview-test-tone"),
                               runRecorderTestOnConnect: arguments.contains("--tailview-test-recorder"),
                               runSyntheticTestOnConnect: arguments.contains("--tailview-test-synthetic"))
            }
            #endif
        }
    }
}
