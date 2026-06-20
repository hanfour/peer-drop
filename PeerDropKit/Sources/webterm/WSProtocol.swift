import Foundation

/// WebSocket binary framing: first byte is a tag.
///  0x00 data  (rest = raw terminal bytes, both directions)
///  0x01 resize (payload = cols:UInt16 BE, rows:UInt16 BE)
///  0x02 ping
public enum WSFrame: Equatable {
    case data(Data)
    case resize(cols: UInt16, rows: UInt16)
    case ping

    public func encoded() -> Data {
        switch self {
        case .data(let d): return Data([0x00]) + d
        case .resize(let cols, let rows):
            var out = Data([0x01])
            out.append(UInt8(cols >> 8)); out.append(UInt8(cols & 0xff))
            out.append(UInt8(rows >> 8)); out.append(UInt8(rows & 0xff))
            return out
        case .ping: return Data([0x02])
        }
    }

    public static func decode(_ frame: Data) -> WSFrame? {
        guard let tag = frame.first else { return nil }
        let body = frame.dropFirst()
        switch tag {
        case 0x00: return .data(Data(body))
        case 0x01:
            guard body.count == 4 else { return nil }
            let b = Array(body)
            return .resize(cols: UInt16(b[0]) << 8 | UInt16(b[1]),
                           rows: UInt16(b[2]) << 8 | UInt16(b[3]))
        case 0x02: return .ping
        default: return nil
        }
    }
}
