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

    /// Total tap XP earned today
    var tapXPToday: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return allHistory
            .filter { $0.type == .tap && $0.date >= startOfDay }
            .reduce(0) { $0 + $1.type.experienceValue }
    }

    func record(_ type: InteractionType) {
        allHistory.append(Record(type: type, date: Date()))
        trimOldHistory()
    }

    func calculateMood(hasSocialRecently: Bool) -> PetMood {
        let recentCount = lastHourHistory.count
        let last10minCount = allHistory.filter { Date().timeIntervalSince($0.date) < 600 }.count
        let hasNewPeer = lastHourHistory.contains { $0.type == .peerConnected }

        // Lots of recent interaction = happy
        if last10minCount >= 5 { return .happy }
        // Peer connected in last hour = excited (not just curious)
        if hasNewPeer { return .excited }
        // Some interaction in last 10 min = curious
        if last10minCount > 0 { return .curious }
        // Had interaction in past hour but not recently = content (happy)
        if recentCount > 0 && hasSocialRecently { return .happy }
        // Some activity in past hour = default
        if recentCount > 0 { return .happy }
        // No interaction for 1+ hours with social = lonely
        if !hasSocialRecently && recentCount == 0 { return .lonely }
        // Default = sleepy
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
