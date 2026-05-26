import Foundation

public enum ProtocolVersion: UInt8, Codable {
    case v1 = 1

    public static let current: ProtocolVersion = .v1
}
