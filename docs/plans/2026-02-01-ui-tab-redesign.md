# UI Tab Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform PeerDrop from single NavigationStack to 3-tab architecture with toolbar controls, grid/list toggle, device persistence, and search.

**Architecture:** Replace ContentView's state-based view switching with a TabView containing three tabs (Nearby/Connected/Library), each with its own NavigationStack. Add DeviceRecordStore for persistent device history. Auto-switch to Connected tab on connection.

**Tech Stack:** SwiftUI, UserDefaults (JSON persistence), @AppStorage, LazyVGrid

---

### Task 1: DeviceRecord Model

**Files:**
- Create: `PeerDrop/Core/DeviceRecord.swift`

**Step 1: Create the model**

```swift
import Foundation

enum SortMode: String, CaseIterable {
    case name
    case lastConnected
    case connectionCount
}

struct DeviceRecord: Identifiable, Codable, Hashable {
    let id: String
    var displayName: String
    var sourceType: String
    var host: String?
    var port: UInt16?
    var lastConnected: Date
    var connectionCount: Int

    var relativeLastConnected: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastConnected, relativeTo: Date())
    }
}
```

**Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tail -3`
Expected: Build Succeeded

---

### Task 2: DeviceRecordStore Persistence

**Files:**
- Create: `PeerDrop/Core/DeviceRecordStore.swift`

**Step 1: Create the store**

```swift
import Foundation
import SwiftUI

@MainActor
final class DeviceRecordStore: ObservableObject {
    @Published var records: [DeviceRecord] = []

    private let key = "peerDropDeviceRecords"

    init() {
        load()
    }

