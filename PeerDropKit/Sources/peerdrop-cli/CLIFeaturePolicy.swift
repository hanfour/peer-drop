import Foundation

/// Process-wide feature switches for peerdrop-cli.
///
/// In the app, accepting a connection is the user's consent, so
/// `FileTransferSession` auto-accepts offers. In the CLI an accepted
/// connection is NOT trusted (unknown peers are accepted pending SAS, #166),
/// so anything that acts on peer data outside the input gate must be off:
/// file transfer (writes to disk), voice calls and clipboard sync. Chat stays
/// on — it carries the gated shell I/O.
///
/// The values go into the VOLATILE argument domain: highest precedence after
/// forced defaults (so a persisted `defaults write … true` can't re-enable
/// them) and never written to disk. `FeatureSettings` reads `UserDefaults.standard`.
enum CLIFeaturePolicy {
    static let disabledFeatureKeys = [
        "peerDropFileTransferEnabled",
        "peerDropVoiceCallEnabled",
        "peerDropClipboardSyncEnabled",
    ]

    static func apply(to defaults: UserDefaults) {
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in disabledFeatureKeys { domain[key] = false }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}
