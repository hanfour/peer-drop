import Foundation

enum KeyExchangeMessage: Codable {
    case hello(
        publicKey: Data,
        signingPublicKey: Data,
        fingerprint: String,
        deviceName: String
    )
    case verify(nonce: Data)
    case confirm(signature: Data)
    case keyChanged(oldFingerprint: String, newPublicKey: Data)

    private enum CodingKeys: String, CodingKey {
        case type, publicKey, signingPublicKey, fingerprint, deviceName
        case nonce, signature, oldFingerprint, newPublicKey
    }

    private enum MessageType: String, Codable {
        case hello, verify, confirm, keyChanged
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let pk, let spk, let fp, let name):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(pk, forKey: .publicKey)
            try container.encode(spk, forKey: .signingPublicKey)
            try container.encode(fp, forKey: .fingerprint)
            try container.encode(name, forKey: .deviceName)
        case .verify(let nonce):
            try container.encode(MessageType.verify, forKey: .type)
            try container.encode(nonce, forKey: .nonce)
        case .confirm(let sig):
            try container.encode(MessageType.confirm, forKey: .type)
            try container.encode(sig, forKey: .signature)
        case .keyChanged(let oldFp, let newPk):
            try container.encode(MessageType.keyChanged, forKey: .type)
            try container.encode(oldFp, forKey: .oldFingerprint)
            try container.encode(newPk, forKey: .newPublicKey)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .hello:
            self = .hello(
                publicKey: try container.decode(Data.self, forKey: .publicKey),
                signingPublicKey: try container.decode(Data.self, forKey: .signingPublicKey),
                fingerprint: try container.decode(String.self, forKey: .fingerprint),
                deviceName: try container.decode(String.self, forKey: .deviceName)
            )
        case .verify:
            self = .verify(nonce: try container.decode(Data.self, forKey: .nonce))
        case .confirm:
            self = .confirm(signature: try container.decode(Data.self, forKey: .signature))
        case .keyChanged:
            self = .keyChanged(
                oldFingerprint: try container.decode(String.self, forKey: .oldFingerprint),
                newPublicKey: try container.decode(Data.self, forKey: .newPublicKey)
            )
        }
    }
}
