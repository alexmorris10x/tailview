import Foundation

enum PacketKind: UInt8 {
    case jpeg = 1
    case microphone = 2
    case control = 3
    case controlState = 4
    case macAudio = 5
    case microphoneState = 6
    case microphoneRequest = 7
    /// Viewer to Mac screen-frame flow control; see VideoFlow.
    case videoFlow = 8
    /// One byte of feature bits, such as AACAudio.capability. A viewer sends
    /// it after sign-in; the Mac replies only to viewers that sent it.
    case capabilities = 9
    /// One AAC packet of mono microphone audio, after both sides offered AAC.
    case microphoneAAC = 10
    /// One AAC packet of stereo Mac sound, after both sides offered AAC.
    case macAudioAAC = 11
    /// Viewer to Mac: text to paste; see ClipboardPaste.
    case paste = 12
}

/// Text from the viewer's clipboard, which the Mac puts on its own clipboard
/// as plain text and pastes with Command-V. Typing long text key by key is
/// slow and can garble it. Macs that accept it set `capability` in their
/// capabilities reply; older Macs close the connection on an unknown packet,
/// so a viewer never sends one to a Mac that didn't offer it.
enum ClipboardPaste {
    static let capability: UInt8 = 2
    static let maximumBytes = 1_048_576

    /// UTF-8 text, or nil if it is empty or over the size cap.
    static func encode(_ text: String) -> Data? {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        return data
    }

    static func decode(_ payload: Data) -> String? {
        guard !payload.isEmpty, payload.count <= maximumBytes else { return nil }
        return String(data: payload, encoding: .utf8)
    }
}

/// A viewer that sends any videoFlow packet receives screen frames only
/// against credits: one per acknowledged frame, refilled on resume. Keeping
/// few frames in flight stops stale frames queueing in the TCP send buffer,
/// so the newest frame goes out next. Older viewers never send it.
enum VideoFlow: UInt8 {
    /// Stop sending frames, for example while the viewer is in the background.
    case pause = 0
    /// One screen frame arrived.
    case received = 1
    /// Start or restart frames and send the latest one now.
    case resume = 2
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
            case .macAudio: limit = 65_536
            case .microphoneState: limit = 1
            case .microphoneRequest: limit = 1
            case .videoFlow: limit = 1
            case .capabilities: limit = 1
            case .microphoneAAC, .macAudioAAC: limit = UInt32(AACAudio.maximumPacketBytes)
            case .paste: limit = UInt32(ClipboardPaste.maximumBytes)
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
