import Foundation

/// Helpers for H.264/H.265 bitstreams.
///
/// Android's MediaCodec produces **Annex-B**: NAL units separated by start
/// codes (`00 00 01` or `00 00 00 01`). Apple's VideoToolbox wants **AVCC/HVCC**:
/// every NAL unit prefixed by its 4-byte big-endian length. These functions
/// convert between the two without trusting the input.
enum AnnexB {
    /// Splits an Annex-B buffer into NAL units (start codes removed).
    static func split(_ data: Data) -> [ArraySlice<UInt8>] {
        let bytes = [UInt8](data)
        let count = bytes.count
        var starts: [(codeStart: Int, nalStart: Int)] = []
        var index = 0
        while index + 2 < count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let codeStart = (index > 0 && bytes[index - 1] == 0) ? index - 1 : index
                starts.append((codeStart, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        var units: [ArraySlice<UInt8>] = []
        units.reserveCapacity(starts.count)
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1].codeStart : count
            if end > start.nalStart {
                units.append(bytes[start.nalStart..<end])
            }
        }
        return units
    }

    /// Joins NAL units into one AVCC buffer (4-byte big-endian length prefixes).
    static func avcc(_ units: [ArraySlice<UInt8>]) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { output.append(contentsOf: $0) }
            output.append(contentsOf: unit)
        }
        return output
    }
}

/// NAL unit types that matter to the decoder.
enum NalKind {
    case parameterSet
    case keyframe
    case frame
    case ignorable // access unit delimiters, filler data

    static func of(_ unit: ArraySlice<UInt8>, hevc: Bool) -> NalKind {
        guard let header = unit.first else { return .ignorable }
        if hevc {
            switch (header >> 1) & 0x3F {
            case 32, 33, 34: return .parameterSet // VPS, SPS, PPS
            case 16...21: return .keyframe // BLA, IDR, CRA
            case 35, 38: return .ignorable // AUD, filler
            default: return .frame
            }
        }
        switch header & 0x1F {
        case 7, 8: return .parameterSet // SPS, PPS
        case 5: return .keyframe // IDR
        case 9, 12: return .ignorable // AUD, filler
        default: return .frame
        }
    }

    /// Specific parameter-set type, for picking VPS/SPS/PPS out of a config buffer.
    static func parameterSetType(_ unit: ArraySlice<UInt8>, hevc: Bool) -> Int {
        guard let header = unit.first else { return -1 }
        return hevc ? Int((header >> 1) & 0x3F) : Int(header & 0x1F)
    }
}
