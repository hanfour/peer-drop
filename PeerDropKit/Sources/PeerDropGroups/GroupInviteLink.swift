import Foundation

/// Builds and parses the key-free group invite URL.
public enum GroupInviteLink {
    private static let groupIdPattern = "^[0-9A-HJKMNP-TV-Z]{26}$"

    /// Parses `peerdrop://group/<groupId>?code=<inviteCode>` or returns nil for an invalid link.
    public static func parse(_ url: URL) -> (groupId: String, code: String)? {
        guard url.scheme == "peerdrop", url.host == "group", url.user == nil, url.password == nil, url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.first == "/" else { return nil }
        let encodedId = String(components.percentEncodedPath.dropFirst())
        guard !encodedId.contains("/"), let groupId = encodedId.removingPercentEncoding,
              groupId.range(of: groupIdPattern, options: .regularExpression) != nil,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return nil }
        return (groupId, code)
    }

    /// Creates a key-free group invite URL.
    public static func make(groupId: String, code: String) -> URL {
        var components = URLComponents()
        components.scheme = "peerdrop"
        components.host = "group"
        components.path = "/\(groupId)"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// Returns a description safe for logs that excludes the group id and invite code.
    public static func logSafeDescription(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? "")"
    }
}
