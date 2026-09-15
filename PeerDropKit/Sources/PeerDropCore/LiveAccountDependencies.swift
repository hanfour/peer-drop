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

    var attestSupported: Bool {
        if #available(iOS 14.0, macOS 11.0, *) {
            return DCAppAttestService.shared.isSupported
        } else {
            return false
        }
    }

    func identityKeys() throws -> (identity: Data, signing: Data) {
        (IdentityKeyManager.shared.publicKey.rawRepresentation, IdentityKeyManager.shared.signingPublicKey.rawRepresentation)
    }

    func sign(_ data: Data) throws -> Data {
        try IdentityKeyManager.shared.sign(data)
    }

    func currentMailboxId() async throws -> String {
        try await mailboxManager.registerIfNeeded()
        guard let id = await mailboxManager.mailboxId else { throw AccountClientError.invalidResponse }
        return id
    }
}
