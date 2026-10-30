import Foundation

@main
struct HostConsentSmoke {
    static func main() throws {
        let suite = "TailView.HostConsentSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func reset() { defaults.removePersistentDomain(forName: suite) }

        let fresh = HostConsent(defaults: defaults, hasPairedDevices: false)
        try check(!fresh.sharingEnabled && !fresh.remoteControlAllowed && !fresh.automaticAudioRoutingEnabled,
                  "A fresh installation enabled sharing, control, or audio routing")
        fresh.sharingEnabled = true
        fresh.remoteControlAllowed = true
        fresh.automaticAudioRoutingEnabled = true
        let relaunched = HostConsent(defaults: defaults, hasPairedDevices: true)
        try check(relaunched.sharingEnabled && relaunched.remoteControlAllowed && relaunched.automaticAudioRoutingEnabled,
                  "Explicit consent did not survive relaunch")
        relaunched.sharingEnabled = false
        relaunched.remoteControlAllowed = false
        relaunched.automaticAudioRoutingEnabled = false
        let paused = HostConsent(defaults: defaults, hasPairedDevices: true)
        try check(!paused.sharingEnabled && !paused.remoteControlAllowed && !paused.automaticAudioRoutingEnabled,
                  "Existing pairings overrode explicit opt-outs")

        reset()
        let oldPaired = HostConsent(defaults: defaults, hasPairedDevices: true)
        try check(oldPaired.sharingEnabled, "A previously paired host lost its sharing preference")
        try check(!oldPaired.remoteControlAllowed && !oldPaired.automaticAudioRoutingEnabled,
                  "A previous pairing was incorrectly treated as optional access consent")

        reset()
        defaults.set(true, forKey: "tailview.accessPaused")
        let oldPaused = HostConsent(defaults: defaults, hasPairedDevices: true)
        try check(!oldPaused.sharingEnabled, "A legacy paused host resumed sharing")
        reset()
        defaults.set(false, forKey: "tailview.accessPaused")
        let oldResumed = HostConsent(defaults: defaults, hasPairedDevices: false)
        try check(oldResumed.sharingEnabled, "A legacy explicit Resume choice was lost")

        try check(TailscaleSetup.isTailscaleIPv4("100.64.0.1") && TailscaleSetup.isTailscaleIPv4("100.127.255.254"),
                  "Valid Tailscale addresses were rejected")
        for invalid in ["0.0.0.0", "127.0.0.1", "192.168.1.2", "100.63.1.2", "100.128.1.2", "100.64.0.256", "100.64.1", "100.64.1.2.3"] {
            try check(!TailscaleSetup.isTailscaleIPv4(invalid), "Accepted a non-Tailscale address: \(invalid)")
        }
        try check(TailscaleSetup.cliPaths.contains("/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
                  "The standalone Tailscale installation was not detected")
        print("Host consent passed: first launch, explicit choices, legacy sharing migration, optional access opt-outs, and Tailscale-only addresses")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
}
