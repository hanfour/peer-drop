import Foundation
import PeerDropSecurity
import PeerDropTransport
import os.log

/// Uploads `CryptoHardeningMetrics` snapshots to the worker's
/// `POST /debug/crypto-metric` endpoint, feeding the v5.4 crypto-hardening
/// soak (spec §8.6). Before this existed, `CryptoHardeningMetrics.snapshot()`
/// had no consumer — the counters lived only in process memory and the soak
/// read an empty bucket.
///
/// Delivery is at-least-once with a safe bias: snapshot → POST → subtract
/// only on a 2xx. A failed or credential-less POST leaves the counters in
/// place so the next flush re-sends them; over-counting an error signal is
/// conservative (it would delay strict-policy activation, never wrongly
/// enable it), whereas losing one is dangerous.
public actor CryptoMetricsUploader {

    public static let shared = CryptoMetricsUploader()

    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "CryptoMetricsUploader")
    private let appVersion: String
    private let platform: String
    /// Reentrancy guard: `flush` suspends at the network await, so without
    /// this a second concurrent flush would snapshot the SAME un-subtracted
    /// counters and POST them again → server-side double-count.
    private var isFlushing = false
    /// Sends the encoded body and returns the HTTP status, or nil if the
    /// request could not be made (no credential, network failure). Injected
    /// so tests exercise the subtract-on-success logic without networking.
    private let send: (Data) async -> Int?

    /// Production initializer — POSTs through `WorkerAuthHelper` (Bearer or
    /// operator key) to the configured worker.
    public init(
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
        platform: String = "ios"
    ) {
        self.appVersion = appVersion
        self.platform = platform
        self.send = { body in
            let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
                ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
            guard let url = URL(string: "\(baseURL)/debug/crypto-metric") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            request.httpBody = body
            await WorkerAuthHelper.applyAuth(to: &request)
            // No credential attached ⇒ don't bother the server with a
            // guaranteed 401; treat as "couldn't send" so counts are kept.
            guard request.value(forHTTPHeaderField: "Authorization") != nil
                || request.value(forHTTPHeaderField: "X-API-Key") != nil else {
                return nil
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode
            } catch {
                return nil
            }
        }
    }

    /// Test seam — inject the send closure directly.
    init(appVersion: String, platform: String = "ios", send: @escaping (Data) async -> Int?) {
        self.appVersion = appVersion
        self.platform = platform
        self.send = send
    }

    /// Snapshot the metrics, POST them, and clear exactly the delivered
    /// counts on success. No-op when the snapshot is empty or a flush is
    /// already in flight (see `isFlushing`).
    public func flush(metrics: CryptoHardeningMetrics, now: Date = Date()) async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let snapshot = metrics.snapshot()
        guard let payload = CryptoMetricsPayload(
            snapshot: snapshot, platform: platform, appVersion: appVersion, timestamp: now
        ) else {
            return // empty snapshot — nothing to send
        }
        guard let body = try? JSONEncoder().encode(payload) else {
            logger.error("Failed to encode crypto metrics payload")
            return
        }
        let status = await send(body)
        switch status {
        case .some(let code) where (200...299).contains(code):
            // Delivered — remove exactly what we sent (keeps concurrent events).
            metrics.subtract(snapshot)
        case .some(400), .some(413):
            // Permanent client error: the same body can never succeed, so
            // retrying forever would wedge this device out of the soak. Drop.
            logger.error("Crypto metrics rejected (\(status ?? -1, privacy: .public)) — dropping non-retryable batch")
            metrics.subtract(snapshot)
        default:
            // Transient (5xx / 401 / 429 / nil no-credential) — retain the
            // counts so the next flush retries. Safe bias: never lose an
            // error-counter signal to a temporary failure.
            logger.debug("Crypto metrics upload not confirmed (status: \(String(describing: status), privacy: .public)); keeping counts for retry")
        }
    }
}
