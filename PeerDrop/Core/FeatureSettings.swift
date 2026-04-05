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
    static var isBLEDiscoveryEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropBLEDiscoveryEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropBLEDiscoveryEnabled")
    }
    static var isNearbyInteractionEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropNearbyInteractionEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropNearbyInteractionEnabled")
    }
    static var isClipboardSyncEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropClipboardSyncEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropClipboardSyncEnabled")
    }
    static var isRelayEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropRelayEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropRelayEnabled")
    }
}
