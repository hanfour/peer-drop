import Foundation

struct DeviceGroup: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var deviceIDs: [String]

    init(id: String = UUID().uuidString, name: String, deviceIDs: [String] = []) {
        self.id = id
        self.name = name
        self.deviceIDs = deviceIDs
    }
}
