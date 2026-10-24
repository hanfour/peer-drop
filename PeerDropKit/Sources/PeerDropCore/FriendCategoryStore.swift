import Foundation
import Combine
import os
import PeerDropSecurity

/// Friend "categories" (replaces the old DeviceGroup UI). One friend belongs to
/// at most one category; friends in none are "uncategorized". Persisted as an
/// encrypted file (never UserDefaults, unlike the legacy DeviceGroupStore).
@MainActor
public final class FriendCategoryStore: ObservableObject {
    public static let maxCategories = 20
    public static let maxNameLength = 20
    public static let fallbackName = "分類"
    static let migratedFlagKey = "peerDropCategoriesMigrated"

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "FriendCategoryStore")

    @Published public private(set) var categories: [FriendCategory] = []

    private let storageKey: String
    private let directory: URL
    private let encryptor: ChatDataEncryptor
    private let migrationDefaults: UserDefaults

    private var url: URL { directory.appendingPathComponent("\(storageKey).enc") }

    public init(
        storageKey: String = "categories",
        directory: URL? = nil,
        encryptor: ChatDataEncryptor = .shared,
        legacyGroups: [DeviceGroup] = [],
        migrationDefaults: UserDefaults = .standard
    ) {
        self.storageKey = storageKey
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        self.encryptor = encryptor
        self.migrationDefaults = migrationDefaults

        if FileManager.default.fileExists(atPath: url.path) {
            load()
        } else if !migrationDefaults.bool(forKey: Self.migratedFlagKey), !legacyGroups.isEmpty {
            categories = Self.migrate(legacy: legacyGroups)
            if save() { migrationDefaults.set(true, forKey: Self.migratedFlagKey) }
        }
    }

    // MARK: - Mutations

    @discardableResult
    public func create(name: String) -> FriendCategory? {
        guard let clean = Self.validName(name), categories.count < Self.maxCategories else { return nil }
        let cat = FriendCategory(name: clean, order: (categories.map(\.order).max() ?? -1) + 1)
        categories.append(cat)
        save()
        return cat
    }

    @discardableResult
    public func rename(id: String, to name: String) -> Bool {
        guard let clean = Self.validName(name), let i = categories.firstIndex(where: { $0.id == id }) else { return false }
        categories[i].name = clean
        save()
        return true
    }

    public func delete(id: String) {
        categories.removeAll { $0.id == id }
        normalizeOrder()
        save()
    }

    /// Moves a category in the order list (SwiftUI `onMove` semantics: `to` is the destination offset).
    public func move(order from: Int, to: Int) {
        guard categories.indices.contains(from), to >= 0, to <= categories.count else { return }
        let item = categories.remove(at: from)
        categories.insert(item, at: to > from ? to - 1 : to)
        normalizeOrder()
        save()
    }

    public func reorder(ids: [String]) {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        categories.sort { (rank[$0.id] ?? Int.max, $0.order) < (rank[$1.id] ?? Int.max, $1.order) }
        normalizeOrder()
        save()
    }

    public func setNotificationsEnabled(_ enabled: Bool, for categoryID: String) {
        guard let i = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        categories[i].notificationsEnabled = enabled
        save()
    }

    public func assign(friendID: String, to categoryID: String?) {
        for i in categories.indices { categories[i].friendIDs.removeAll { $0 == friendID } }
        if let categoryID, let i = categories.firstIndex(where: { $0.id == categoryID }) {
            categories[i].friendIDs.append(friendID)
        }
        save()
    }

    // MARK: - Queries

    public func category(containingAnyOf ids: [String]) -> FriendCategory? {
        let wanted = Set(ids)
        return categories.first { !wanted.isDisjoint(with: $0.friendIDs) }
    }

    public func notificationsEnabled(forAnyOf ids: [String]) -> Bool {
        category(containingAnyOf: ids)?.notificationsEnabled ?? true
    }

    // MARK: - Migration

    /// Pure: one category per legacy group (same id/name/members). A friend in several
    /// groups goes to the group whose name sorts first (`localizedStandardCompare`,
    /// ties by original order). Order follows the original group order.
    public static func migrate(legacy groups: [DeviceGroup]) -> [FriendCategory] {
        let names = groups.map { cleanedLegacyName($0.name) }
        let ranked = groups.indices.sorted { a, b in
            switch names[a].localizedStandardCompare(names[b]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a < b
            }
        }
        var owner: [String: Int] = [:]
        for idx in ranked {
            for id in groups[idx].deviceIDs where owner[id] == nil { owner[id] = idx }
        }
        return groups.enumerated().map { idx, g in
            var seen = Set<String>()
            let members = g.deviceIDs.filter { owner[$0] == idx && seen.insert($0).inserted }
            return FriendCategory(id: g.id, name: names[idx], order: idx, friendIDs: members)
        }
    }

    // MARK: - Helpers

    private static func validName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...maxNameLength).contains(t.count) ? t : nil
    }

    private static func cleanedLegacyName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallbackName : String(t.prefix(maxNameLength))
    }

    private func normalizeOrder() {
        for i in categories.indices { categories[i].order = i }
    }

    private func load() {
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            categories = try JSONDecoder().decode([FriendCategory].self, from: data).sorted { $0.order < $1.order }
        } catch {
            Self.logger.error("categories file unreadable: \(error.localizedDescription, privacy: .public)")
            categories = []
            let corrupt = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.moveItem(at: url, to: corrupt)
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encryptor.encryptAndWrite(JSONEncoder().encode(categories), to: url)
            return true
        } catch {
            Self.logger.error("categories save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
