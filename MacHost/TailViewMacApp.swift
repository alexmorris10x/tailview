import AppKit
import SwiftUI

@main
struct TailViewMacApp: App {
    @StateObject private var host = HostModel()

    var body: some Scene {
        WindowGroup("TailView", id: "main") {
            ContentView()
                .environmentObject(host)
                .frame(minWidth: 560, minHeight: 700)
        }
        .defaultSize(width: 680, height: 760)

        MenuBarExtra("TailView", systemImage: "display") {
            TailViewMenu()
                .environmentObject(host)
        }
    }
}

private struct TailViewMenu: View {
    @EnvironmentObject private var host: HostModel
    @Environment(\.openWindow) private var openWindow

    private func showMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "TailView" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some View {
        Text(host.isPaused ? "Access paused" : host.status)
        Text(host.viewerStatus)
        Divider()
        Button("Open TailView") { showMainWindow() }
        if host.isPaused {
            Button("Resume Access") { host.resumeAccess() }
        } else {
            Button("Pause Access") { host.pauseAccess() }
            if !host.isSharing && !host.isStarting {
                Button("Retry sharing") { host.start() }
            }
            Button("Pair a New Device…") {
                host.enablePairing()
                showMainWindow()
            }
            .disabled(!host.isSharing)
        }
        Divider()
        Button("Quit TailView") { NSApplication.shared.terminate(nil) }
    }
}
