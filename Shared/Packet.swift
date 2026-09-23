import Foundation

enum PacketKind: UInt8 {
    case jpeg = 1
    case microphone = 2
    case control = 3
    case controlState = 4
}

enum Packet {
    static func encode(_ kind: PacketKind, _ payload: Data) -> Data {
        var result = Data([kind.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }
}

final class PacketParser {
    private var buffer = Data()

    func append(_ data: Data, onPacket: (PacketKind, Data) -> Void) throws {
        buffer.append(data)
        while buffer.count >= 5 {
            guard let kind = PacketKind(rawValue: buffer[buffer.startIndex]) else { throw PacketError.invalidKind }
            let offset = buffer.startIndex
            let length = (UInt32(buffer[offset + 1]) << 24)
                | (UInt32(buffer[offset + 2]) << 16)
                | (UInt32(buffer[offset + 3]) << 8)
                | UInt32(buffer[offset + 4])
            let limit: UInt32
            switch kind {
            case .jpeg: limit = 2_000_000
            case .microphone: limit = 65_536
            case .control: limit = 1_024
            case .controlState: limit = 1
            }
            guard length > 0, length <= limit else { throw PacketError.invalidLength }
            let total = 5 + Int(length)
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(in: (offset + 5)..<(offset + total))
            buffer.removeSubrange(offset..<(offset + total))
            onPacket(kind, payload)
        }
    }

    enum PacketError: Error { case invalidKind, invalidLength }
}
