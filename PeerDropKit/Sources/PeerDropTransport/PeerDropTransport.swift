/// Placeholder for the PeerDropTransport module.
///
/// In M1d, this module will own Bonjour discovery, PeerConnection,
/// WebRTC wrapper, RelaySession, NetworkFingerprint, TailnetPeerStore
/// — plus the Voice/ transport-layer pieces from M1b (VoiceCallManager,
/// WebRTCClient, SDPSignaling, VoicePlayer, VoiceRecorder, VoiceCallSession).
///
/// Until M1d migrates the source files, this empty enum exists only
/// so `swift build` has something to compile.
public enum PeerDropTransport {}
