import Foundation

/// Presence shown on avatars.
/// - `online`: a live connection exists (for a cross-network friend: only a
///   VERIFIED rendezvous connection).
/// - `nearby`: discovered / connecting on the local network.
/// - `connecting` (Project E): waiting in the rendezvous room or negotiating;
///   never live.
/// - `offline`: none of the above (a cross-network `unreachable` friend is
///   offline: peer-off and refused are never distinguished).
public enum PeerPresence: Equatable, CaseIterable {
    case online, nearby, connecting, offline
}

/// Sets of known ids per presence source.
public struct PresenceSources {
    public var connected: Set<String>
    public var connecting: Set<String>
    public var discovered: Set<String>
    /// Reserved for a future always-connected (server) mode; currently always empty.
    public var server: Set<String>
    /// Project E: cross-network friends waiting in the room or negotiating
    /// (not yet verified). Resolves to `.connecting`, never online.
    public var crossNetworkConnecting: Set<String>

    public init(connected: Set<String>, connecting: Set<String>, discovered: Set<String>, server: Set<String> = [],
                crossNetworkConnecting: Set<String> = []) {
        self.connected = connected
        self.connecting = connecting
        self.discovered = discovered
        self.server = server
        self.crossNetworkConnecting = crossNetworkConnecting
    }
}

public enum PeerPresenceResolver {
    /// `ids ∩ (connected ∪ server)` → online; else `ids ∩ (connecting ∪ discovered)` → nearby;
    /// else `ids ∩ crossNetworkConnecting` → connecting; else offline.
    public static func presence(ids: Set<String>, sources: PresenceSources) -> PeerPresence {
        if !ids.isDisjoint(with: sources.connected.union(sources.server)) { return .online }
        if !ids.isDisjoint(with: sources.connecting.union(sources.discovered)) { return .nearby }
        if !ids.isDisjoint(with: sources.crossNetworkConnecting) { return .connecting }
        return .offline
    }
}

/// Resolves a record to a live value by trying its ids in order (record id, then alias).
public enum RecordConnectionLookup {
    public static func resolve<T>(recordID: String, peerDeviceID: String?, lookup: (String) -> T?) -> T? {
        if let hit = lookup(recordID) { return hit }
        if let alias = peerDeviceID, alias != recordID { return lookup(alias) }
        return nil
    }
}

extension ConnectionManager {
    /// The live connection for a saved record. Presence matches `{record.id, record.peerDeviceId}`,
    /// so actions must resolve through the same two ids (each via the `connection(for:)` alias lookup).
    public func connection(for record: DeviceRecord) -> PeerConnection? {
        RecordConnectionLookup.resolve(recordID: record.id, peerDeviceID: record.peerDeviceId) { connection(for: $0) }
    }

    /// Name to show for a saved record: relay/blank stored names defer to the live connection's identity.
    public func displayName(for record: DeviceRecord) -> String {
        ChatDisplayName.forRecord(recordName: record.displayName,
                                  liveName: connection(for: record)?.peerIdentity.displayName)
    }

    public func presenceSources() -> PresenceSources {
        func ids(_ conns: [PeerConnection]) -> Set<String> {
            Set(conns.flatMap { [$0.id, $0.peerIdentity.id] })
        }
        let all = Array(connections.values)
        // Project E: only a VERIFIED rendezvous connection is online (it is
        // exactly what `connection(for:)` returns, so a live send always finds
        // it); an installed-but-unverified one, or a room waiting/negotiating,
        // is `.connecting`.
        let rendezvous = Array(rendezvousConnections.values)
        return PresenceSources(
            connected: ids(all.filter { $0.state.isConnected } + rendezvous.filter(\.rendezvousVerified)),
            connecting: ids(all.filter { $0.state == .connecting }),
            discovered: Set(discoveredPeers.map(\.id)),
            crossNetworkConnecting: ids(rendezvous.filter { !$0.rendezvousVerified })
                .union(rendezvousConnectingDeviceIDs()))
    }

    /// Presence of a chat peer id (e.g. a thread's `peerID`) from one snapshot.
    public func presence(ids: Set<String>) -> PeerPresence {
        PeerPresenceResolver.presence(ids: ids, sources: presenceSources())
    }

    public func presence(for record: DeviceRecord) -> PeerPresence {
        presence(for: record, sources: presenceSources())
    }

    public func presence(for record: DeviceRecord, sources: PresenceSources) -> PeerPresence {
        var ids: Set<String> = [record.id]
        if let alias = record.peerDeviceId { ids.insert(alias) }
        return PeerPresenceResolver.presence(ids: ids, sources: sources)
    }

    /// `total` is `group.deviceIDs.count`. Ids with no matching record can't be
    /// resolved to a peer, so they count toward total only (never online).
    public func presence(forGroup group: DeviceGroup) -> (online: Int, total: Int) {
        let sources = presenceSources()
        let byID = Dictionary(deviceStore.records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let online = group.deviceIDs.filter { id in
            byID[id].map { presence(for: $0, sources: sources) == .online } ?? false
        }.count
        return (online, group.deviceIDs.count)
    }
}
