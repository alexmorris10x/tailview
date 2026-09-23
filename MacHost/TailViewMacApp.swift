import SwiftUI

@main
struct TailViewMacApp: App {
    @StateObject private var host = HostModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(host)
                .frame(minWidth: 520, minHeight: 430)
        }
    }
}
