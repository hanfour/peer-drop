import XCTest
@testable import webterm

/// Tests for `resolveAuth(from:)` — the environment → auth-mode resolver
/// extracted from `main.swift` so it can be exercised in isolation.
///
/// Security-critical guarantee: with no credentials configured the server must
/// REFUSE to start (throw) rather than fall back to the old, guessable default
/// password ("changeme"). See the fail-closed tests below.
final class AuthConfigTests: XCTestCase {

    // MARK: - Password mode

    func test_passwordHash_returnsPasswordAuth() throws {
        let auth = try resolveAuth(from: ["WEBTERM_PASSWORD_HASH": "pbkdf2$1$abc$def"])
        guard case .password(let hash) = auth else {
            return XCTFail("expected .password, got \(auth)")
        }
        XCTAssertEqual(hash, "pbkdf2$1$abc$def")
    }

    // MARK: - Cloudflare mode

    func test_fullCloudflare_returnsCloudflareAuth() throws {
        let env = [
            "CF_ACCESS_TEAM": "myteam",
            "CF_ACCESS_AUD": "aud123",
            "CF_ACCESS_OWNER_EMAIL": "owner@example.com",
        ]
        let auth = try resolveAuth(from: env)
        guard case .cloudflare(let team, let aud, let email) = auth else {
            return XCTFail("expected .cloudflare, got \(auth)")
        }
        XCTAssertEqual(team, "myteam")
        XCTAssertEqual(aud, "aud123")
        XCTAssertEqual(email, "owner@example.com")
    }

    func test_passwordHash_takesPrecedenceOverCloudflare() throws {
        // Historical priority: WEBTERM_PASSWORD_HASH is checked before CF_ACCESS_*.
        let env = [
            "WEBTERM_PASSWORD_HASH": "pbkdf2$1$abc$def",
            "CF_ACCESS_TEAM": "myteam",
            "CF_ACCESS_AUD": "aud123",
            "CF_ACCESS_OWNER_EMAIL": "owner@example.com",
        ]
        guard case .password = try resolveAuth(from: env) else {
            return XCTFail("password hash must win over cloudflare when both are set")
        }
    }

    // MARK: - Fail-closed (the security fix)

    func test_emptyEnvironment_throwsNoAuthConfigured() {
        XCTAssertThrowsError(try resolveAuth(from: [:])) { error in
            XCTAssertEqual(error as? AuthConfigError, .noAuthConfigured)
        }
    }

    func test_emptyPasswordHash_isTreatedAsUnset() {
        // A set-but-empty hash can never verify; treat it as unconfigured and
        // fail closed with a clear message rather than starting unusable.
        XCTAssertThrowsError(try resolveAuth(from: ["WEBTERM_PASSWORD_HASH": ""])) { error in
            XCTAssertEqual(error as? AuthConfigError, .noAuthConfigured)
        }
    }

    func test_partialCloudflare_throwsIncompleteWithMissingList() {
        // TEAM + AUD present, OWNER_EMAIL missing → must fail closed AND name the
        // exact missing variable, rather than silently defaulting to a password.
        let env = ["CF_ACCESS_TEAM": "myteam", "CF_ACCESS_AUD": "aud123"]
        XCTAssertThrowsError(try resolveAuth(from: env)) { error in
            XCTAssertEqual(error as? AuthConfigError,
                           .incompleteCloudflareConfig(missing: ["CF_ACCESS_OWNER_EMAIL"]))
        }
    }

    func test_partialCloudflare_multipleMissing_listedInStableOrder() {
        let env = ["CF_ACCESS_AUD": "aud123"]  // only AUD present
        XCTAssertThrowsError(try resolveAuth(from: env)) { error in
            XCTAssertEqual(error as? AuthConfigError,
                           .incompleteCloudflareConfig(missing: ["CF_ACCESS_TEAM", "CF_ACCESS_OWNER_EMAIL"]))
        }
    }

    // MARK: - Regression: never the old guessable default

    func test_noConfig_neverReturnsGuessableDefault() {
        // Historically main.swift fell back to PasswordHash.make("changeme").
        // The resolver must now throw instead of returning ANY auth value.
        XCTAssertThrowsError(
            try resolveAuth(from: [:]),
            "resolveAuth must fail closed with no credentials, never return a default password"
        )
    }

    // MARK: - Operator-facing messages are actionable

    func test_errorDescriptions_nameTheEnvVars() {
        XCTAssertTrue(
            AuthConfigError.noAuthConfigured.description.contains("WEBTERM_PASSWORD_HASH"),
            "noAuthConfigured message must tell the operator which env var to set"
        )
        XCTAssertTrue(
            AuthConfigError.incompleteCloudflareConfig(missing: ["CF_ACCESS_OWNER_EMAIL"])
                .description.contains("CF_ACCESS_OWNER_EMAIL"),
            "incompleteCloudflareConfig message must list the missing variable(s)"
        )
    }
}
