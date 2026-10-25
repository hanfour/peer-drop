import Foundation

public enum FeatureSettings {
    public static var isFileTransferEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropFileTransferEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropFileTransferEnabled")
    }
    public static var isVoiceCallEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropVoiceCallEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropVoiceCallEnabled")
    }
    public static var isChatEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropChatEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropChatEnabled")
    }
    public static var isBLEDiscoveryEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropBLEDiscoveryEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropBLEDiscoveryEnabled")
    }
    public static var isNearbyInteractionEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropNearbyInteractionEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropNearbyInteractionEnabled")
    }
    /// Off unless explicitly enabled: automatic clipboard sync reads everything the person copies and sends
    /// it to every connected peer, which must never happen silently.
    public static var isClipboardSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: "peerDropClipboardSyncEnabled")
    }
    public static var isRelayEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "peerDropRelayEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "peerDropRelayEnabled")
    }
}