    func addOrUpdate(id: String, displayName: String, sourceType: String, host: String?, port: UInt16?) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].displayName = displayName
            records[index].lastConnected = Date()
            records[index].connectionCount += 1
            if let h = host { records[index].host = h }
            if let p = port { records[index].port = p }
        } else {
            let record = DeviceRecord(
                id: id,
                displayName: displayName,
                sourceType: sourceType,
                host: host,
                port: port,
                lastConnected: Date(),
                connectionCount: 1
            )
            records.append(record)
        }
        save()
    }

    func remove(id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    func sorted(by mode: SortMode) -> [DeviceRecord] {
        switch mode {
        case .name:
            return records.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .lastConnected:
            return records.sorted { $0.lastConnected > $1.lastConnected }
        case .connectionCount:
            return records.sorted { $0.connectionCount > $1.connectionCount }
        }
    }

    func search(query: String) -> [DeviceRecord] {
        guard !query.isEmpty else { return records }
        return records.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
```

**Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tail -3`

---

### Task 3: DeviceRecordStore Unit Tests

**Files:**
- Create: `PeerDropTests/DeviceRecordStoreTests.swift`

**Step 1: Write tests**

```swift
import XCTest
@testable import PeerDrop

@MainActor
final class DeviceRecordStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceRecords")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceRecords")
        super.tearDown()
    }

    func testAddNewRecord() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].displayName, "iPhone")
        XCTAssertEqual(store.records[0].connectionCount, 1)
    }

    func testUpdateExistingRecord() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "peer1", displayName: "iPhone 15", sourceType: "bonjour", host: nil, port: nil)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].displayName, "iPhone 15")
        XCTAssertEqual(store.records[0].connectionCount, 2)
    }

    func testRemoveRecord() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        store.remove(id: "peer1")
        XCTAssertTrue(store.records.isEmpty)
    }

    func testPersistence() {
        let store1 = DeviceRecordStore()
        store1.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        let store2 = DeviceRecordStore()
        XCTAssertEqual(store2.records.count, 1)
        XCTAssertEqual(store2.records[0].displayName, "iPhone")
    }

    func testSortByName() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "b", displayName: "Bravo", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "a", displayName: "Alpha", sourceType: "bonjour", host: nil, port: nil)
        let sorted = store.sorted(by: .name)
        XCTAssertEqual(sorted[0].displayName, "Alpha")
        XCTAssertEqual(sorted[1].displayName, "Bravo")
    }

    func testSortByConnectionCount() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "a", displayName: "Alpha", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "b", displayName: "Bravo", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "b", displayName: "Bravo", sourceType: "bonjour", host: nil, port: nil)
        let sorted = store.sorted(by: .connectionCount)
        XCTAssertEqual(sorted[0].displayName, "Bravo")
    }

    func testSearchFilter() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "a", displayName: "iPhone 15", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "b", displayName: "MacBook", sourceType: "manual", host: "10.0.0.1", port: 9000)
        XCTAssertEqual(store.search(query: "mac").count, 1)
        XCTAssertEqual(store.search(query: "").count, 2)
    }

    func testManualPeerStoresHostPort() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "10.0.0.1:9000", displayName: "Server", sourceType: "manual", host: "10.0.0.1", port: 9000)
        XCTAssertEqual(store.records[0].host, "10.0.0.1")
        XCTAssertEqual(store.records[0].port, 9000)
    }
}
```

**Step 2: Run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PeerDropTests/DeviceRecordStoreTests -quiet 2>&1 | grep "Executed"`

---

### Task 4: Integrate DeviceRecordStore into ConnectionManager

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift`

**Changes:**
1. Add property: `let deviceStore = DeviceRecordStore()`
2. In `acceptConnection()` after `transition(to: .connected)`: record the device
3. In `handleMessage(.connectionAccept)` after `transition(to: .connected)`: record the device
4. Helper method to extract peer info and call `deviceStore.addOrUpdate()`

**Step 1: Add deviceStore property**

After `private(set) var voiceCallManager: VoiceCallManager?`, add:
```swift
let deviceStore = DeviceRecordStore()
```

**Step 2: Add recording helper**

After `configureVoiceCalling()`, add:
```swift
private func recordConnectedDevice() {
    guard let peer = connectedPeer else { return }
    let sourceType: String
    let host: String?
    let port: UInt16?
    if let lastPeer = lastConnectedPeer {
        switch lastPeer.source {
        case .bonjour: sourceType = "bonjour"
        case .manual: sourceType = "manual"
        }
        switch lastPeer.endpoint {
        case .manual(let h, let p):
            host = h; port = p
        case .bonjour:
            host = nil; port = nil
        }
    } else {
        sourceType = "bonjour"; host = nil; port = nil
    }
    let id = lastConnectedPeer?.id ?? peer.id
    deviceStore.addOrUpdate(id: id, displayName: peer.displayName, sourceType: sourceType, host: host, port: port)
}
```

**Step 3: Call in acceptConnection()**

After `transition(to: .connected)` in `acceptConnection()`, add:
```swift
recordConnectedDevice()
```

**Step 4: Call in handleMessage(.connectionAccept)**

After `transition(to: .connected)` in `handleMessage()`, add:
```swift
recordConnectedDevice()
```

**Step 5: Build and run all tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PeerDropTests -quiet 2>&1 | grep "Executed"`

---

### Task 5: PeerGridItemView Component

**Files:**
- Create: `PeerDrop/UI/Components/PeerGridItemView.swift`

```swift
import SwiftUI

struct PeerGridItemView: View {
    let peer: DiscoveredPeer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                PeerAvatar(name: peer.displayName)
                    .scaleEffect(1.5)
                    .frame(width: 60, height: 60)

                Text(peer.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(peer.displayName)
        .accessibilityHint("Tap to connect")
    }
}
```

---

### Task 6: DeviceRecordRow Component

**Files:**
- Create: `PeerDrop/UI/Library/DeviceRecordRow.swift`

```swift
import SwiftUI

struct DeviceRecordRow: View {
    let record: DeviceRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PeerAvatar(name: record.displayName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text(record.relativeLastConnected)
                        Text("·")
                        Text("\(record.connectionCount) connections")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: record.sourceType == "manual" ? "network" : "wifi")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityLabel("\(record.displayName), \(record.relativeLastConnected), \(record.connectionCount) connections")
    }
}
```

---

### Task 7: NearbyTab View

**Files:**
- Create: `PeerDrop/UI/Discovery/NearbyTab.swift`

```swift
import SwiftUI

struct NearbyTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @AppStorage("peerDropViewMode") private var isGridMode = false
    @AppStorage("peerDropSortMode") private var sortModeRaw = "name"
    @State private var showManualConnect = false
    @State private var showSettings = false
    @State private var showTransferHistory = false

    private var sortMode: SortMode {
        SortMode(rawValue: sortModeRaw) ?? .name
    }

    private var sortedPeers: [DiscoveredPeer] {
        let peers = connectionManager.discoveredPeers
        switch sortMode {
        case .name:
            return peers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .lastConnected:
            let records = connectionManager.deviceStore.records
            return peers.sorted { p1, p2 in
                let r1 = records.first { $0.id == p1.id }
                let r2 = records.first { $0.id == p2.id }
                return (r1?.lastConnected ?? .distantPast) > (r2?.lastConnected ?? .distantPast)
            }
        case .connectionCount:
            let records = connectionManager.deviceStore.records
            return peers.sorted { p1, p2 in
                let r1 = records.first { $0.id == p1.id }
                let r2 = records.first { $0.id == p2.id }
                return (r1?.connectionCount ?? 0) > (r2?.connectionCount ?? 0)
            }
        }
    }

    var body: some View {
        ZStack {
            Group {
                if connectionManager.discoveredPeers.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for nearby devices...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isGridMode {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                            ForEach(sortedPeers) { peer in
                                PeerGridItemView(peer: peer) {
                                    connectionManager.requestConnection(to: peer)
                                }
                                .disabled(isConnecting)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        connectionManager.restartDiscovery()
                    }
                } else {
                    List {
                        Section {
                            ForEach(sortedPeers) { peer in
                                PeerRowView(peer: peer) {
                                    connectionManager.requestConnection(to: peer)
                                }
                                .disabled(isConnecting)
                            }
                        } header: {
                            HStack {
                                Text("Nearby Devices")
                                Spacer()
                                Text("\(connectionManager.discoveredPeers.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                            }
                        }

                        if let error = connectionManager.certificateManager.setupError {
                            Section {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Security Degraded")
                                            .font(.subheadline.bold())
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: connectionManager.discoveredPeers)
                    .refreshable {
                        connectionManager.restartDiscovery()
                    }
                }
            }

            if isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(connectingLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isConnecting)
        .navigationTitle("PeerDrop")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showManualConnect = true
                } label: {
                    Image(systemName: "bolt.horizontal.fill")
                }
                .accessibilityLabel("Quick Connect")

                Button {
                    isGridMode.toggle()
                } label: {
                    Image(systemName: isGridMode ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(isGridMode ? "Switch to list" : "Switch to grid")

                Menu {
                    Section("Sort By") {
                        Button {
                            sortModeRaw = SortMode.name.rawValue
                        } label: {
                            Label("Name", systemImage: sortMode == .name ? "checkmark" : "")
                        }
                        Button {
                            sortModeRaw = SortMode.lastConnected.rawValue
                        } label: {
                            Label("Last Connected", systemImage: sortMode == .lastConnected ? "checkmark" : "")
                        }
                        Button {
                            sortModeRaw = SortMode.connectionCount.rawValue
                        } label: {
                            Label("Connection Count", systemImage: sortMode == .connectionCount ? "checkmark" : "")
                        }
                    }
                    Section {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button {
                            showTransferHistory = true
                        } label: {
                            Label("Transfer History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showManualConnect) {
            ManualConnectView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showTransferHistory) {
            NavigationStack {
                TransferHistoryView()
                    .environmentObject(connectionManager)
            }
        }
        .onAppear {
            if case .idle = connectionManager.state {
                connectionManager.startDiscovery()
            }
        }
        .onChange(of: connectionManager.discoveredPeers.count) { _ in
            if !connectionManager.discoveredPeers.isEmpty {
                HapticManager.peerDiscovered()
            }
        }
    }

    private var isConnecting: Bool {
        switch connectionManager.state {
        case .requesting, .connecting: return true
        default: return false
        }
    }

    private var connectingLabel: String {
        switch connectionManager.state {
        case .requesting: return "Requesting connection..."
        case .connecting: return "Connecting..."
        default: return ""
        }
    }
}
```

---

### Task 8: ConnectedTab View

**Files:**
- Create: `PeerDrop/UI/Connection/ConnectedTab.swift`

```swift
import SwiftUI

struct ConnectedTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    private var isConnected: Bool {
        switch connectionManager.state {
        case .connected, .transferring, .voiceCall: return true
        default: return false
        }
    }

    private var recentRecords: [DeviceRecord] {
        connectionManager.deviceStore.sorted(by: .lastConnected)
    }

    var body: some View {
        Group {
            if isConnected {
                ConnectionView()
            } else if recentRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No active connection")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Connect to a device from the Nearby tab")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No active connection")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    Section("Recent Connections") {
                        ForEach(recentRecords) { record in
                            DeviceRecordRow(record: record) {
                                reconnect(record: record)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Connected")
    }

    private func reconnect(record: DeviceRecord) {
        let peer = connectionManager.discoveredPeers.first { $0.id == record.id }
        if let peer = peer {
            connectionManager.requestConnection(to: peer)
        } else if let host = record.host, let port = record.port {
            connectionManager.addManualPeer(host: host, port: port, name: record.displayName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let peer = connectionManager.discoveredPeers.first(where: { $0.id == record.id }) {
                    connectionManager.requestConnection(to: peer)
                }
            }
        }
    }
}
```

---

### Task 9: LibraryTab View

**Files:**
- Create: `PeerDrop/UI/Library/LibraryTab.swift`

```swift
import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var searchQuery = ""

    private var filteredRecords: [DeviceRecord] {
        let store = connectionManager.deviceStore
        if searchQuery.isEmpty {
            return store.sorted(by: .lastConnected)
        }
        return store.search(query: searchQuery).sorted { $0.lastConnected > $1.lastConnected }
    }

    var body: some View {
        Group {
            if connectionManager.deviceStore.records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No saved devices")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Devices you connect to will appear here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredRecords) { record in
                        DeviceRecordRow(record: record) {
                            reconnect(record: record)
                        }
                    }
                    .onDelete { indexSet in
                        let records = filteredRecords
                        for index in indexSet {
                            connectionManager.deviceStore.remove(id: records[index].id)
                        }
                    }
                }
                .searchable(text: $searchQuery, prompt: "Search devices")
            }
        }
        .navigationTitle("Library")
    }

    private func reconnect(record: DeviceRecord) {
        let peer = connectionManager.discoveredPeers.first { $0.id == record.id }
        if let peer = peer {
            connectionManager.requestConnection(to: peer)
        } else if let host = record.host, let port = record.port {
            connectionManager.addManualPeer(host: host, port: port, name: record.displayName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let peer = connectionManager.discoveredPeers.first(where: { $0.id == record.id }) {
                    connectionManager.requestConnection(to: peer)
                }
            }
        }
    }
}
```

---

### Task 10: Redesign ContentView with TabView

**Files:**
- Modify: `PeerDrop/UI/ContentView.swift`

**Replace entire file with:**

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var selectedTab = 0
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showShareSheet = false
    @State private var receivedFileURL: URL?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                NearbyTab()
            }
            .tabItem {
                Label("Nearby", systemImage: "wifi")
            }
            .tag(0)

            NavigationStack {
                ConnectedTab()
            }
            .tabItem {
                Label("Connected", systemImage: "link")
            }
            .tag(1)

            NavigationStack {
                LibraryTab()
            }
            .tabItem {
                Label("Library", systemImage: "archivebox")
            }
            .tag(2)
        }
        .sheet(item: $connectionManager.pendingIncomingRequest) { request in
            ConsentSheet(request: request)
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $connectionManager.showTransferProgress) {
            TransferProgressView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $connectionManager.showVoiceCall) {
            VoiceCallView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = receivedFileURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Connection Error", isPresented: $showError) {
            if connectionManager.canReconnect {
                Button("Reconnect") {
                    connectionManager.reconnect()
                }
            }
            Button("Back to Discovery", role: .cancel) {
                connectionManager.transition(to: .discovering)
                connectionManager.restartDiscovery()
                selectedTab = 0
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .onChange(of: connectionManager.state) { _ in
            switch connectionManager.state {
            case .connected, .transferring, .voiceCall:
                selectedTab = 1
            case .failed(let reason):
                errorMessage = reason
                showError = true
            case .rejected:
                errorMessage = "The peer declined your connection request."
                showError = true
            default:
                break
            }
        }
        .onChange(of: connectionManager.fileTransfer?.receivedFileURL) { _ in
            if let url = connectionManager.fileTransfer?.receivedFileURL {
                receivedFileURL = url
                showShareSheet = true
                connectionManager.fileTransfer?.receivedFileURL = nil
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
```

---

### Task 11: Clean Up Old Views

**Files:**
- Modify: `PeerDrop/UI/Connection/ConnectionView.swift` — Remove transfer history toolbar (moved to NearbyTab More menu)
- Keep: `PeerDrop/UI/Discovery/DiscoveryView.swift` — No longer used as standalone, but keep for now (NearbyTab replaces it)

**ConnectionView changes:**
Remove the entire `.toolbar` block:
```swift
// DELETE THIS:
.toolbar {
    ToolbarItem(placement: .navigationBarTrailing) {
        NavigationLink {
            TransferHistoryView()
                .environmentObject(connectionManager)
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
    }
}
```

Also remove `.navigationTitle("Connection")` and `.navigationBarTitleDisplayMode(.inline)` since the ConnectedTab parent handles the title.

---

### Task 12: Update UI Tests

**Files:**
- Modify: `PeerDropUITests/ConsentFlowUITests.swift`
- Modify: `PeerDropUITests/ScreenshotTests.swift`

**ConsentFlowUITests changes:**
- Change `app.navigationBars["PeerDrop"]` to wait for the tab bar instead
- Update button references for tab-based navigation

**ScreenshotTests changes:**
- Update navigation bar references
- Add tab switching screenshots

---

### Task 13: Build, Test, Verify

**Step 1: Regenerate project**
Run: `xcodegen generate`

**Step 2: Build**
Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`

**Step 3: Run all unit tests**
Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PeerDropTests`

**Step 4: Run UI tests**
Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PeerDropUITests`

**Step 5: Simulator screenshot verification**

**Step 6: Commit**
```bash
git add -A && git commit -m "Redesign UI with 3-tab architecture, grid/list toggle, device persistence, and search"
```
