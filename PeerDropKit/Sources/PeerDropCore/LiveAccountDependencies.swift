import Foundation
import DeviceCheck
import PeerDropAccount
import PeerDropPlatform
import PeerDropSecurity
import PeerDropTransport

/// Production `AccountRegistrationDependencies`, backed by `IdentityKeyManager`,
/// `DeviceIdentity`, App Attest, and this device's `MailboxManager`.
///
/// `AccountRegistrationDependencies` requires `Sendable` (so `AccountManager`
/// can hold it as a plain stored property without actor-hopping ceremony),
/// but `MailboxManager` is a plain `@MainActor` class — not itself `Sendable`
/// — so a struct that stores it can't satisfy `Sendable` structurally. Of the
/// two options the task called for (an `@unchecked Sendable` struct, or a
/// `@Sendable () async throws -> String` closure captured on the main
/// actor), `@unchecked Sendable` is the least-warning choice here: a closure
/// alternative would still need to capture the same non-`Sendable`
/// `mailboxManager` reference (just one property deeper), so it trades this
/// one documented `@unchecked` for a second, less visible one hidden inside
/// the closure's capture list. It is sound because every actual access to
/// `mailboxManager` below happens through `await`-ed calls to its
/// `@MainActor`-isolated members (`registerIfNeeded()`, `mailboxId`) — the
/// compiler inserts the actor hop at each call site regardless of the
/// caller's isolation, so cross-actor use is memory-safe even though the
/// struct's `Sendable` conformance can't be checked structurally.
struct LiveAccountDependencies: AccountRegistrationDependencies, @unchecked Sendable {
    let mailboxManager: MailboxManager

    var deviceId: String { DeviceIdentity.deviceId }

    var platform: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    /// App Attest is the only source of self-service Bearer tokens, and it
    /// is unavailable on native macOS (`DCAppAttestService.isSupported ==
    /// false`, verified 2026-09-15 on an M4 running macOS 15.7) as well as
    /// on the Simulator and entitlement-less dev builds.
    var attestSupported: Bool {
        if #available(iOS 14.0, macOS 11.0, *) {
            return DCAppAttestService.shared.isSupported
        } else {
            return false
        }
    }

    /// Registration needs *some* credential, not App Attest specifically:
    /// the worker's key lane (`X-API-Key` + `X-Device-Id`) covers the
    /// surfaces without it — peerdrop-cli, Debug/Simulator builds, and the
    /// shipped Mac app, which bundles its own restricted `MAC_CLIENT_KEY`.
    /// Only a build with neither falls through to `.attestUnsupported`.
    var registrationSupported: Bool {
        attestSupported || WorkerAuthHelper.legacyAPIKey() != nil
    }

    func identityKeys() throws -> (identity: Data, signing: Data) {
        (IdentityKeyManager.shared.publicKey.rawRepresentation, IdentityKeyManager.shared.signingPublicKey.rawRepresentation)
    }

    func sign(_ data: Data) throws -> Data {
        try IdentityKeyManager.shared.sign(data)
    }

    func currentMailbox() async throws -> (id: String, token: String) {
        try await mailboxManager.registerIfNeeded()
        guard let id = await mailboxManager.mailboxId,
              let token = await mailboxManager.mailboxToken else { throw AccountClientError.invalidResponse }
        return (id, token)
    }
}
