import Foundation
import PeerDropPlatform

public struct UserProfile: Codable {
    public var displayName: String
    public var avatarData: Data?

    public init(displayName: String, avatarData: Data? = nil) {
        self.displayName = displayName
        self.avatarData = avatarData
    }

    @MainActor
    public static var current: UserProfile {
        let name = UserDefaults.standard.string(forKey: "peerDropDisplayName")
            ?? PlatformDependencies.shared.deviceName().currentName
        let avatar = UserDefaults.standard.data(forKey: "peerDropAvatarData")
        return UserProfile(displayName: name, avatarData: avatar)
    }

    public func save() {
        UserDefaults.standard.set(displayName, forKey: "peerDropDisplayName")
        if let avatarData {
            UserDefaults.standard.set(avatarData, forKey: "peerDropAvatarData")
        } else {
            UserDefaults.standard.removeObject(forKey: "peerDropAvatarData")
        }
    }
}
