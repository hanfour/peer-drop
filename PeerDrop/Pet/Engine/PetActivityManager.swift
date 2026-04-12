import Foundation
import ActivityKit
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PetActivityManager")

@available(iOS 16.2, *)
@MainActor
class PetActivityManager {
    private var currentActivity: Activity<PetActivityAttributes>?

    static func contentState(from snapshot: PetSnapshot) -> PetActivityAttributes.ContentState {
        let progress = snapshot.maxExperience > 0
            ? min(Double(snapshot.experience) / Double(snapshot.maxExperience), 1.0)
            : 0.0
        return PetActivityAttributes.ContentState(
            pose: IslandPose.from(mood: snapshot.mood),
            mood: snapshot.mood,
            level: snapshot.level,
            expProgress: progress)
    }

    func startActivity(snapshot: PetSnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities not enabled")
            return
        }
        let attributes = PetActivityAttributes(
            petName: snapshot.name ?? "Pet",
            bodyType: snapshot.bodyType,
            eyeType: snapshot.eyeType,
            patternType: snapshot.patternType,
            paletteIndex: snapshot.paletteIndex)
        let state = Self.contentState(from: snapshot)
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(3600 * 8)),
                pushType: nil)
            logger.info("Started Live Activity")
        } catch {
            logger.error("Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    func updateActivity(snapshot: PetSnapshot) {
        guard let activity = currentActivity else { return }
        let state = Self.contentState(from: snapshot)
        Task {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(3600 * 8)))
        }
    }

    func endActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        logger.info("Ended Live Activity")
    }
}
