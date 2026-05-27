import Foundation
import Combine

@MainActor
public final class DeviceGroupStore: ObservableObject {
    @Published public var groups: [DeviceGroup] = []

    private let key = "peerDropDeviceGroups"

    init() {
        load()
    }

    public func add(name: String) {
        let group = DeviceGroup(name: name)
        groups.append(group)
        save()
    }

    public func remove(id: String) {
        groups.removeAll { $0.id == id }
        save()
    }

    public func update(_ group: DeviceGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
            save()
        }
    }

    public func addDevice(_ deviceID: String, toGroup groupID: String) {
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            if !groups[index].deviceIDs.contains(deviceID) {
                groups[index].deviceIDs.append(deviceID)
                save()
            }
        }
    }

    public func removeDevice(_ deviceID: String, fromGroup groupID: String) {
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].deviceIDs.removeAll { $0 == deviceID }
            save()
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DeviceGroup].self, from: data) else { return }
        groups = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
