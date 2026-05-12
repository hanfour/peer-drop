import Foundation
import Combine
import Network
import os

@MainActor
final class TailnetPeerStore: ObservableObject {
    @Published private(set) var entries: [TailnetPeerEntry] = []
    private let key = "peerDropTailnetPeers"

    init() { load() }

    func add(displayName: String, ip: String, port: UInt16 = 9876) {
        let entry = TailnetPeerEntry(displayName: displayName, ip: ip, port: port)
        entries.append(entry)
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func rename(id: UUID, to newName: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].displayName = newName
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TailnetPeerEntry].self, from: data) else { return }
        entries = decoded
    }

    fileprivate func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Periodic Probe

    private var probeTask: Task<Void, Never>?

    func startPeriodicProbe() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeAll()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func stopPeriodicProbe() { probeTask?.cancel(); probeTask = nil }
}

extension TailnetPeerStore {
    func isReachable(_ id: UUID) -> Bool {
        guard let e = entries.first(where: { $0.id == id }) else { return false }
        return e.consecutiveFailures < 2 && e.lastReachable != nil
    }

    func probeAll() async {
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for entry in entries {
                group.addTask { [entry] in
                    let ok = await TailnetPeerStore.probeOne(ip: entry.ip, port: entry.port)
                    return (entry.id, ok)
                }
            }
            for await (id, ok) in group {
                guard let idx = self.entries.firstIndex(where: { $0.id == id }) else { continue }
                self.entries[idx].lastChecked = Date()
                if ok {
                    self.entries[idx].lastReachable = Date()
                    self.entries[idx].consecutiveFailures = 0
                } else {
                    self.entries[idx].consecutiveFailures += 1
                }
            }
            self.persist()
        }
    }

    func addIfMissing(displayName: String, ip: String, port: UInt16 = 9876) {
        if entries.contains(where: { $0.ip == ip }) { return }
        add(displayName: displayName, ip: ip, port: port)
    }

    nonisolated private static func probeOne(ip: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(ip),
                port: NWEndpoint.Port(integerLiteral: port),
                using: .tcp)
            let done = OSAllocatedUnfairLock(initialState: false)
            /// Atomically claim the done flag; returns `true` if successfully claimed.
            /// `@Sendable` so the local fn can be referenced from the
            /// `stateUpdateHandler` (Sendable closure) without a Swift 6 warning.
            @Sendable func claimDone() -> Bool {
                done.withLock { val in
                    if val { return false }
                    val = true
                    return true
                }
            }
            let timeout = DispatchWorkItem {
                guard claimDone() else { return }
                conn.cancel(); cont.resume(returning: false)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if claimDone() { timeout.cancel(); conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled:
                    if claimDone() { timeout.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: timeout)
        }
    }
}
