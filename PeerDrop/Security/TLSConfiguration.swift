import Foundation
import Network
import Security
import CryptoKit

/// Creates NWProtocolTLS.Options with certificate pinning for peer connections.
enum TLSConfiguration {
    /// Create TLS options for the listener (server role) with the local certificate.
    static func serverOptions(identity: SecIdentity) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        sec_protocol_options_set_local_identity(
            options.securityProtocolOptions,
            sec_identity_create(identity)!
        )

        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv12
        )

        // Accept any client certificate (trust-on-first-use)
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trust, complete in
                complete(true)
            },
            DispatchQueue.global()
        )

        return options
    }

    /// Create TLS options for the client with optional certificate pinning.
    static func clientOptions(
        identity: SecIdentity?,
        expectedFingerprint: String? = nil
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        if let identity {
            sec_protocol_options_set_local_identity(
                options.securityProtocolOptions,
                sec_identity_create(identity)!
            )
        }

        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions,
            .TLSv12
        )

        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { metadata, trust, complete in
                if let expectedFingerprint {
                    // Verify certificate fingerprint matches
                    let verified = verifyFingerprint(
                        metadata: metadata,
                        trust: trust,
                        expected: expectedFingerprint
                    )
                    complete(verified)
                } else {
                    // Trust-on-first-use: accept any certificate
                    complete(true)
                }
            },
            DispatchQueue.global()
        )

        return options
    }

    /// Verify the peer's certificate fingerprint.
    private static func verifyFingerprint(
        metadata: sec_protocol_metadata_t,
        trust: sec_trust_t,
        expected: String
    ) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        guard let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let cert = certChain.first else {
            return false
        }

        let data = SecCertificateCopyData(cert) as Data
        let hash = SHA256.hash(data: data)
        let fingerprint = hash.map { String(format: "%02x", $0) }.joined()
        return fingerprint == expected.lowercased()
    }
}
