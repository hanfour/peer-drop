#!/usr/bin/env swift
// sign-crypto-policy.swift
//
// Offline signer for SignedCryptoPolicy blobs. Reads an unsigned policy
// (just the {schemaVersion, issuedAt, expiresAt, policy} fields) plus a
// private-key file, and writes a fully-signed SignedCryptoPolicy JSON to
// stdout.
//
// Usage:
//   swift tools/sign-crypto-policy.swift <unsigned-policy.json> <signing-key.json>
//
// The output is suitable for upload to the Cloudflare worker via:
//   cat output.json | npx wrangler secret put CRYPTO_POLICY_JSON --env production
//
// Production signing keys live OFFLINE — never commit them. The dev key
// at cloudflare-worker/dev-signing-key.json is for staging only.

import Foundation
import CryptoKit

guard CommandLine.arguments.count == 3 else {
    let scriptName = CommandLine.arguments.first ?? "sign-crypto-policy.swift"
    FileHandle.standardError.write(Data(
        "usage: swift \(scriptName) <unsigned-policy.json> <signing-key.json>\n".utf8
    ))
    exit(64)
}

let policyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])

// MARK: - Key load

struct SigningKey: Codable {
    let private_key_base64: String
}

let keyData: Data
do {
    keyData = try Data(contentsOf: keyURL)
} catch {
    FileHandle.standardError.write(Data("error: cannot read key file at \(keyURL.path): \(error)\n".utf8))
    exit(65)
}

let signingKeyFile: SigningKey
do {
    signingKeyFile = try JSONDecoder().decode(SigningKey.self, from: keyData)
} catch {
    FileHandle.standardError.write(Data("error: cannot parse key file (expected {\"private_key_base64\": \"...\"}): \(error)\n".utf8))
    exit(65)
}

guard let privKeyBytes = Data(base64Encoded: signingKeyFile.private_key_base64) else {
    FileHandle.standardError.write(Data("error: private_key_base64 is not valid base64\n".utf8))
    exit(65)
}

let privKey: Curve25519.Signing.PrivateKey
do {
    privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privKeyBytes)
} catch {
    FileHandle.standardError.write(Data("error: cannot construct Ed25519 private key: \(error)\n".utf8))
    exit(65)
}

// MARK: - Policy load

let inputData: Data
do {
    inputData = try Data(contentsOf: policyURL)
} catch {
    FileHandle.standardError.write(Data("error: cannot read policy file at \(policyURL.path): \(error)\n".utf8))
    exit(65)
}

guard let inputDict = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
    FileHandle.standardError.write(Data("error: policy file is not a JSON object\n".utf8))
    exit(65)
}

// Required fields. The 4 we sign over.
let requiredKeys = ["schemaVersion", "issuedAt", "expiresAt", "policy"]
for k in requiredKeys {
    guard inputDict[k] != nil else {
        FileHandle.standardError.write(Data("error: policy file missing required field \"\(k)\"\n".utf8))
        exit(65)
    }
}

// MARK: - Canonical JSON of the signing payload

// Inline copy of CanonicalJSON.serialize logic — keeps the tool self-contained.
// Must agree byte-for-byte with PeerDrop/Security/CanonicalJSON.swift.
func canonicalize(_ v: Any) throws -> Any {
    switch v {
    case let dict as [String: Any]:
        var out: [String: Any] = [:]
        for (k, sub) in dict { out[k] = try canonicalize(sub) }
        return out
    case let arr as [Any]:
        return try arr.map { try canonicalize($0) }
    case is String, is Bool, is NSNull,
         is Int, is Int8, is Int16, is Int32, is Int64,
         is UInt, is UInt8, is UInt16, is UInt32, is UInt64,
         is Double, is Float:
        return v
    default:
        struct UnsupportedType: Error { let described: String }
        throw UnsupportedType(described: String(describing: type(of: v)))
    }
}

let payloadDict: [String: Any] = [
    "schemaVersion": inputDict["schemaVersion"]!,
    "issuedAt": inputDict["issuedAt"]!,
    "expiresAt": inputDict["expiresAt"]!,
    "policy": inputDict["policy"]!
]

let canonical: Data
do {
    let normalized = try canonicalize(payloadDict)
    canonical = try JSONSerialization.data(
        withJSONObject: normalized,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
} catch {
    FileHandle.standardError.write(Data("error: canonical-JSON serialization failed: \(error)\n".utf8))
    exit(65)
}

// MARK: - Sign

let sigBase64: String
do {
    let sig = try privKey.signature(for: canonical)
    sigBase64 = sig.base64EncodedString()
} catch {
    FileHandle.standardError.write(Data("error: Ed25519 signing failed: \(error)\n".utf8))
    exit(70)
}

// MARK: - Emit signed JSON to stdout

var outputDict = inputDict
outputDict["signature"] = sigBase64

let outputData: Data
do {
    outputData = try JSONSerialization.data(
        withJSONObject: outputDict,
        options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
    )
} catch {
    FileHandle.standardError.write(Data("error: cannot serialize signed output: \(error)\n".utf8))
    exit(70)
}

FileHandle.standardOutput.write(outputData)
FileHandle.standardOutput.write(Data("\n".utf8))
