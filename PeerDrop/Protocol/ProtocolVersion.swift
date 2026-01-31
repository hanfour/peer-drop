import Foundation

enum ProtocolVersion: UInt8, Codable {
    case v1 = 1

    static let current: ProtocolVersion = .v1
}
