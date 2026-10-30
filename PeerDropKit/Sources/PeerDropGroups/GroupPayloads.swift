import Foundation

public struct GroupMessagePayload: Codable, Equatable {
    public enum Kind: String, Codable, Equatable {
        case text
        case identity
    }

    public var kind: Kind
    public var text: String?
    public var nickname: String?

    public init(kind: Kind, text: String? = nil, nickname: String? = nil) {
        self.kind = kind
        self.text = text
        self.nickname = nickname
    }
}

public struct GroupMetaPlaintext: Codable, Equatable {
    public var name: String
    public var description: String?
    public var category: String?
    public var photo: Data?
    public var background: GroupBackground?

    private enum CodingKeys: String, CodingKey { case name, description, category, photo, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        photo = try c.decodeIfPresent(Data.self, forKey: .photo)
        // A background from a newer client must not hide the rest of the meta.
        background = try? c.decodeIfPresent(GroupBackground.self, forKey: .background)
    }

    public init(
        name: String,
        description: String? = nil,
        category: String? = nil,
        photo: Data? = nil,
        background: GroupBackground? = nil
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.photo = photo
        self.background = background
    }
}

/// Stored inside the encrypted meta blob, so the wire shape is permanent:
/// `{"type":"preset","value":"<id>"}` or `{"type":"custom","value":"<base64>"}`.
/// A `type` this build does not know decodes as `nil` in `GroupMetaPlaintext`
/// instead of failing the whole meta (the group name must stay readable).
public enum GroupBackground: Codable, Equatable {
    case preset(String)
    case custom(Data)

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "preset": self = .preset(try c.decode(String.self, forKey: .value))
        case "custom": self = .custom(try c.decode(Data.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown background type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let id):
            try c.encode("preset", forKey: .type)
            try c.encode(id, forKey: .value)
        case .custom(let data):
            try c.encode("custom", forKey: .type)
            try c.encode(data, forKey: .value)
        }
    }
}

/// Size limits shared with the Worker (`GROUP_LIMITS`) and the product spec.
/// Note the ciphertext of one message is also capped at 8 KiB on the server,
/// so CJK text (about 3 bytes per scalar in the JSON envelope) tops out near
/// 2,700 scalars before the 4,000-scalar cap is reachable: UI code must
/// pre-check the encoded size. `photoBytes`/`customBackgroundBytes` count raw
/// bytes; base64 inflates them by about 4/3 inside the `metaBytes` budget.
public enum GroupLimits {
    public static let nameScalars = 30
    public static let descriptionScalars = 200
    public static let nicknameScalars = 20
    public static let messageScalars = 4_000
    public static let photoBytes = 128 * 1024
    public static let customBackgroundBytes = 256 * 1024
    public static let metaBytes = 400 * 1024
}
