import Foundation
import PeerDropPlatform

/// Centralised auth-header application for outbound Worker requests.
/// Prefers an App-Attest-issued Bearer token (from `DeviceTokenManager`)
/// and falls back to the `X-API-Key` lane.
///
/// Since the 2026-07 key rotation (worker-auth redesign §Layer 5,
/// REVISED), X-API-Key is a PERMANENT credential, not a deprecation
/// shim, and it now covers two different kinds of caller:
///
///   * **Operator/dev** — peerdrop-cli (no App Attest entitlement),
///     local Debug builds and Simulator runs, via `API_KEY`.
///   * **Shipped native macOS** — `DCAppAttestService.isSupported` is
///     `false` on native Mac apps (verified 2026-09-15 on an M4 running
///     macOS 15.7), so the Mac build ships its own `MAC_CLIENT_KEY` and
///     authenticates with it. On the worker that key is a restricted
///     lane: it reaches the /v2 relay surfaces and the read/registration
///     half of /v3, never the account-mutating routes.
///
/// Release App Store builds of the **iOS** app intentionally ship no key
/// — on devices where App Attest is unavailable (e.g. the iPhone app
/// running on Apple Silicon Macs) or transiently failing, `applyAuth`
/// attaches NOTHING and the request 401s; App Attest retries on the next
/// request. The Mac Release build is the deliberate exception above.
public enum WorkerAuthHelper {

    /// Apply the strongest available credential to `request`. Async so
    /// the token-refresh path can run an HTTP round-trip without
    /// blocking the caller's actor.
    public static func applyAuth(to request: inout URLRequest) async {
        if #available(iOS 14.0, macOS 11.0, *) {
            if let bearer = await DeviceTokenManager.shared.bearerHeader() {
                request.setValue(bearer, forHTTPHeaderField: "Authorization")
                return
            }
        }
        if let apiKey = legacyAPIKey() {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            // The key alone says "a holder of this credential"; the
            // worker's /v3 key lane additionally needs to know WHICH
            // device is speaking, so it can resolve the account binding
            // (`scopeForDevice`). Self-asserted by design — which is why
            // that lane is read/registration only on the server side.
            request.setValue(DeviceIdentity.deviceId, forHTTPHeaderField: "X-Device-Id")
        }
    }

    /// Resolve the worker API key. Precedence (first non-empty wins):
    ///   1. `PEERDROP_WORKER_KEY` environment variable — explicit
    ///      per-invocation supply (peerdrop-cli relay mode); env beats
    ///      any stale `defaults write` left from before a rotation.
    ///   2. `peerDropWorkerAPIKey` in UserDefaults — operator
    ///      set-and-forget override.
    ///   3. The Info.plist key baked in via Secrets.xcconfig — iOS Debug
    ///      builds only since the 2026-07 rotation; on the Mac target it
    ///      is bound for Debug AND Release, carrying `MAC_CLIENT_KEY`
    ///      (see the type doc above).
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
        if #available(iOS 14.0, macOS 11.0, *) {
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
