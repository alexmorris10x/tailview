import XCTest

/// Writes the App Store screenshots from the real app: the access screen with
/// local StoreKit products, the first-run setup screen, then a real pairing and
/// session with the demo Mac host (docs/app-store/screenshots/2026-11-07/tools),
/// whose three desktop frames are picked with the bar's window buttons.
/// Runs only with TEST_RUNNER_TV_SHOTS_DIR and TEST_RUNNER_TV_DEMO_HOST set.
final class AppStoreScreenshotUITests: XCTestCase {
    private var directory: URL!
    private var host: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["TV_SHOTS_DIR"] == nil || env["TV_DEMO_HOST"] == nil,
                      "Set TEST_RUNNER_TV_SHOTS_DIR and TEST_RUNNER_TV_DEMO_HOST to write App Store screenshots.")
        directory = URL(fileURLWithPath: env["TV_SHOTS_DIR"]!)
        host = env["TV_DEMO_HOST"]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        continueAfterFailure = false
    }

    /// TEST_RUNNER_TV_SHOTS_PART=access (run with -configuration Release, so the
    /// App Store bundle ID loads its real products) or =session (Debug, which
    /// has full access without a purchase). Unset runs both.
    func testAppStoreScreens() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let part = ProcessInfo.processInfo.environment["TV_SHOTS_PART"]
        if part != "session" { try accessScreen() }
        if part != "access" { try sessionScreens() }
    }

    /// The trial and lifetime offer with App Store prices.
    private func accessScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-tailview-test-purchases"]
        app.launch()
        tap(app.buttons["tailview.settings"])
        tap(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Trial, purchase'")).firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["tailview.purchase.status"].waitForExistence(timeout: 90))
        // The offers sit below the fold in landscape; the form builds rows only when shown.
        let lifetime = app.buttons["tailview.purchase.lifetime"]
        let window = app.windows.firstMatch
        for _ in 0..<8 where !(lifetime.exists && lifetime.isHittable) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(lifetime.waitForExistence(timeout: 90))
        let priced = NSPredicate(format: "label CONTAINS '·'")
        expectation(for: priced, evaluatedWith: lifetime)
        waitForExpectations(timeout: 90)
        try shot("05-access")
        app.terminate()
    }

    /// First-run setup, then a real pairing and session with the demo Mac.
    private func sessionScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-remoteControlConsent", "YES", "-macAudioOnConnect", "YES", "-microphoneOnConnect", "NO"]
        app.launch()
        let name = app.textFields["tailview.profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 90))
        try shot("04-setup")
        tap(name)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "MacBook Pro")
        tap(app.textFields["tailview.mac-address"])
        app.textFields["tailview.mac-address"].typeText(host)
        tap(app.secureTextFields["tailview.pairing-code"])
        app.secureTextFields["tailview.pairing-code"].typeText(UUID().uuidString.lowercased())
        tap(app.buttons["tailview.pair"])

        let keyboard = app.buttons["tailview.keyboardButton"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 60))
        Thread.sleep(forTimeInterval: 3)
        dismissSystemPrompts(app)
        if keyboard.label == "Hide keyboard" { tap(keyboard) }

        // Inside the Mac image, which is narrower than the window on iPhone.
        try frame(app, at: 0.30, name: "01-control", keyboardUp: false)
        try frame(app, at: 0.5, name: "02-see-hear", keyboardUp: false)
        // iPad has room for the software keyboard; on iPhone in landscape it would
        // cover most of the Mac, so show a latched Command key instead.
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        try frame(app, at: 0.70, name: "03-keyboard", keyboardUp: pad, modifier: pad ? nil : "command")
    }

    /// A click on the left, middle or right of the remote screen tells the demo
    /// host which desktop to stream.
    private func frame(_ app: XCUIApplication, at x: CGFloat, name: String, keyboardUp: Bool,
                       modifier: String? = nil) throws {
        let keyboard = app.buttons["tailview.keyboardButton"]
        dismissSystemPrompts(app)
        if keyboard.label == "Hide keyboard" { tap(keyboard) }
        Thread.sleep(forTimeInterval: 1)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.42)).tap()
        if let modifier { tap(app.buttons["tailview.modifier.\(modifier)"]) }
        if keyboardUp && keyboard.label != "Hide keyboard" { tap(keyboard) }
        Thread.sleep(forTimeInterval: 4)
        try shot(name)
    }

    /// iOS offers to save the pairing code as a password and shows a one-time
    /// slide-to-type tip with the first keyboard; neither belongs in a shot.
    private func dismissSystemPrompts(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<12 {
            let candidates = [app.buttons["Not Now"], springboard.buttons["Not Now"], app.buttons["Continue"]]
            if let prompt = candidates.first(where: { $0.exists }) {
                prompt.tap()
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 180), "\(element) never appeared")
        element.tap()
    }

    private func shot(_ name: String) throws {
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}
