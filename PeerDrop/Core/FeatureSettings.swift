import Foundation

enum FeatureSettings {
    static var isFileTransferEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropFileTransferEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropFileTransferEnabled")
    }
    static var isVoiceCallEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropVoiceCallEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropVoiceCallEnabled")
    }
    static var isChatEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropChatEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropChatEnabled")
    }
}
