import Foundation

/// A human-readable readout of the iCloud pet-sync state, so the
/// two-device verification (docs/plans/2026-07-05-remaining-work-roadmap.md
/// §3) is an observation instead of guesswork. `render` is pure and unit
/// tested; `gather` collects the real, side-effecting state (iCloud
/// availability, the ubiquity container, the KVS heartbeat, and the local vs
/// cloud pet timestamps) and is meant to be called from a DEBUG affordance.
public enum PetSyncDiagnostics {

    public struct Snapshot {
        public let capturedAt: Date
        public let iCloudAccountAvailable: Bool
        public let ubiquityContainerURL: String?
        public let localPetID: String?
        public let localUpdatedAt: Date?
        public let cloudPetID: String?
        public let cloudUpdatedAt: Date?
        public let kvsPetID: String?
        public let kvsLevel: Int?
        public let kvsExperience: Int?

        public init(
            capturedAt: Date,
            iCloudAccountAvailable: Bool,
            ubiquityContainerURL: String?,
            localPetID: String?, localUpdatedAt: Date?,
            cloudPetID: String?, cloudUpdatedAt: Date?,
            kvsPetID: String?, kvsLevel: Int?, kvsExperience: Int?
        ) {
            self.capturedAt = capturedAt
            self.iCloudAccountAvailable = iCloudAccountAvailable
            self.ubiquityContainerURL = ubiquityContainerURL
            self.localPetID = localPetID
            self.localUpdatedAt = localUpdatedAt
            self.cloudPetID = cloudPetID
            self.cloudUpdatedAt = cloudUpdatedAt
            self.kvsPetID = kvsPetID
            self.kvsLevel = kvsLevel
            self.kvsExperience = kvsExperience
        }
    }

    /// Top-line verdict — the one thing a tester reads first.
    public enum Verdict: String {
        case iCloudUnavailable = "iCLOUD UNAVAILABLE"
        case noPet             = "NO PET (fresh)"
        case localOnly         = "LOCAL ONLY"
        case cloudOnly         = "CLOUD ONLY"
        case cloudAhead        = "CLOUD AHEAD"
        case localAhead        = "LOCAL AHEAD"
        case inSync            = "IN SYNC"
        case divergentPets     = "DIVERGENT PETS"
    }

    public static func verdict(_ s: Snapshot) -> Verdict {
        guard s.iCloudAccountAvailable else { return .iCloudUnavailable }
        switch (s.localPetID, s.cloudPetID) {
        case (nil, nil): return .noPet
        case (_?, nil):  return .localOnly
        case (nil, _?):  return .cloudOnly
        case let (l?, c?):
            if l != c { return .divergentPets }        // different pets — conflict resolver decides
            let lt = s.localUpdatedAt ?? .distantPast
            let ct = s.cloudUpdatedAt ?? .distantPast
            if ct > lt { return .cloudAhead }
            if lt > ct { return .localAhead }
            return .inSync
        }
    }

    /// Full multi-line readout: verdict + the evidence behind it.
    public static func render(_ s: Snapshot) -> String {
        let v = verdict(s)
        var lines: [String] = []
        lines.append("PET SYNC — \(v.rawValue)")
        lines.append(hint(for: v))
        lines.append("")
        lines.append("iCloud account : \(s.iCloudAccountAvailable ? "available" : "UNAVAILABLE (not signed in / no entitlement)")")
        lines.append("container      : \(s.ubiquityContainerURL ?? "<none>")")
        lines.append("local pet      : \(idAndTime(s.localPetID, s.localUpdatedAt))")
        lines.append("cloud pet      : \(idAndTime(s.cloudPetID, s.cloudUpdatedAt))")
        lines.append("KVS heartbeat  : \(kvsLine(s))")
        lines.append("captured       : \(iso(s.capturedAt))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Real-state gatherer (side-effecting; call from DEBUG only)

    /// Collect the live sync state. Reads the local + cloud pet copies and the
    /// iCloud KVS heartbeat. Safe on a device without an iCloud container —
    /// the cloud fields simply come back nil.
    public static func gather(
        local: PetStore = PetStore(),
        cloud: PetCloudSync = PetCloudSync(),
        fileManager: FileManager = .default,
        kvStore: NSUbiquitousKeyValueStore = .default,
        now: Date = Date()
    ) -> Snapshot {
        let accountAvailable = fileManager.ubiquityIdentityToken != nil
        let container = fileManager.url(forUbiquityContainerIdentifier: nil)?.absoluteString
        let localPet = try? local.load()
        let cloudPet = try? cloud.loadFromCloud()
        let kvsID = kvStore.string(forKey: "pet_id")
        let kvsLevel = kvStore.object(forKey: "pet_level") as? Int
            ?? Int(kvStore.longLong(forKey: "pet_level"))
        let kvsExp = kvStore.object(forKey: "pet_exp") as? Int
            ?? Int(kvStore.longLong(forKey: "pet_exp"))
        return Snapshot(
            capturedAt: now,
            iCloudAccountAvailable: accountAvailable,
            ubiquityContainerURL: container,
            localPetID: localPet?.id.uuidString, localUpdatedAt: localPet?.updatedAt,
            cloudPetID: cloudPet?.id.uuidString, cloudUpdatedAt: cloudPet?.updatedAt,
            kvsPetID: kvsID,
            kvsLevel: kvsID == nil ? nil : kvsLevel,
            kvsExperience: kvsID == nil ? nil : kvsExp)
    }

    // MARK: - Formatting helpers

    private static func hint(for v: Verdict) -> String {
        switch v {
        case .iCloudUnavailable: return "Sign in to iCloud (and, on Mac, confirm the iCloud entitlement shipped)."
        case .noPet:             return "Neither device has a pet yet — hatch one to start."
        case .localOnly:         return "This device has a pet; iCloud has none. Background the app to push it up."
        case .cloudOnly:         return "iCloud has a pet; this device doesn't. It will adopt it on next launch."
        case .cloudAhead:        return "iCloud is newer — this device pulls the cloud pet on next launch/observe."
        case .localAhead:        return "This device is newer — background to push the local pet up."
        case .inSync:            return "Local and cloud agree. Propagation confirmed."
        case .divergentPets:     return "Different pet IDs — the conflict resolver keeps the more-invested one."
        }
    }

    private static func idAndTime(_ id: String?, _ t: Date?) -> String {
        guard let id else { return "<none>" }
        return "\(shortID(id))  @ \(t.map(iso) ?? "?")"
    }

    private static func kvsLine(_ s: Snapshot) -> String {
        guard let id = s.kvsPetID else { return "<none>" }
        return "\(shortID(id))  level \(s.kvsLevel.map(String.init) ?? "?")  exp \(s.kvsExperience.map(String.init) ?? "?")"
    }

    private static func shortID(_ id: String) -> String {
        id.count > 8 ? String(id.prefix(8)) + "…" : id
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
}
