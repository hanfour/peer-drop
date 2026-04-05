import Foundation

class InteractionTracker {
    struct Record: Codable {
        let type: InteractionType
        let date: Date
    }

    private(set) var allHistory: [Record] = []

    var recentHistory: [Record] {
        let cutoff = Date().addingTimeInterval(-86400)
        return allHistory.filter { $0.date > cutoff }
    }

    var lastHourHistory: [Record] {
        let cutoff = Date().addingTimeInterval(-3600)
        return allHistory.filter { $0.date > cutoff }
    }

    func record(_ type: InteractionType) {
        allHistory.append(Record(type: type, date: Date()))
        trimOldHistory()
    }

    func calculateMood(hasSocialRecently: Bool) -> PetMood {
        let recentCount = lastHourHistory.count
        let hasNewPeer = lastHourHistory.contains { $0.type == .peerConnected }

        if recentCount >= 5 { return .happy }
        if hasNewPeer { return .curious }
        if recentCount == 0 && !hasSocialRecently { return .sleepy }
        if recentCount > 0 { return .curious }
        return .sleepy
    }

    // For testing only
    func insertForTesting(_ record: Record) {
        allHistory.append(record)
    }

    private func trimOldHistory() {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        allHistory.removeAll { $0.date < cutoff }
    }
}
