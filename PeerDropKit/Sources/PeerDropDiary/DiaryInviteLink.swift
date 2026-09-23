import Foundation

/// Parses `peerdrop://diary/<diaryId>?code=<inviteCode>#k=<base64url key>`
/// deep links (spec §3.2). Extracted out of `DiaryStore` (review round 1,
/// minor) so Task 6's deep-link handling (iOS `PeerDropApp.swift`, Mac
/// `MacDeepLinkHandler.swift`) can call `parse(_:)` directly without going
/// through a `DiaryStore` instance.
public enum DiaryInviteLink {
    /// nil for a structurally invalid link — wrong host, missing/empty id,
    /// or missing/empty `code` query item — anything needed just to CALL
    /// the join API. A missing or malformed `#k=` key fragment resolves to
    /// `key: nil` in an otherwise-valid result rather than nil-ing the
    /// whole parse: the fragment never reaches the server, so it must
    /// never be able to block the join itself (`DiaryStore.performJoin`
    /// treats a nil/wrong key as "leave this diary `pendingKey`", not as a
    /// reason to refuse the join).
    public static func parse(_ url: URL) -> (diaryId: String, code: String, key: Data?)? {
        guard url.host == "diary" else { return nil }
        let diaryId = url.pathComponents.first { $0 != "/" } ?? ""
        guard !diaryId.isEmpty else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        var key: Data?
        if let fragment = url.fragment, fragment.hasPrefix("k=") {
            key = Data(base64URLEncoded: String(fragment.dropFirst(2)))
        }
        return (diaryId, code, key)
    }

    /// Safe to write to any log: scheme + host ONLY — never the query
    /// (`code`) or fragment (`key`), per the global constraint "任何 log
    /// 不得含 query／fragment".
    public static func logSafeDescription(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? "")"
    }
}

extension Data {
    /// Base64url (RFC 4648 §5) decode — the diary invite link's `#k=`
    /// fragment uses this alphabet (URL-safe, no padding required in the
    /// link itself). `internal` — used by `DiaryInviteLink` only.
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }

    /// The encode side of `init?(base64URLEncoded:)` — used by
    /// `DiaryStore.inviteLink(for:)` to embed the content key in a
    /// `#k=` fragment. No padding (matches how a link's fragment is
    /// written; the decoder above re-pads before doing the actual
    /// base64 decode).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
