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
        recordIDByAccount(recordIDs: cm.deviceStore.records.map(\.id),
                          chatKey: { id in
                              guard let r = cm.deviceStore.records.first(where: { $0.id == id }) else { return id }
                              return cm.chatKey(forRecord: r)
                          },
                          binding: FriendBinding(connectionManager: cm))
    }

    /// Pure core (testable): `recordIDs` in deterministic display order, `chatKey` maps a record to its chat peer id.
    static func recordIDByAccount(recordIDs: [String], chatKey: (String) -> String, binding: FriendBinding) -> [String: String] {
        var result: [String: String] = [:]
        for id in recordIDs {
            if let v = binding.verifiedAccount(forChatPeerID: chatKey(id)), result[v.accountId] == nil {
                result[v.accountId] = id
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

/// A note deep link that targets a bound friend's thread. `noteID` lets the list still show the
/// tapped note if the friend vanished between the decision and the push.
struct ThreadRequest: Equatable {
    let recordID: String
    let noteID: String?
}

/// Keeps the set of verified-bound accounts current for views that must not recompute it in `body`.
@MainActor
final class BoundFriendsModel: ObservableObject {
    @Published private(set) var recordIDByAccount: [String: String] = [:]
    /// False until the first `bind`; views use a synchronous fallback so no unfiltered frame shows.
    private(set) var isReady = false
    var accounts: Set<String> { Set(recordIDByAccount.keys) }
    /// Records whose friend has a verified binding.
    var reachableRecordIDs: Set<String> { Set(recordIDByAccount.values) }
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
        isReady = true
        let next = BoundFriends.recordIDByAccount(cm)
        if next != recordIDByAccount { recordIDByAccount = next }
    }
}
