import Foundation

/// Centralised auth-header application for outbound Worker requests.
/// Prefers an App-Attest-issued Bearer token (from `DeviceTokenManager`)
/// and falls back to the operator `X-API-Key` lane.
///
/// Since the 2026-07 key rotation (worker-auth redesign §Layer 5,
/// REVISED), X-API-Key is a PERMANENT operator/dev credential, not a
/// deprecation shim: peerdrop-cli (no App Attest entitlement), local
/// Debug builds, and Simulator runs authenticate with it. Release App
/// Store builds intentionally ship no key — on devices where App
/// Attest is unavailable (e.g. iPhone app running on Apple Silicon
/// Macs) or transiently failing, `applyAuth` attaches NOTHING and the
/// request 401s; App Attest retries on the next request.
public enum WorkerAuthHelper {

    /// Apply the strongest available credential to `request`. Async so
    /// the token-refresh path can run an HTTP round-trip without
    /// blocking the caller's actor.
    public static func applyAuth(to request: inout URLRequest) async {
        if #available(iOS 14.0, *) {
            if let bearer = await DeviceTokenManager.shared.bearerHeader() {
                request.setValue(bearer, forHTTPHeaderField: "Authorization")
                return
            }
        }
        if let apiKey = legacyAPIKey() {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
    }

    /// Resolve the operator API key. Precedence (first non-empty wins):
    ///   1. `PEERDROP_WORKER_KEY` environment variable — explicit
    ///      per-invocation supply (peerdrop-cli relay mode); env beats
    ///      any stale `defaults write` left from before a rotation.
    ///   2. `peerDropWorkerAPIKey` in UserDefaults — operator
    ///      set-and-forget override.
    ///   3. The Info.plist key baked in via Secrets.xcconfig — Debug
    ///      builds only since the 2026-07 rotation.
    /// Empty strings are treated as absent at every level so a blank
    /// setting falls through instead of sending a blank header.
    public static func legacyAPIKey() -> String? {
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PEERDROP_WORKER_KEY"],
            UserDefaults.standard.string(forKey: "peerDropWorkerAPIKey"),
            WorkerSignaling.bundledAPIKey,
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Token + query-param flavor for WebSocket upgrades, where
    /// URLSession can't attach `Authorization` headers. Returns
    /// `(name, value)` to splat into `URLComponents.queryItems`.
    public static func authQueryItem() async -> URLQueryItem? {
        if #available(iOS 14.0, *) {
            if let token = await DeviceTokenManager.shared.currentRawToken() {
                return URLQueryItem(name: "token", value: token)
            }
        }
        if let apiKey = legacyAPIKey() {
            return URLQueryItem(name: "apiKey", value: apiKey)
        }
        return nil
    }
}
