import Foundation
import JWTKit

/// Helpers for loading Cloudflare Access public keys from the team JWKS endpoint.
public enum CfAccessKeys {
    /// The Cloudflare Access JWKS endpoint for a team.
    ///
    /// - Parameter team: The Zero Trust team name (e.g. `myteam` for `myteam.cloudflareaccess.com`).
    /// - Throws: `CfAccessKeysError.invalidTeam` if the team name contains characters that break URL parsing.
    public static func certsURL(team: String) throws -> URL {
        guard let url = URL(string: "https://\(team).cloudflareaccess.com/cdn-cgi/access/certs") else {
            throw CfAccessKeysError.invalidTeam(team)
        }
        return url
    }

    /// Build a key collection from a JWKS JSON string.
    ///
    /// This is a pure function (no network) — suitable for unit testing. The
    /// keys are loaded via `JWTKeyCollection.add(jwksJSON:)`, which decodes
    /// the JWKS and registers each key by its `kid`.
    ///
    /// - Parameter json: A JSON string containing a JWKS (`{"keys": [...]}`).
    /// - Throws: If the JSON cannot be decoded or any key cannot be parsed.
    /// - Returns: A populated `JWTKeyCollection` ready to verify tokens.
    public static func keyCollection(fromJWKSJSON json: String) async throws -> JWTKeyCollection {
        let keys = JWTKeyCollection()
        try await keys.add(jwksJSON: json)
        return keys
    }

    /// Fetch the team JWKS over the network and build a key collection.
    ///
    /// Throws on any network error, non-2xx HTTP response, or JWKS parse
    /// failure. Callers must fail-closed: deny all requests if this throws.
    ///
    /// - Parameter team: The Zero Trust team name.
    /// - Throws: `CfAccessKeysError` with diagnostic context on failure; JSON
    ///   parse errors from `JWTKeyCollection.add(jwksJSON:)` propagate as-is.
    /// - Returns: A populated `JWTKeyCollection` loaded with the team's public keys.
    public static func fetch(team: String) async throws -> JWTKeyCollection {
        let url = try certsURL(team: team)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CfAccessKeysError.fetchFailed(status: statusCode)
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw CfAccessKeysError.decodeFailed
        }
        return try await keyCollection(fromJWKSJSON: json)
    }
}

public enum CfAccessKeysError: Error, CustomStringConvertible {
    case invalidTeam(String)
    case fetchFailed(status: Int)
    case decodeFailed

    public var description: String {
        switch self {
        case .invalidTeam(let t):
            return "invalid Cloudflare team name: \(t)"
        case .fetchFailed(let s):
            return "Cloudflare JWKS fetch failed (HTTP \(s))"
        case .decodeFailed:
            return "Cloudflare JWKS response was not valid UTF-8/JSON"
        }
    }
}
