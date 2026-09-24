import AppKit
import SwiftUI

@main
struct TailViewMacApp: App {
    @StateObject private var host = HostModel()

    var body: some Scene {
        MenuBarExtra("TailView", systemImage: host.isPaused ? "display.slash" : "display") {
            TailViewMenu()
                .environmentObject(host)
        }

        Settings {
            ContentView()
                .environmentObject(host)
                .frame(minWidth: 560, minHeight: 480)
        }
    }
}

private struct TailViewMenu: View {
    @EnvironmentObject private var host: HostModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(host.isPaused ? "Access paused" : host.status)
        Text(host.viewerStatus)
        Divider()
        if host.isPaused {
            Button("Resume Access") { host.resumeAccess() }
        } else {
            Button("Pause Access") { host.pauseAccess() }
            if !host.isSharing && !host.isStarting {
                Button("Retry sharing") { host.start() }
            }
            Button("Pair a New Device…") {
                host.enablePairing()
                openSettings()
            }
            .disabled(!host.isSharing || host.viewerStatus == "Connected")
        }
        Button("Settings…") { openSettings() }
        Divider()
        Button("Quit TailView") { NSApplication.shared.terminate(nil) }
    }
}
