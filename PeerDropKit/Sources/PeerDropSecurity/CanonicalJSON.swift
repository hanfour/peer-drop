import Foundation

/// Canonical JSON serializer — produces byte-stable output for any input
/// of supported types. The signing layer (`SecurityPolicyStore.parseSignedPolicy`
/// and `tools/sign-crypto-policy.swift`) feeds bytes from this serializer
/// into Ed25519 sign/verify, so the Swift and worker (TS) sides MUST agree
/// byte-for-byte on the encoding.
///
/// Conformance: subset of RFC 8785 (JCS). Specifically:
/// - Object keys sorted lexicographically (by raw UTF-8 bytes).
/// - No whitespace anywhere.
/// - Arrays preserve insertion order.
/// - Supported leaf types: `String`, `Int` / `Int64`, `UInt32` / `UInt64`,
///   `Bool`, `NSNull`. Other types (`Double`, `Float`, `Date`, custom)
///   must be pre-serialized to strings by the caller.
///
/// **`Double`/`Float` rejected by design.** Cross-language JSON
/// round-tripping of floats is unreliable (Swift may emit `1.5` while a
/// JS canonicalizer emits `1.5000000000000002`). The policy schema
/// currently has no float fields; if one is added later, format it as a
/// string at the caller side and adopt a full JCS number canonicalization
/// here.
public enum CanonicalJSON {

    public enum Error: Swift.Error {
        case unsupportedType(String)
    }

    /// Returns canonical UTF-8 bytes for `value`. Throws if `value` contains
    /// an unsupported leaf type at any depth.
    public static func serialize(_ value: Any) throws -> Data {
        let normalized = try canonicalize(value)
        // `JSONSerialization` with `.sortedKeys` writes object keys in
        // lexicographic UTF-16 order, which matches UTF-8 byte order for
        // ASCII keys. Policy schema uses ASCII keys only.
        return try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Recursively walks `value`, returning a new representation suitable for
    /// `JSONSerialization`. Throws on any unsupported leaf.
    private static func canonicalize(_ v: Any) throws -> Any {
        switch v {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, sub) in dict {
                out[k] = try canonicalize(sub)
            }
            return out
        case let arr as [Any]:
            return try arr.map { try canonicalize($0) }
        case is String, is Bool, is NSNull:
            return v
        case is Int, is Int8, is Int16, is Int32, is Int64,
             is UInt, is UInt8, is UInt16, is UInt32, is UInt64:
            return v
        case is Double, is Float:
            // Reject: cross-language float canonicalization is unreliable.
            // Caller must pre-format any float-valued field as a String.
            throw Error.unsupportedType("Double/Float — pre-format as String at the caller")
        default:
            throw Error.unsupportedType(String(describing: type(of: v)))
        }
    }
}
