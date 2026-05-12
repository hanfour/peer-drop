import Foundation
import UIKit
import os.log

/// Sends error reports to the Cloudflare Worker for remote debugging.
/// Reports are stored for 7 days and can be fetched with:
///   curl -H "X-API-Key: $KEY" https://peerdrop-signal.hanfourhuang.workers.dev/debug/reports
enum ErrorReporter {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ErrorReporter")

    /// Send an error report. Fire-and-forget — never blocks UI.
    static func report(
        error: String,
        context: String,
        extras: [String: String] = [:]
    ) {
        Task.detached(priority: .utility) {
            await send(error: error, context: context, extras: extras)
        }
    }

    private static func send(
        error: String,
        context: String,
        extras: [String: String]
    ) async {
        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard let url = URL(string: "\(baseURL)/debug/report") else { return }

        // UIDevice properties are @MainActor-isolated in Swift 6 — read them
        // once on the main actor instead of capturing UIDevice.current across
        // the async boundary.
        let deviceModel = await MainActor.run { UIDevice.current.model }
        let systemVersion = await MainActor.run { UIDevice.current.systemVersion }
        var body: [String: Any] = [
            "error": error,
            "context": context,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "device": deviceModel,
            "systemVersion": systemVersion,
        ]
        for (k, v) in extras { body[k] = v }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 201 {
                logger.info("Error report sent successfully")
            }
        } catch {
            logger.debug("Failed to send error report: \(error.localizedDescription)")
        }
    }
}
