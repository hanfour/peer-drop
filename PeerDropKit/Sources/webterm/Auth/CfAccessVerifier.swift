import Foundation
import JWTKit

/// Validates a Cloudflare Access JWT: signature (via the team JWKS / injected
/// keys), audience (the Access app AUD tag), expiry, and the email claim.
public struct CfAccessVerifier: Sendable {
    struct Claims: JWTPayload {
        let aud: AudienceClaim
        let email: String
        let exp: ExpirationClaim
        func verify(using algorithm: some JWTAlgorithm) throws { try exp.verifyNotExpired() }
    }

    let audience: String
    let ownerEmail: String
    /// The swappable key source. Accessible within the module so main.swift can hand it
    /// to the periodic refresher.
    let source: CfAccessKeySource

    /// Backward-compatible initialiser — wraps the provided key collection in a
    /// CfAccessKeySource. Existing callers (tests, main.swift) compile unchanged.
    public init(audience: String, ownerEmail: String, keys: JWTKeyCollection) {
        self.audience = audience
        self.ownerEmail = ownerEmail
        self.source = CfAccessKeySource(keys)
    }

    public func verify(_ token: String) async throws -> String {
        let keys = await source.current()
        let claims = try await keys.verify(token, as: Claims.self)
        guard claims.aud.value.contains(audience) else { throw CfAccessError.badAudience }
        guard claims.email.lowercased() == ownerEmail.lowercased() else { throw CfAccessError.badEmail }
        return claims.email
    }
}

public enum CfAccessError: Error { case badAudience, badEmail }
