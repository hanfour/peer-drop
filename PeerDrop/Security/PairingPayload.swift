import Foundation
import CryptoKit

struct PairingPayload {
    let publicKey: Data
    let signingPublicKey: Data
    let fingerprint: String
    let deviceName: String
    let localAddress: String?
    let relayCode: String?

    func toURL() -> URL? {
        var components = URLComponents()
        components.scheme = "peerdrop"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "pk", value: publicKey.base64EncodedString()),
            URLQueryItem(name: "spk", value: signingPublicKey.base64EncodedString()),
            URLQueryItem(name: "fp", value: fingerprint),
            URLQueryItem(name: "name", value: deviceName),
        ]
        if let local = localAddress {
            components.queryItems?.append(URLQueryItem(name: "local", value: local))
        }
        if let relay = relayCode {
            components.queryItems?.append(URLQueryItem(name: "relay", value: relay))
        }
        return components.url
    }

    init(
        publicKey: Data,
        signingPublicKey: Data,
        fingerprint: String,
        deviceName: String,
        localAddress: String? = nil,
        relayCode: String? = nil
    ) {
        self.publicKey = publicKey
        self.signingPublicKey = signingPublicKey
        self.fingerprint = fingerprint
        self.deviceName = deviceName
        self.localAddress = localAddress
        self.relayCode = relayCode
    }

    init(from url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "peerdrop",
              components.host == "pair",
              let items = components.queryItems else {
            throw PairingError.invalidURL
        }

        let dict = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let pkBase64 = dict["pk"],
              let pk = Data(base64Encoded: pkBase64),
              let spkBase64 = dict["spk"],
              let spk = Data(base64Encoded: spkBase64),
              let fp = dict["fp"],
              let name = dict["name"] else {
            throw PairingError.missingFields
        }

        self.publicKey = pk
        self.signingPublicKey = spk
        self.fingerprint = fp
        self.deviceName = name
        self.localAddress = dict["local"]
        self.relayCode = dict["relay"]
    }

    static func safetyNumber(myPublicKey: Data, peerPublicKey: Data) -> String {
        let sorted = [myPublicKey, peerPublicKey].sorted { $0.lexicographicallyPrecedes($1) }
        var combined = Data()
        combined.append(sorted[0])
        combined.append(sorted[1])
        let hash = SHA256.hash(data: combined)
        let bytes = Array(hash)
        let num1 = (Int(bytes[0]) << 8 | Int(bytes[1])) % 100000
        let num2 = (Int(bytes[2]) << 8 | Int(bytes[3])) % 100000
        return String(format: "%05d %05d", num1, num2)
    }

    enum PairingError: Error {
        case invalidURL
        case missingFields
    }
}
