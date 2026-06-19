import Foundation

/// Process-global persistence mode. Default (nil) = keychain-backed identity +
/// at-rest key + unscoped stores — the iOS/macOS app behavior, UNCHANGED. The
/// headless CLI sets `fileStore` once at startup so its identity/at-rest key
/// persist as 0600 files (the non-bundle CLI can't use the keychain) and its
/// stores are namespaced per --name.
public enum PeerDropPersistence {
    public struct FileStore {
        public let directory: URL    // per-instance config dir (created 0700)
        public let namespace: String // sanitized, path/key-safe
        public init(directory: URL, namespace: String) {
            self.directory = directory
            self.namespace = namespace
        }
    }

    /// Set ONCE before any identity access (the CLI sets it before ConnectionManager()).
    public static var fileStore: FileStore?

    /// --name → a path/key-safe token (lowercased, [a-z0-9] kept, others → '-', collapsed, trimmed).
    public static func sanitize(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// Store key namespaced by the file-store namespace, else the base (app path unchanged).
    public static func scopedKey(_ base: String) -> String {
        guard let ns = fileStore?.namespace else { return base }
        return "\(base)-\(ns)"
    }

    /// Read raw key bytes from a 0600 file under the file-store directory.
    /// Returns nil when no fileStore is configured — callers must fall back to
    /// the keychain in that case.
    static func readKeyFile(_ name: String) -> Data? {
        guard let dir = fileStore?.directory else { return nil }
        let url = dir.appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    /// Write raw key bytes as a 0600 file under the file-store directory.
    /// Returns false (and writes nothing) when no fileStore is configured.
    @discardableResult
    static func writeKeyFile(_ name: String, _ data: Data) -> Bool {
        guard let dir = fileStore?.directory else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    static func deleteKeyFile(_ name: String) {
        guard let dir = fileStore?.directory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}
