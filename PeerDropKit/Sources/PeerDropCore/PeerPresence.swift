import Foundation

/// Three-state presence shown on avatars.
public enum PeerPresence: Equatable {
    case online, nearby, offline
}

/// Sets of known ids per presence source.
public struct PresenceSources {
    public var connected: Set<String>
    public var connecting: Set<String>
    public var discovered: Set<String>
    /// Reserved for a future always-connected (server) mode; currently always empty.
    public var server: Set<String>

    public init(connected: Set<String>, connecting: Set<String>, discovered: Set<String>, server: Set<String> = []) {
        self.connected = connected
        self.connecting = connecting
        self.discovered = discovered
        self.server = server
    }
}

public enum PeerPresenceResolver {
    /// `ids ∩ (connected ∪ server)` → online; else `ids ∩ (connecting ∪ discovered)` → nearby; else offline.
    public static func presence(ids: Set<String>, sources: PresenceSources) -> PeerPresence {
        if !ids.isDisjoint(with: sources.connected.union(sources.server)) { return .online }
        if !ids.isDisjoint(with: sources.connecting.union(sources.discovered)) { return .nearby }
        return .offline
    }
}

extension ConnectionManager {
    public func presenceSources() -> PresenceSources {
        func ids(_ conns: [PeerConnection]) -> Set<String> {
            Set(conns.flatMap { [$0.id, $0.peerIdentity.id] })
        }
        let all = Array(connections.values)
        return PresenceSources(
            connected: ids(all.filter { $0.state.isConnected }),
            connecting: ids(all.filter { $0.state == .connecting }),
            discovered: Set(discoveredPeers.map(\.id)))
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
