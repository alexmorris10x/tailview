import CoreAudio
import Foundation

@main
struct AudioRoutingSmoke {
    @MainActor
    static func main() throws {
        let suite = "TailView.AudioRoutingSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = FakeAudio()
        let routing = AudioRoutingController(backend: hardware, defaults: defaults)

        routing.enforce()
        try check(hardware.selected[.input] == 1, "Idle host changed the input")
        routing.setConnected(true)
        try check(hardware.selected[.input] == 2, "Connection did not select BlackHole")
        try check(hardware.selected[.output] == 3, "Connection replaced the selected headphones")
        try check(hardware.selected[.systemOutput] == 3, "System sound was routed elsewhere")

        hardware.selected = [.input: 1, .output: 2, .systemOutput: 2]
        routing.enforce()
        try check(hardware.selected == [.input: 2, .output: 3, .systemOutput: 3],
                  "A changed route was not corrected")
        routing.setConnected(true) // Another viewer must not overwrite the original snapshot.
        routing.setConnected(false)
        try check(hardware.selected == [.input: 1, .output: 3, .systemOutput: 4],
                  "Disconnect did not restore all three original defaults")

        hardware.selected = [.input: 1, .output: 2, .systemOutput: 2]
        routing.setConnected(true)
        try check(hardware.selected[.output] == 4 && hardware.selected[.systemOutput] == 4,
                  "BlackHole playback was allowed to loop into input")
        routing.setConnected(false)

        hardware.selected = [.input: 1, .output: 3, .systemOutput: 4]
        routing.setConnected(true)
        hardware.available.removeAll { $0.id == 3 }
        routing.enforce()
        try check(hardware.selected[.output] == 4, "Disconnected headset had no speaker fallback")
        routing.setConnected(false)
        try check(hardware.selected[.input] == 1 && hardware.selected[.output] == 4,
                  "Missing saved headset prevented restoration")

        hardware.available.removeAll { $0.id == 2 }
        routing.setConnected(true)
        try check(routing.status.contains("Install BlackHole"), "Missing BlackHole was hidden")
        try check(hardware.selected[.input] == 1, "Missing BlackHole silenced the local mic")
        hardware.available.append(FakeAudio.blackHole)
        routing.enforce()
        try check(hardware.selected[.input] == 2, "Newly available BlackHole was not selected")
        routing.setConnected(false)

        // Simulate a crash by constructing a new controller from the journal.
        routing.setConnected(true)
        hardware.selected[.systemOutput] = 3 // An unrelated post-crash change must survive recovery.
        hardware.available.append(FakeAudio.headphones)
        let recovery = AudioRoutingController(backend: hardware, defaults: defaults)
        try check(hardware.selected[.input] == 1 && hardware.selected[.output] == 4,
                  "Crash recovery did not restore TailView-owned defaults")
        try check(hardware.selected[.systemOutput] == 3,
                  "Crash recovery overwrote a later user selection")
        _ = recovery
        routing.setConnected(false)

        // A failed restore must keep the original snapshot for the next connection.
        hardware.selected = [.input: 1, .output: 4, .systemOutput: 4]
        routing.setConnected(true)
        hardware.rejectWrites = true
        routing.setConnected(false)
        try check(routing.status.contains("Could not restore"), "Restore failure was hidden")
        hardware.rejectWrites = false
        routing.setConnected(true)
        routing.setConnected(false)
        try check(hardware.selected[.input] == 1, "Reconnect lost the pre-session input after a restore failure")

        routing.setConnected(true)
        hardware.available.removeAll { $0.id == 1 }
        hardware.available.append(AudioRouteDevice(id: 101, uid: "mic", name: "Built-in mic",
                                                   hasInput: true, hasOutput: false,
                                                   transport: kAudioDeviceTransportTypeBuiltIn))
        let renumberedRecovery = AudioRoutingController(backend: hardware, defaults: defaults)
        try check(hardware.selected[.input] == 101, "Crash recovery depended on a transient device ID")
        _ = renumberedRecovery
        routing.setConnected(false)

        print("Audio routing smoke passed: ownership, drift, feedback prevention, device loss, restoration, and crash recovery")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
}

private final class FakeAudio: AudioRoutingBackend {
    static let blackHole = AudioRouteDevice(id: 2, uid: "blackhole", name: "BlackHole 2ch",
                                            hasInput: true, hasOutput: true, transport: kAudioDeviceTransportTypeVirtual)
    static let headphones = AudioRouteDevice(id: 3, uid: "headphones", name: "Headphones",
                                             hasInput: false, hasOutput: true, transport: kAudioDeviceTransportTypeUSB)
    var available = [
        AudioRouteDevice(id: 1, uid: "mic", name: "Built-in mic", hasInput: true,
                         hasOutput: false, transport: kAudioDeviceTransportTypeBuiltIn),
        blackHole, headphones,
        AudioRouteDevice(id: 4, uid: "speakers", name: "Speakers", hasInput: false,
                         hasOutput: true, transport: kAudioDeviceTransportTypeBuiltIn)
    ]
    var selected: [AudioDefault: AudioDeviceID] = [.input: 1, .output: 3, .systemOutput: 4]
    var rejectWrites = false
    func devices() throws -> [AudioRouteDevice] { available }
    func defaultDevice(_ kind: AudioDefault) throws -> AudioDeviceID { selected[kind]! }
    func setDefault(_ kind: AudioDefault, device: AudioDeviceID) throws {
        if rejectWrites { throw NSError(domain: "Simulated unavailable device", code: 1) }
        selected[kind] = device
    }
}
