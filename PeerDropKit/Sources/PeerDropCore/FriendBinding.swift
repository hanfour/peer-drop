import Foundation
import PeerDropSecurity

/// What the resolver knows about a live connection for a chat peer id.
public enum LiveConnectionKey: Equatable {
    /// No live connection with this id.
    case none
    /// Connected but without a secure channel (legacy/relay): no handshake key.
    case unsecured
    /// Secured; the handshake peer identity key.
    case secured(Data)
}

/// Pure resolution of a chat `peerID` to the one `TrustedContact` it means.
/// Never guesses: ambiguity, a blocked contact, a duplicated key or an
/// unsecured live connection all yield nil.
///
/// Known limitation: `DeviceRecordStore` folds same-name records without
/// leaving a marker, so a name merge cannot be detected here. Resolution is
/// per identity (handshake key / `PeerIdentity.id` on the contact), never per
/// display name or `DeviceRecord`, so a merged record cannot redirect a
/// binding to another identity.
public enum FriendBindingResolver {
    public static func resolve(peerID: String, live: LiveConnectionKey, contacts: [TrustedContact]) -> TrustedContact? {
        func unique(_ matches: [TrustedContact]) -> TrustedContact? {
            guard matches.count == 1, let c = matches.first, !c.isBlocked else { return nil }
            return c
        }
        switch live {
        case .secured(let key):
            // The handshake key is authoritative; never fall back to ids.
            return unique(contacts.filter { $0.matchesKey(key) })
        case .unsecured:
            // Threads bind only to a secured identity.
            return nil
        case .none:
            // PeerIdentity.id stored on the contact (NOT record.peerDeviceId,
            // a relay-only DeviceIdentity id), and its key must be unique.
            guard let c = unique(contacts.filter { $0.deviceId == peerID }) else { return nil }
            guard contacts.filter({ $0.matchesKey(c.identityPublicKey) }).count == 1 else { return nil }
            return c
        }
    }
}

/// A friend whose notes-account binding is verified (no pending claim).
public struct VerifiedAccount: Equatable {
    public let accountId: String
    public let contactID: UUID
    public let identityKey: Data
}

/// Resolves the friend (and notes account) behind a chat thread.
@MainActor
public final class FriendBinding {
    private let contacts: () -> [TrustedContact]
    private let live: (String) -> LiveConnectionKey

    public init(contacts: @escaping () -> [TrustedContact], live: @escaping (String) -> LiveConnectionKey) {
        self.contacts = contacts
        self.live = live
    }

    public convenience init(connectionManager cm: ConnectionManager) {
        self.init(contacts: { [weak cm] in cm?.trustedContactStore.contacts ?? [] },
                  live: { [weak cm] id in
                      guard let pc = cm?.connection(for: id) else { return .none }
                      if let key = pc.handshakePeerIdentityKey { return .secured(key) }
                      return .unsecured
                  })
    }

    public func contact(forChatPeerID peerID: String) -> TrustedContact? {
        FriendBindingResolver.resolve(peerID: peerID, live: live(peerID), contacts: contacts())
    }

    /// Non-nil only when `accountId != nil && pendingAccountBinding == nil`,
    /// so a stale account id is never returned while a claim is pending.
    public func verifiedAccount(forChatPeerID peerID: String) -> VerifiedAccount? {
        guard let c = contact(forChatPeerID: peerID), let accountId = c.accountId, c.pendingAccountBinding == nil else { return nil }
        return VerifiedAccount(accountId: accountId, contactID: c.id, identityKey: c.identityPublicKey)
    }

    /// `.pending` whenever a pending claim exists, even if an older account id
    /// is still stored: a re-exchange in progress locks the thread
    /// conservatively. `.verified` only for accountId != nil and no pending.
    public func bindingState(forChatPeerID peerID: String) -> BindingState {
        guard let c = contact(forChatPeerID: peerID) else { return .none }
        if c.pendingAccountBinding != nil { return .pending }
        return c.accountId != nil ? .verified : .none
    }
}
