import AppKit
import SwiftUI

@main
struct TailViewMacApp: App {
    @NSApplicationDelegateAdaptor(TailViewAppDelegate.self) private var appDelegate
    @StateObject private var host = HostModel()

    var body: some Scene {
        WindowGroup("TailView", id: "main") {
            ContentView()
                .environmentObject(host)
                .environmentObject(host.display)
                .frame(minWidth: 560, minHeight: 700)
        }
        .defaultSize(width: 680, height: 880)

        MenuBarExtra("TailView", systemImage: "display") {
            TailViewMenu()
                .environmentObject(host)
                .environmentObject(host.display)
        }
    }
}

/// Whether TailView shows a Dock icon or lives only in the menu bar.
enum DockVisibility {
    static let key = "tailview.showInDock"

    static var isShown: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func apply(_ shown: Bool) {
        NSApplication.shared.setActivationPolicy(shown ? .regular : .accessory)
        // Changing the policy deactivates the app; keep its window in front.
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
}

final class TailViewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(DockVisibility.isShown ? .regular : .accessory)
    }
}

private struct TailViewMenu: View {
    @EnvironmentObject private var host: HostModel
    @EnvironmentObject private var display: DisplayControlModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DockVisibility.key) private var showInDock = true

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
        Button(display.isBlackoutActive ? "Restore Display Backlight" : "Blackout Display (Backlight Off)") {
            display.toggleBlackout()
        }
        .disabled(!display.isBlackoutSupported)
        Menu("Advanced") {
            if display.isBuiltInDisconnected {
                Button("Reconnect Built-In Display") { display.reconnectBuiltIn() }
            } else {
                Button("Disconnect Built-In Display…") { display.disconnectBuiltIn() }
                    .disabled(!display.isDisconnectSupported)
            }
            if display.isRecoveryCountdownActive {
                Button("Keep Disconnected (\(display.recoverySecondsRemaining)s)") { display.keepDisconnected() }
            }
            Divider()
            Toggle("Block Local Keyboard & Mouse When Blacked Out", isOn: Binding(
                get: { display.blocksLocalInputWhenBlackedOut },
                set: { display.setBlocksLocalInputWhenBlackedOut($0) }
            ))
        }
        Divider()
        Toggle(display.launchAtLoginStatus == .requiresApproval ? "Launch at Login (Approval Required)" : "Launch at Login",
               isOn: Binding(get: { display.launchAtLoginStatus == .enabled },
                             set: { _ in display.toggleLaunchAtLogin() }))
        Toggle("Show in Dock", isOn: $showInDock)
            .onChange(of: showInDock) { _, shown in DockVisibility.apply(shown) }
        Divider()
        Button("Quit TailView") { NSApplication.shared.terminate(nil) }
    }
}
