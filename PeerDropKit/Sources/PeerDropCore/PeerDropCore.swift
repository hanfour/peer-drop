/// Placeholder for the PeerDropCore module.
///
/// In M1d, this module will own ConnectionManager, ChatManager,
/// DeviceRecordStore, UserProfile, InboxService,
/// ScreenshotModeProvider, ConnectionMetrics, plus the Platform/
/// registry from M0/M1a/M1b. (DeviceIdentity + FeatureSettings
/// migrated to PeerDropPlatform during M1d-4 because they are
/// pure UserDefaults wrappers with no Core dependencies.)
///
/// Until M1d migrates the source files, this empty enum exists only
/// so `swift build` has something to compile.
public enum PeerDropCore {}
