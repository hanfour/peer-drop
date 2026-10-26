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

public enum GroupBackground: Codable, Equatable {
    case preset(String)
    case custom(Data)
}

public enum GroupLimits {
    public static let nameScalars = 30
    public static let descriptionScalars = 200
    public static let nicknameScalars = 20
    public static let messageScalars = 4_000
    public static let photoBytes = 128 * 1024
    public static let customBackgroundBytes = 256 * 1024
    public static let metaBytes = 400 * 1024
}
