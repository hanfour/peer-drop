import Foundation

/// 8-character Crockford base32 account identifier issued by the worker.
public struct AccountID: Hashable, Codable, Sendable {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public let raw: String

    /// Strict: `raw` must already be 8 uppercase alphabet characters.
    public init?(raw: String) {
        guard raw.count == 8, raw.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.raw = raw
    }

    /// Lenient user-input parser: strips hyphens/whitespace, uppercases, maps I/L→1 and O→0.
    public static func parse(_ input: String) -> AccountID? {
        var cleaned = ""
        for ch in input.uppercased() where ch != "-" && !ch.isWhitespace {
            switch ch {
            case "I", "L": cleaned.append("1")
            case "O": cleaned.append("0")
            default: cleaned.append(ch)
            }
        }
        return AccountID(raw: cleaned)
    }

    public var display: String { raw.prefix(4) + "-" + raw.suffix(4) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = AccountID(raw: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid account id \(s)"))
        }
        self = id
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}
