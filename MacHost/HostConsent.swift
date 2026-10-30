import Foundation

/// App consent is separate from macOS permissions. An Accessibility grant alone
/// never authorizes a viewer, and a connection never opts into audio routing.
final class HostConsent {
    static let sharingKey = "tailview.sharingEnabled"
    static let controlKey = "tailview.remoteControlAllowed"
    static let audioRoutingKey = "tailview.automaticAudioRoutingEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, hasPairedDevices: Bool) {
        self.defaults = defaults
        if defaults.object(forKey: Self.sharingKey) == nil {
            // Older hosts only saved an explicit Pause/Resume choice. Pairing
            // also proves the owner had previously enabled this host.
            let wasPaused = defaults.object(forKey: "tailview.accessPaused") as? Bool
            defaults.set(wasPaused.map { !$0 } ?? hasPairedDevices, forKey: Self.sharingKey)
        }
    }

    var sharingEnabled: Bool {
        get { defaults.bool(forKey: Self.sharingKey) }
        set { defaults.set(newValue, forKey: Self.sharingKey) }
    }

    var remoteControlAllowed: Bool {
        get { defaults.bool(forKey: Self.controlKey) }
        set { defaults.set(newValue, forKey: Self.controlKey) }
    }

    var automaticAudioRoutingEnabled: Bool {
        get { defaults.bool(forKey: Self.audioRoutingKey) }
        set { defaults.set(newValue, forKey: Self.audioRoutingKey) }
    }
}
