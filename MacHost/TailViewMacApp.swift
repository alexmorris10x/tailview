import SwiftUI

@main
struct TailViewMacApp: App {
    @StateObject private var host = HostModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(host)
                .frame(minWidth: 560, minHeight: 520)
        }
    }
}
