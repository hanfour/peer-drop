import Foundation

/// Centralised auth-header application for outbound Worker requests.
/// Prefers an App-Attest-issued Bearer token (from `DeviceTokenManager`)
/// and falls back to the legacy `X-API-Key` bundled in the IPA when:
///   • App Attest is unsupported (Simulator, devices below iOS 14, dev
///     builds without the entitlement),
///   • the worker hasn't been upgraded yet (returns 501 on /attest),
///   • the token cache is empty and the network leg failed (e.g. boot
///     before the inbox WS is up).
///
/// Once the v5.3 transition window closes and `X-API-Key` is dropped
/// from the worker, the fallback branch can go away.
enum WorkerAuthHelper {

    /// Apply the strongest available credential to `request`. Async so
    /// the token-refresh path can run an HTTP round-trip without
    /// blocking the caller's actor.
    static func applyAuth(to request: inout URLRequest) async {
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

    /// Read the bundled or operator-overridden API key. Mirrors the
    /// resolution order `WorkerSignaling` has always used so callers
    /// migrating off direct `X-API-Key` reads see no behavior change.
    static func legacyAPIKey() -> String? {
        UserDefaults.standard.string(forKey: "peerDropWorkerAPIKey")
            ?? WorkerSignaling.bundledAPIKey
    }

    /// Token + query-param flavor for WebSocket upgrades, where
    /// URLSession can't attach `Authorization` headers. Returns
    /// `(name, value)` to splat into `URLComponents.queryItems`.
    static func authQueryItem() async -> URLQueryItem? {
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
