import SwiftUI
import Combine
import PeerDropCore
import PeerDropNotes

/// Which friends have a VERIFIED notes-account binding (never pending). Shared by the
/// conversations list, the inbox filter, the badge math and the `.openNote` routing so they
/// all agree on which notes live in a thread.
@MainActor
enum BoundFriends {
    /// Verified account id -> `DeviceRecord.id`. The first record wins if two ever resolve to the
    /// same account (bindings are unique per contact, so this is purely defensive).
    static func recordIDByAccount(_ cm: ConnectionManager) -> [String: String] {
        let binding = FriendBinding(connectionManager: cm)
        var result: [String: String] = [:]
        for r in cm.deviceStore.records {
            let key = cm.connection(for: r)?.peerIdentity.id ?? r.id
            if let v = binding.verifiedAccount(forChatPeerID: key), result[v.accountId] == nil {
                result[v.accountId] = r.id
            }
        }
        return result
    }

    /// Destination for a notification-tapped note id (unknown id -> inbox).
    static func destination(forNoteID id: String, cm: ConnectionManager) -> InboxDeepLink.Destination {
        let map = recordIDByAccount(cm)
        return InboxDeepLink.destination(sender: cm.notesStore.note(id: id)?.sender, recordIDForAccount: { map[$0] })
    }
}

/// Keeps the set of verified-bound accounts current for views that must not recompute it in `body`.
@MainActor
final class BoundFriendsModel: ObservableObject {
    @Published private(set) var recordIDByAccount: [String: String] = [:]
    var accounts: Set<String> { Set(recordIDByAccount.keys) }
    private var cancellable: AnyCancellable?

    func bind(_ cm: ConnectionManager) {
        refresh(cm)
        guard cancellable == nil else { return }
        cancellable = RefreshHub.pipeline([
            cm.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            cm.deviceStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            cm.trustedContactStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]).sink { [weak self, weak cm] in
            guard let self, let cm else { return }
            self.refresh(cm)
        }
    }

    func refresh(_ cm: ConnectionManager) {
        let next = BoundFriends.recordIDByAccount(cm)
        if next != recordIDByAccount { recordIDByAccount = next }
    }
}
