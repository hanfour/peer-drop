import Foundation
import SwiftUI

@MainActor
final class DeviceRecordStore: ObservableObject {
    @Published var records: [DeviceRecord] = []

    private let key = "peerDropDeviceRecords"

    init() {
        load()
    }

    func addOrUpdate(id: String, displayName: String, sourceType: String, host: String?, port: UInt16?) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].displayName = displayName
            records[index].lastConnected = Date()
            records[index].connectionCount += 1
            if let h = host { records[index].host = h }
            if let p = port { records[index].port = p }
        } else {
            let record = DeviceRecord(
                id: id,
                displayName: displayName,
                sourceType: sourceType,
                host: host,
                port: port,
                lastConnected: Date(),
                connectionCount: 1
            )
            records.append(record)
        }
        save()
    }

    func remove(id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    func sorted(by mode: SortMode) -> [DeviceRecord] {
        switch mode {
        case .name:
            return records.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .lastConnected:
            return records.sorted { $0.lastConnected > $1.lastConnected }
        case .connectionCount:
            return records.sorted { $0.connectionCount > $1.connectionCount }
        }
    }

    func search(query: String) -> [DeviceRecord] {
        guard !query.isEmpty else { return records }
        return records.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
