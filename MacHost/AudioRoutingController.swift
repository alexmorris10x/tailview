import AppKit
import CoreAudio
import Foundation

enum AudioDefault: String, CaseIterable {
    case input, output, systemOutput

    var selector: AudioObjectPropertySelector {
        switch self {
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .systemOutput: return kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }
}

struct AudioRouteDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let transport: UInt32

    var isBlackHole: Bool { name.localizedCaseInsensitiveContains("BlackHole 2ch") }
    var isPhysicalOutput: Bool {
        hasOutput && !isBlackHole && transport != kAudioDeviceTransportTypeVirtual &&
            transport != kAudioDeviceTransportTypeAggregate
    }
}

protocol AudioRoutingBackend: AnyObject {
    func devices() throws -> [AudioRouteDevice]
    func defaultDevice(_ kind: AudioDefault) throws -> AudioDeviceID
    func setDefault(_ kind: AudioDefault, device: AudioDeviceID) throws
}

/// Owns Mac defaults only after explicit opt-in and while a trusted viewer is connected.
/// Store UIDs rather than transient Core Audio IDs so restoration survives a relaunch.
@MainActor
final class AudioRoutingController {
    private struct Snapshot: Codable {
        var original = [String: String]()
        var managed = [String: String]()
    }

    private static let recoveryKey = "tailview.audioRouteRecovery"
    private let backend: AudioRoutingBackend
    private let defaults: UserDefaults
    private var snapshot: Snapshot?
    private var connected = false
    private var enabled = false
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?
    var onStatus: ((String) -> Void)?
    private(set) var status = "Off · Mac audio selections stay unchanged"

    init(backend: AudioRoutingBackend = CoreAudioRoutingBackend(), defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
        // Repair defaults left by an interrupted session before a new connection.
        if let data = defaults.data(forKey: Self.recoveryKey),
           let previous = try? JSONDecoder().decode(Snapshot.self, from: data) {
            if !restore(previous, onlyIfManaged: true) { snapshot = previous }
        }
        if let coreAudio = backend as? CoreAudioRoutingBackend {
            coreAudio.onChange = { [weak self] in
                MainActor.assumeIsolated { self?.enforce() }
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setConnected(false) }
        }
    }

