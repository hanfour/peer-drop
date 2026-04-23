import Foundation
import Combine

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

    func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
