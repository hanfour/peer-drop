import Foundation

/// Flat-string identifier for a pet species variant, e.g. `"cat-tabby"`, `"slime-fire"`,
/// `"octopus"`. Splits on the first hyphen: prefix is the family ("cat"), suffix is the
/// sub-variety ("tabby"). Single-token IDs (no hyphen) carry a nil variant — used by
/// legacy single-variety species like `octopus`, `bird`, `frog`.
///
/// Codable as a plain string (single-value container) so persisted/network payloads stay
/// compact: `{"id":"cat-tabby"}` rather than `{"id":{"rawValue":"cat-tabby"}}`.
public struct SpeciesID: Hashable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var family: String {
        guard let dash = rawValue.firstIndex(of: "-") else { return rawValue }
        return String(rawValue[..<dash])
    }

    public var variant: String? {
        guard let dash = rawValue.firstIndex(of: "-") else { return nil }
        return String(rawValue[rawValue.index(after: dash)...])
    }
}

extension SpeciesID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
