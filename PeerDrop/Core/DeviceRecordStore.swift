import Foundation
import SwiftUI

@MainActor
final class DeviceRecordStore: ObservableObject {
    @Published var records: [DeviceRecord] = []

    private let key = "peerDropDeviceRecords"

    init() {
        load()
        migrateConnectionHistory()
        mergeByName()
    }

    func addOrUpdate(id: String, displayName: String, sourceType: String, host: String?, port: UInt16?) {
        let now = Date()
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].displayName = displayName
            records[index].lastConnected = now
            records[index].connectionCount += 1
            records[index].connectionHistory.append(now)
            if let h = host { records[index].host = h }
            if let p = port { records[index].port = p }
        } else {
            // Check for existing record with same displayName (case-insensitive) but different id
            if let dupeIndex = records.firstIndex(where: { $0.displayName.lowercased() == displayName.lowercased() && $0.id != id }) {
                var merged = records[dupeIndex]
                let newRecord = DeviceRecord(
                    id: id,
                    displayName: displayName,
                    sourceType: sourceType,
                    host: host,
                    port: port,
                    lastConnected: now,
                    connectionCount: 1,
                    connectionHistory: [now]
                )
                merged.merge(with: newRecord)
                // Keep the new id
                records.remove(at: dupeIndex)
                let finalRecord = DeviceRecord(
                    id: id,
                    displayName: merged.displayName,
                    sourceType: sourceType,
                    host: merged.host,
                    port: merged.port,
                    lastConnected: merged.lastConnected,
                    connectionCount: merged.connectionCount,
                    connectionHistory: merged.connectionHistory
                )
                records.append(finalRecord)
            } else {
                let record = DeviceRecord(
                    id: id,
                    displayName: displayName,
                    sourceType: sourceType,
                    host: host,
                    port: port,
                    lastConnected: now,
                    connectionCount: 1,
                    connectionHistory: [now]
                )
                records.append(record)
            }
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

    private func migrateConnectionHistory() {
        var changed = false
        for i in records.indices {
            if records[i].connectionHistory.isEmpty {
                records[i].connectionHistory = [records[i].lastConnected]
                changed = true
            }
        }
        if changed { save() }
    }

    private func mergeByName() {
        var grouped: [String: [Int]] = [:]
        for (index, record) in records.enumerated() {
            let key = record.displayName.lowercased()
            grouped[key, default: []].append(index)
        }
        var indicesToRemove: Set<Int> = []
        for (_, indices) in grouped where indices.count > 1 {
            var primary = records[indices[0]]
            for i in indices.dropFirst() {
                primary.merge(with: records[i])
                indicesToRemove.insert(i)
            }
            records[indices[0]] = primary
        }
        if !indicesToRemove.isEmpty {
            records = records.enumerated().filter { !indicesToRemove.contains($0.offset) }.map(\.element)
            save()
        }
    }

    func replaceAll(with newRecords: [DeviceRecord]) {
        records = newRecords
        save()
    }

    func mergeImported(_ imported: [DeviceRecord]) {
        for record in imported {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index].merge(with: record)
            } else {
                records.append(record)
            }
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return }
        records = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
