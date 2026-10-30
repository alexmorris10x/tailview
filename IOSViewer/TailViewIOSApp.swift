import SwiftUI

@main
struct TailViewIOSApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-tailview-test-purchases"),
               NSClassFromString("XCTestCase") != nil {
                // Hosted tests configure SKTestSession before constructing the
                // purchase client. ViewerView would otherwise start StoreKit
                // from PurchaseAccess.shared before that session exists.
                Color.clear
            } else {
                ViewerView()
            }
            #else
            ViewerView()
            #endif
        }
    }
}
