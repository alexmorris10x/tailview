import CryptoKit
import Foundation
import Security

struct PairedDeviceRecord: Codable, Identifiable {
    let id: UUID
    let name: String
    let tokenDigest: String
    let pairedAt: Date
}

final class PairedDeviceStore {
    private let lock = NSLock()
    private let service = "com.10x.tailview.mac.paired-devices"
    private let account = "paired-devices"
    // The last list read or written, used only when the Keychain cannot be
    // read, so a Keychain hiccup cannot lock a paired device out.
    private var cached: [PairedDeviceRecord]?

    func list() throws -> [PairedDeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    func add(id: UUID, name: String, token: String) throws {
        guard PairingRequest.validToken(token) else { throw StoreError.invalidToken }
        lock.lock(); defer { lock.unlock() }
        var devices = try load()
        devices.removeAll { $0.id == id }
        devices.append(PairedDeviceRecord(id: id, name: name,
                                          tokenDigest: Self.digest(token).base64EncodedString(),
                                          pairedAt: Date()))
        try save(devices)
    }

    /// `unavailable` when the list cannot be read, so the device is not told
    /// it was revoked.
    func authenticate(id: UUID, token: String) -> VideoServer.SavedCredentialCheck {
        guard PairingRequest.validToken(token) else { return .rejected }
        lock.lock(); defer { lock.unlock() }
        let devices: [PairedDeviceRecord]
        do { devices = try load() } catch { return .unavailable }
        guard let record = devices.first(where: { $0.id == id }),
              let expected = Data(base64Encoded: record.tokenDigest) else { return .rejected }
        let received = Self.digest(token)
        guard expected.count == received.count else { return .rejected }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ received[index] }
        return difference == 0 ? .accepted : .rejected
    }

    func revoke(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var devices = try load()
        devices.removeAll { $0.id == id }
        try save(devices)
    }

    private static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load() throws -> [PairedDeviceRecord] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { cached = []; return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            if let cached { return cached }
            throw StoreError.keychain(status)
        }
        let devices = try JSONDecoder().decode([PairedDeviceRecord].self, from: data)
        cached = devices
        return devices
    }

    private func save(_ devices: [PairedDeviceRecord]) throws {
        let data = try JSONEncoder().encode(devices)
        let status = SecItemUpdate(query() as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query()
            request[kSecValueData as String] = data
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
        cached = devices
    }

    enum StoreError: LocalizedError {
        case invalidToken, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidToken: return "The pairing credential is invalid"
            case .keychain(let status): return "Keychain failed (\(status))"
            }
        }
    }
}
