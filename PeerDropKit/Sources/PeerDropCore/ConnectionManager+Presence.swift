import Foundation
import PeerDropProtocol
import PeerDropSecurity
import PeerDropTransport

// Project F2 / Task 3 — enforcing category presence ("what a friend sees of
// me"). A friend whose category hides us right now:
// - incoming direct connection: cancelled right after the HELLO, before any
//   reply (no consent sheet, no TOFU, no frame at all);
// - dialing them: refused with a toast;
// - always-connected room: left (`RendezvousManager` filters on `visible`);
// - a live direct / rendezvous connection: closed quietly (`cancel()`, never
//   `disconnect()`, which would send a `.disconnect` frame).
// Relay-code (`relay-<code>`) connections are exempt: both sides typed the
// room code, an explicit one-off consent.
//
// Visibility is always computed live at the enforcement point; the single
// `presenceTimer` only wakes `reevaluatePresence()` at the next schedule
// boundary so live connections follow the schedule.

extension ConnectionManager {

    // MARK: - Visibility

    /// Every id the peer behind `identity` may be stored under: its identity
    /// id, `extraIDs`, and the device id of a contact pinning the same key,
    /// before `notificationAliasIDs` expansion.
    func friendAliasIDs(forIdentity identity: PeerIdentity, extraIDs: [String] = []) -> [String] {
        var ids = [identity.id] + extraIDs
        if let key = identity.identityPublicKey,
           let deviceID = trustedContactStore.find(byPublicKey: key)?.deviceId {
            ids.append(deviceID)
        }
        return ids
    }

    /// May the friend known by `ids` (expanded to all their aliases) see us
    /// online right now?
    public func isFriendVisible(aliases ids: [String]) -> Bool {
        PresencePolicy.isVisible(aliases: notificationAliasIDs(for: ids),
                                 categories: categoryStore.categories,
                                 at: presenceClock(), calendar: presenceCalendar)
    }

    func isFriendVisible(identity: PeerIdentity) -> Bool {
        isFriendVisible(aliases: friendAliasIDs(forIdentity: identity))
    }

    /// The contact's device id plus every contact pinning the same key.
    func isFriendVisible(contact: TrustedContact) -> Bool {
        var ids = [contact.deviceId].compactMap { $0 }
        for c in trustedContactStore.contacts where c.identityPublicKey == contact.identityPublicKey {
            if let id = c.deviceId { ids.append(id) }
        }
        return isFriendVisible(aliases: ids)
    }

    func isFriendVisible(connection pc: PeerConnection) -> Bool {
        isFriendVisible(aliases: friendAliasIDs(forIdentity: pc.peerIdentity,
                                                extraIDs: [pc.id, ChatStorageKey.key(forConnection: pc)]))
    }

    // MARK: - Enforcement

    /// Close every live connection to a friend who may no longer see us,
    /// re-reconcile the rooms and re-arm the timer. Idempotent.
    func reevaluatePresence() {
        for pc in Array(connections.values)
        where !pc.isRelayTransport && pc.state.isActive && !isFriendVisible(connection: pc) {
            closeQuietly(pc)
        }
        for pc in Array(rendezvousConnections.values) where !isFriendVisible(connection: pc) {
            closeRendezvousConnection(pc)
        }
        rendezvousManager?.contactsDidChange()
        schedulePresenceTimer()
    }

    /// Close a direct connection without any frame. `onDisconnected` runs the
    /// usual `handlePeerDisconnected` cleanup (transfers, calls, removal).
    /// No toast: to the user the friend simply went offline.
    func closeQuietly(_ pc: PeerConnection) {
        pc.cancel()
        pc.updateState(.disconnected)
        #if os(iOS)
        nearbyInteractionManager?.stopSession(for: pc.id)
        #endif
    }

    // MARK: - Timer

    /// One timer at the next schedule boundary (+1 s so it never fires just
    /// before it), or none when no category is scheduled.
    func schedulePresenceTimer() {
        cancelPresenceTimer()
        guard let date = PresencePolicy.nextTransition(categories: categoryStore.categories,
                                                       after: presenceClock(), calendar: presenceCalendar)
        else { return }
        let timer = Timer(fire: date.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reevaluatePresence() }
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
    }

    func cancelPresenceTimer() {
        presenceTimer?.invalidate()
        presenceTimer = nil
    }
}
