import Foundation

/// The MirrorCast wire protocol (version 1). Must stay in sync with `Wire.kt`
/// on Android and with `docs/PROTOCOL.md`.
///
/// Every message is a packet with a 14-byte big-endian header:
///
///     offset size field
///     0      1    type     (see `PacketType`)
///     1      1    flags    (bit 0 = keyframe)
///     2      8    ptsUs    presentation timestamp in microseconds
///     10     4    length   payload length in bytes
///     14     N    payload
enum Wire {
    static let protocolVersion = 1
    static let headerSize = 14
    static let flagKeyframe: UInt8 = 0x01

    static let maxControlPayload = 64 * 1024
    static let maxAudioPayload = 64 * 1024
    static let maxVideoPayload = 8 * 1024 * 1024

    static func maxPayload(for type: PacketType) -> Int {
        switch type {
        case .videoConfig, .videoFrame: return maxVideoPayload
        case .audioPCM: return maxAudioPayload
        default: return maxControlPayload
        }
    }
}

enum PacketType: UInt8 {
    // Media (phone -> Mac)
    case videoConfig = 0x00
    case videoFrame = 0x01
    case audioPCM = 0x02

    // Session control
    case hello = 0x10
    case welcome = 0x11
    case reject = 0x12
    case videoFormat = 0x13
    case audioState = 0x14
    case keyframeRequest = 0x15
    case ping = 0x16
    case pong = 0x17
    case receiverStats = 0x18
    case bye = 0x19

    // Pairing
    case pairCommit = 0x20
    case pairReveal = 0x21
    case pairProof = 0x22
    case pairResult = 0x23
}

enum SessionIntent: String {
    case stream
    case pairPin = "pair_pin"
    case pairQr = "pair_qr"
}

enum RejectCode: String {
    case notPaired = "not_paired"
    case busy
    case pairingClosed = "pairing_closed"
    case codeMismatch = "code_mismatch"
    case protocolError = "protocol_error"
    case unsupportedVersion = "unsupported_version"
}

enum ProtocolError: Error, CustomStringConvertible {
    case unknownType(UInt8)
    case payloadTooLarge(Int)
    case malformed(String)

    var description: String {
        switch self {
        case .unknownType(let type): return String(format: "Unknown packet type 0x%02x", type)
        case .payloadTooLarge(let size): return "Payload too large (\(size) bytes)"
        case .malformed(let what): return "Malformed data: \(what)"
        }
    }
}

struct PacketHeader {
    let type: PacketType
    let flags: UInt8
    let ptsUs: Int64
    let length: Int

    static func parse(_ data: Data) throws -> PacketHeader {
        guard data.count == Wire.headerSize else { throw ProtocolError.malformed("short header") }
        return try data.withUnsafeBytes { raw -> PacketHeader in
            let typeByte = raw[0]
            guard let type = PacketType(rawValue: typeByte) else { throw ProtocolError.unknownType(typeByte) }
            let flags = raw[1]
            let pts = Int64(bigEndian: raw.loadUnaligned(fromByteOffset: 2, as: Int64.self))
            let length = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 10, as: UInt32.self)))
            guard length <= Wire.maxPayload(for: type) else { throw ProtocolError.payloadTooLarge(length) }
            return PacketHeader(type: type, flags: flags, ptsUs: pts, length: length)
        }
    }

    static func encode(type: PacketType, flags: UInt8, ptsUs: Int64, length: Int) -> Data {
        var data = Data(capacity: Wire.headerSize + length)
        data.append(type.rawValue)
        data.append(flags)
        withUnsafeBytes(of: ptsUs.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(length).bigEndian) { data.append(contentsOf: $0) }
        return data
    }
}

struct Packet {
    let type: PacketType
    let flags: UInt8
    let ptsUs: Int64
    let payload: Data

    var isKeyframe: Bool { flags & Wire.flagKeyframe != 0 }

    /// Parses the payload of a control packet as a JSON object.
    func json() throws -> [String: Any] { try Control.decode(payload) }
}

/// JSON helpers for control payloads.
enum Control {
    static func encode(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
    }

    static func decode(_ payload: Data) throws -> [String: Any] {
        if payload.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: payload, options: []),
              let dictionary = object as? [String: Any]
        else { throw ProtocolError.malformed("control message") }
        return dictionary
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Reads a string field, trimmed and length-limited (input from the network is never trusted).
    func string(_ key: String, maxLength: Int = 64) -> String? {
        guard let value = self[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { character in
                !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxLength))
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        if let value = self[key] as? NSNumber { return value.int64Value }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        return nil
    }
}
