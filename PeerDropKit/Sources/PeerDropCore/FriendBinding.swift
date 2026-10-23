import Foundation
import PeerDropSecurity

/// Pure resolution of a chat `peerID` to the one `TrustedContact` it means.
/// Never guesses: ambiguity, a blocked contact, or a key mismatch yields nil.
public enum FriendBindingResolver {
    public static func resolve(peerID: String,
                               liveHandshakeKey: Data?,
                               contacts: [TrustedContact],
                               records: [DeviceRecord]) -> TrustedContact? {
        func unique(_ matches: [TrustedContact]) -> TrustedContact? {
            guard matches.count == 1, let c = matches.first, !c.isBlocked else { return nil }
            return c
        }
        // 1. A live connection: the handshake key is authoritative. When it is
        //    known, never fall back to id-based lookups (a contact that does
        //    not own this key must not be guessed).
        if let key = liveHandshakeKey {
            return unique(contacts.filter { $0.matchesKey(key) })
        }
        // 2. PeerIdentity.id stored on the contact.
        guard let contact = unique(contacts.filter { $0.deviceId == peerID }) else { return nil }
        // 3. The DeviceRecord with this id (PeerIdentity.id space, NOT
        //    `record.peerDeviceId`, which is a relay-only DeviceIdentity id):
        //    if its name collides with another record (merged by name) the
        //    mapping is ambiguous, so refuse.
        let same = records.filter { $0.id == peerID }
        if same.count > 1 { return nil }
        if let record = same.first {
            let name = record.displayName.lowercased()
            if records.contains(where: { $0.id != record.id && $0.displayName.lowercased() == name }) { return nil }
        }
        return contact
    }
}

public struct BoundAccount: Equatable {
    public let accountId: String
    public let contactID: UUID
    /// accountId != nil && pendingAccountBinding == nil
    public let verified: Bool
    public let identityKey: Data
}

/// Resolves the friend (and notes account) behind a chat thread.
@MainActor
public final class FriendBinding {
    private let contacts: () -> [TrustedContact]
    private let records: () -> [DeviceRecord]
    private let liveHandshakeKey: (String) -> Data?

    public init(contacts: @escaping () -> [TrustedContact],
                records: @escaping () -> [DeviceRecord],
                liveHandshakeKey: @escaping (String) -> Data?) {
        self.contacts = contacts
        self.records = records
        self.liveHandshakeKey = liveHandshakeKey
    }

    public convenience init(connectionManager cm: ConnectionManager) {
        self.init(contacts: { [unowned cm] in cm.trustedContactStore.contacts },
                  records: { [unowned cm] in cm.deviceStore.records },
                  liveHandshakeKey: { [unowned cm] in cm.connection(for: $0)?.handshakePeerIdentityKey })
    }

    public func contact(forChatPeerID peerID: String) -> TrustedContact? {
        FriendBindingResolver.resolve(peerID: peerID, liveHandshakeKey: liveHandshakeKey(peerID),
                                      contacts: contacts(), records: records())
    }

    public func boundAccount(forChatPeerID peerID: String) -> BoundAccount? {
        guard let c = contact(forChatPeerID: peerID), let accountId = c.accountId else { return nil }
        return BoundAccount(accountId: accountId, contactID: c.id,
                            verified: c.pendingAccountBinding == nil, identityKey: c.identityPublicKey)
    }

    /// `.pending` when a claim awaits directory verification (even before any
    /// verified account exists); `.verified` only for accountId != nil with
    /// no pending claim; otherwise `.none`.
    public func bindingState(forChatPeerID peerID: String) -> BindingState {
        guard let c = contact(forChatPeerID: peerID) else { return .none }
        if c.pendingAccountBinding != nil { return .pending }
        return c.accountId != nil ? .verified : .none
    }
}
