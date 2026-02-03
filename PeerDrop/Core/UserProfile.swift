import Foundation
import UIKit

struct UserProfile: Codable {
    var displayName: String
    var avatarData: Data?

    static var current: UserProfile {
        let name = UserDefaults.standard.string(forKey: "peerDropDisplayName") ?? UIDevice.current.name
        let avatar = UserDefaults.standard.data(forKey: "peerDropAvatarData")
        return UserProfile(displayName: name, avatarData: avatar)
    }

    func save() {
        UserDefaults.standard.set(displayName, forKey: "peerDropDisplayName")
        if let avatarData {
            UserDefaults.standard.set(avatarData, forKey: "peerDropAvatarData")
        } else {
            UserDefaults.standard.removeObject(forKey: "peerDropAvatarData")
        }
    }
}
