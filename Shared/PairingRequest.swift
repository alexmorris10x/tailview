import Foundation

enum PairingRequest {
    case session(code: String)
    case authenticate(id: UUID, token: String)
    case pair(code: String, id: UUID, token: String, deviceName: String)

    static let maximumLineBytes = 256

    var line: String {
        switch self {
        case .session(let code):
            return "\(code)\n"
        case .authenticate(let id, let token):
            return "AUTH \(id.uuidString.lowercased()) \(token)\n"
        case .pair(let code, let id, let token, let deviceName):
            let shortName = String(deviceName.prefix(16))
            let encodedName = Data(shortName.utf8).base64EncodedString()
            return "PAIR \(code) \(id.uuidString.lowercased()) \(token) \(encodedName)\n"
        }
    }

    static func parse(_ line: String) -> PairingRequest? {
        guard !line.isEmpty, line.utf8.count < maximumLineBytes else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if fields.count == 1, validCode(fields[0]) { return .session(code: fields[0]) }
        if fields.count == 3, fields[0] == "AUTH",
           let id = UUID(uuidString: fields[1]), validToken(fields[2]) {
            return .authenticate(id: id, token: fields[2])
        }
        if fields.count == 5, fields[0] == "PAIR", validCode(fields[1]),
           let id = UUID(uuidString: fields[2]), validToken(fields[3]),
           let nameData = Data(base64Encoded: fields[4]), nameData.count <= 64,
           let name = String(data: nameData, encoding: .utf8) {
            let sanitized = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitized.isEmpty else { return nil }
            return .pair(code: fields[1], id: id, token: fields[3], deviceName: String(sanitized.prefix(32)))
        }
        return nil
    }

    static func validCode(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    static func validToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
