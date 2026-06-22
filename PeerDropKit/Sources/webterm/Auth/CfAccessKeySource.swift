import JWTKit

/// Holds the current Cloudflare Access verification keys behind an actor so a background
/// refresher can swap them in atomically while requests read them concurrently.
public actor CfAccessKeySource {
    private var keys: JWTKeyCollection

    public init(_ keys: JWTKeyCollection) {
        self.keys = keys
    }

    /// Returns the current key collection for token verification.
    public func current() -> JWTKeyCollection { keys }

    /// Atomically replaces the key collection (called by the periodic refresher).
    public func replace(with newKeys: JWTKeyCollection) { keys = newKeys }
}
