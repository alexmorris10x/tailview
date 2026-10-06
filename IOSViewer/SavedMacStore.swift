import Foundation
import Security

struct SavedMac: Codable, Identifiable {
    let id: UUID
    var name: String
    var address: String
    let token: String
}

enum SavedMacStore {
    // Keep existing Release records; Dev has its own service and app access group.
    private static let service: String = {
        guard let bundleID = Bundle.main.bundleIdentifier,
              ["com.10x.tailview.ios", "com.10x.tailview.ios.dev"].contains(bundleID) else {
            preconditionFailure("Invalid TailView iOS identity configuration")
        }
        return bundleID + ".saved-macs"
    }()
    private static let account = "saved-macs"

    static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func load() throws -> [SavedMac] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError.keychain(status) }
        return try JSONDecoder().decode([SavedMac].self, from: data)
    }

    static func save(_ profiles: [SavedMac]) throws {
        let data = try JSONEncoder().encode(profiles)
        let status = SecItemUpdate(query() as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query()
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? {
            switch self { case .keychain(let status): return "Keychain failed (\(status))" }
        }
    }
}
