import Foundation

public enum NicknameValidation: Equatable {
    case ok(String)
    case tooShort
    case tooLong
    case invalidCharacters
    case reserved
}

public enum Nickname {
    public static let reserved: Set<String> = ["admin", "peerdrop", "support", "system", "null", "me"]
    public static let minLength = 3
    public static let maxLength = 20

    /// Validates a user-supplied nickname. Normalizes to NFC first so a
    /// base letter followed by a combining mark (e.g. "e" + U+0301) is
    /// treated as the single precomposed letter ("é") both for length
    /// counting and for the character-class check below.
    public static func validate(_ raw: String) -> NicknameValidation {
        let value = raw.precomposedStringWithCanonicalMapping   // NFC
        let scalars = value.unicodeScalars
        if scalars.count < minLength { return .tooShort }
        if scalars.count > maxLength { return .tooLong }
        for scalar in scalars {
            let isUnderscore = scalar == "_"
            let isLetterOrNumber = scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            guard isUnderscore || isLetterOrNumber else { return .invalidCharacters }
        }
        if reserved.contains(value.lowercased()) { return .reserved }
        return .ok(value)
    }
}
