import Foundation

enum AuthenticationReply: Equatable {
    case pending, accepted, rejected, unavailable, invalid

    static func parse(_ data: Data, expected: Data, savedCredential: Bool,
                      streamEnded: Bool) -> AuthenticationReply {
        let rejection = Data("NO\n".utf8)
        if savedCredential && rejection.starts(with: data) {
            if data == rejection { return .rejected }
            return streamEnded ? .unavailable : .pending
        }
        guard data.count <= expected.count, expected.starts(with: data) else { return .invalid }
        if streamEnded { return .unavailable }
        return data == expected ? .accepted : .pending
    }
}
