import Foundation

/// Pure orchestration helper for migrating keychain items from the macOS legacy
/// (CSSM/file) keychain to the modern data-protection keychain.
///
/// All real Security-framework calls are injected via closures so the logic
/// can be unit-tested without touching the actual keychain.
///
/// ## Why this exists
/// `caff43a` added `kSecUseDataProtectionKeychain: true` to all keychain reads
/// to prevent the legacy-keychain path from blocking the main thread inside
/// securityd (critical for the headless CLI). The side effect on macOS is that
/// items previously saved without that flag become invisible to data-protection
/// queries. This helper transparently migrates them on first access inside a
/// real `.app` bundle (iOS or macOS app).
///
/// ## Bundle guard
/// The legacy keychain read itself is what hangs in a non-bundle CLI / xctest
/// runner. Therefore the legacy probe must ONLY execute inside a real `.app`
/// bundle. `canProbeLegacyKeychain` implements that guard by checking
/// `Bundle.main.bundleURL.pathExtension`.
enum KeychainMigration {

    /// True only when running inside a real .app bundle (iOS or macOS app),
    /// where probing the legacy macOS keychain is safe. False for the headless
    /// CLI and xctest runners, where a legacy keychain query can hang on securityd.
    static var canProbeLegacyKeychain: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Orchestrates: data-protection lookup → (if app bundle) legacy lookup → migrate.
    ///
    /// - Parameters:
    ///   - probeDataProtection: Query the data-protection keychain; return `nil` if not found.
    ///   - canProbeLegacy: Whether we're inside a `.app` bundle where legacy probes are safe.
    ///   - probeLegacy: Query the legacy keychain; return `nil` if not found.
    ///   - migrate: Write the recovered data into the data-protection keychain (best-effort;
    ///              the caller MUST NOT throw — errors are silently ignored by convention).
    /// - Returns: The found data, or `nil` if not present in either keychain.
    static func load(
        probeDataProtection: () -> Data?,
        canProbeLegacy: Bool,
        probeLegacy: () -> Data?,
        migrate: (Data) -> Void
    ) -> Data? {
        // Step 1: data-protection keychain — happy path (CLI, iOS, post-migration macOS).
        if let dp = probeDataProtection() { return dp }

        // Step 2: if we can't safely touch the legacy keychain (CLI / xctest), stop here.
        guard canProbeLegacy else { return nil }

        // Step 3: probe the legacy keychain — only reached inside a real .app bundle.
        guard let legacy = probeLegacy() else { return nil }

        // Step 4: migrate into the data-protection keychain (best-effort; still return
        // the data even if the write fails so the caller can proceed normally).
        migrate(legacy)
        return legacy
    }
}
