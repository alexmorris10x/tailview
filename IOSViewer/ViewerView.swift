import SwiftUI

struct ViewerView: View {
    @AppStorage("macAddress") private var macAddress = ""
    @State private var code = ""
    @State private var profileName = "My Mac"
    @State private var showPairing = false
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
                        }
                        .navigationTitle("Debug Settings")
                    } label: {
                        Label("Debug Settings", systemImage: "gearshape")
                    }
                }
            }
            #endif
        }
        .onChange(of: viewer.isConnected) { _, connected in
            if connected { showPairing = false; code = "" }
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
}