    deinit {
        timer?.invalidate()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func setConnected(_ enabled: Bool) {
        guard connected != enabled else {
            if enabled { enforce() }
            else if let snapshot, restore(snapshot, onlyIfManaged: false) { self.snapshot = nil }
            return
        }
        connected = enabled
        updateRouting()
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        updateRouting()
    }

    private func updateRouting() {
        timer?.invalidate()
        timer = nil
        if connected && enabled {
            // A watchdog also retries transient failures and missing-device recovery.
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.enforce() }
            }
            enforce()
        } else {
            if let snapshot, restore(snapshot, onlyIfManaged: false) { self.snapshot = nil }
            if snapshot == nil {
                updateStatus(enabled ? "Ready · starts when a paired viewer connects" : "Off · Mac audio selections stay unchanged")
            }
        }
    }

    func enforce() {
        guard connected && enabled else { return }
        do {
            let devices = try backend.devices()
            if snapshot == nil {
                var saved = Snapshot()
                for kind in AudioDefault.allCases {
                    let id = try backend.defaultDevice(kind)
                    saved.original[kind.rawValue] = devices.first { $0.id == id }?.uid
                }
                snapshot = saved
                persist()
            }
            guard let microphone = devices.first(where: { $0.isBlackHole && $0.hasInput }) else {
                throw RoutingError.message("Install BlackHole 2ch to use the remote microphone")
            }
            let currentOutput = try backend.defaultDevice(.output)
            let output = devices.first { $0.uid == snapshot?.managed[AudioDefault.output.rawValue] && $0.isPhysicalOutput }
                ?? devices.first { $0.id == currentOutput && $0.isPhysicalOutput }
                ?? devices.first { $0.isPhysicalOutput && $0.transport == kAudioDeviceTransportTypeBuiltIn }
                ?? devices.first { $0.isPhysicalOutput }
            guard let output else { throw RoutingError.message("Connect speakers or headphones for Mac output") }

            // Move playback away from BlackHole before selecting it as input.
            for (kind, device) in [(AudioDefault.output, output), (.systemOutput, output), (.input, microphone)] {
                if snapshot?.managed[kind.rawValue] != device.uid {
                    snapshot?.managed[kind.rawValue] = device.uid
                    persist() // Journal before writing a global preference.
                }
                if try backend.defaultDevice(kind) != device.id {
                    try backend.setDefault(kind, device: device.id)
                }
                guard try backend.defaultDevice(kind) == device.id else {
                    throw RoutingError.message("macOS did not select \(device.name) for \(kind.rawValue)")
                }
            }
            updateStatus("Enforced · input: \(microphone.name) · output: \(output.name)")
        } catch {
            updateStatus("Audio routing needs attention: \(error.localizedDescription)")
        }
    }

    private func persist() {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.recoveryKey)
        }
    }

    @discardableResult
    private func restore(_ previous: Snapshot, onlyIfManaged: Bool) -> Bool {
        do {
            let devices = try backend.devices()
            for kind in AudioDefault.allCases {
                guard previous.managed[kind.rawValue] != nil,
                      let uid = previous.original[kind.rawValue] else { continue }
                let current = try backend.defaultDevice(kind)
                if onlyIfManaged,
                   devices.first(where: { $0.id == current })?.uid != previous.managed[kind.rawValue] { continue }
                // If a saved headset disappeared, do not leave the remote-only
                // BlackHole input selected after the viewer has gone away.
                let original = devices.first { $0.uid == uid } ?? devices.first {
                    $0.transport == kAudioDeviceTransportTypeBuiltIn &&
                        (kind == .input ? $0.hasInput : $0.hasOutput)
                }
                guard let original else { continue }
                if current != original.id { try backend.setDefault(kind, device: original.id) }
                guard try backend.defaultDevice(kind) == original.id else {
                    throw RoutingError.message("macOS did not restore \(original.name)")
                }
            }
            defaults.removeObject(forKey: Self.recoveryKey)
            updateStatus("Previous Mac audio selections restored")
            return true
        } catch {
            // Keep the journal so a subsequent launch can finish restoration.
            updateStatus("Could not restore Mac audio selections: \(error.localizedDescription)")
            return false
        }
    }

    private func updateStatus(_ value: String) {
        guard status != value else { return }
        status = value
        onStatus?(value)
    }

    private enum RoutingError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}

final class CoreAudioRoutingBackend: AudioRoutingBackend {
    var onChange: (() -> Void)?
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listeners = [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]()

    init() {
        for selector in AudioDefault.allCases.map(\.selector) + [kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
            if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    deinit {
        for (var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, block)
        }
    }

    func defaultDevice(_ kind: AudioDefault) throws -> AudioDeviceID {
        try number(system, kind.selector)
    }

    func setDefault(_ kind: AudioDefault, device: AudioDeviceID) throws {
        var address = Self.address(kind.selector)
        var device = device
        try check(AudioObjectSetPropertyData(system, &address, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &device))
    }

    func devices() throws -> [AudioRouteDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        if !ids.isEmpty {
            try ids.withUnsafeMutableBytes {
                try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!))
            }
        }
        return ids.compactMap { id in
            guard (try? number(id, kAudioDevicePropertyDeviceIsAlive)) == 1,
                  let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  let name = try? string(id, kAudioObjectPropertyName) else { return nil }
            return AudioRouteDevice(id: id, uid: uid, name: name,
                                    hasInput: hasStreams(id, scope: kAudioObjectPropertyScopeInput),
                                    hasOutput: hasStreams(id, scope: kAudioObjectPropertyScopeOutput),
                                    transport: (try? number(id, kAudioDevicePropertyTransportType)) ?? kAudioDeviceTransportTypeVirtual)
        }
    }

    private func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = Self.address(selector)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result))
        return result
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &result) {
            try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer($0)))
        }
        guard let result else { throw AudioError.status(kAudioHardwareUnspecifiedError) }
        return result.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw AudioError.status(status) }
    }

    private enum AudioError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? { if case .status(let code) = self { return "Core Audio error \(code)" }; return nil }
    }
}
