import XCTest
@testable import PeerDropSecurity

/// Regression coverage for the Mac ↔ iOS TLS asymmetry (2026-06-12):
///
/// CertificateManager never creates a certificate, so its
/// `kSecClassIdentity` lookup is *expected* to find nothing and leave
/// `identity == nil` — that keeps both sides of a connection on the same
/// (plain-TCP) framing. On iOS that held. On macOS the file-based login
/// keychain ignores `kSecAttrApplicationTag` for identity queries and
/// returned the *user's own codesigning identity* (e.g. "Apple
/// Development: …"), flipping the Mac side to TLS while iOS stayed plain:
/// the iOS MessageFramer then read the TLS ClientHello header (0x16030302)
/// as an app frame length and every Mac → iPhone connection timed out.
///
/// The fix scopes both the add and the lookup to the data-protection
/// keychain (`kSecUseDataProtectionKeychain`), which enforces strict
/// attribute matching on macOS exactly like iOS.
final class CertificateManagerIdentityTests: XCTestCase {

    func testFreshManagerHasNoIdentityWithoutStoredCertificate() {
        let manager = CertificateManager()
        // Fingerprint must exist (TOFU verification depends on it)…
        XCTAssertNotNil(manager.fingerprint, "ephemeral key + fingerprint should always be derivable")
        XCTAssertTrue(manager.isReady)
        // …but identity must be nil: no certificate was ever created, so any
        // non-nil value here is a foreign identity leaked from the host
        // keychain — the exact failure that made Mac speak TLS to a
        // plain-TCP iOS listener.
        XCTAssertNil(
            manager.identity,
            "identity query must not match foreign keychain identities (macOS tag-ignore leak)")
    }
}
