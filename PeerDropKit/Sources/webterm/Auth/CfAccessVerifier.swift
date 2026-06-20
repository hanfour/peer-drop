import Foundation
import JWTKit

/// Validates a Cloudflare Access JWT: signature (via the team JWKS / injected
/// keys), audience (the Access app AUD tag), expiry, and the email claim.
public struct CfAccessVerifier {
    struct Claims: JWTPayload {
        let aud: AudienceClaim
        let email: String
        let exp: ExpirationClaim
        func verify(using algorithm: some JWTAlgorithm) throws { try exp.verifyNotExpired() }
    }

    let audience: String
    let ownerEmail: String
    let keys: JWTKeyCollection

    public init(audience: String, ownerEmail: String, keys: JWTKeyCollection) {
        self.audience = audience
        self.ownerEmail = ownerEmail
        self.keys = keys
    }

    /// In production, build `keys` from the team JWKS:
    ///   let keys = JWTKeyCollection()
    ///   try await keys.add(jwks: <fetched certs json>)
    /// The JWKS fetch/caching from
    ///   https://<team>.cloudflareaccess.com/cdn-cgi/access/certs
    /// is wired in a later task's composition root, not here.
    public func verify(_ token: String) async throws -> String {
        let claims = try await keys.verify(token, as: Claims.self)
        guard claims.aud.value.contains(audience) else { throw CfAccessError.badAudience }
        guard claims.email.lowercased() == ownerEmail.lowercased() else { throw CfAccessError.badEmail }
        return claims.email
    }
}

public enum CfAccessError: Error { case badAudience, badEmail }
