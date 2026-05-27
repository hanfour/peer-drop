import Foundation

public struct DeviceGroup: Identifiable, Codable, Hashable {
    public let id: String
    public var name: String
    public var deviceIDs: [String]

    public init(id: String = UUID().uuidString, name: String, deviceIDs: [String] = []) {
        self.id = id
        self.name = name
        self.deviceIDs = deviceIDs
    }
}
