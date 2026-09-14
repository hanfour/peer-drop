# 子專案 0：寵物系統移除 — 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 從 iOS、macOS、Widget、PeerDropKit、Scripts、CI 與商店資料中完整移除寵物養成（Neo-Egg / PeerDropPet），並在首次啟動清除使用者裝置與 iCloud 上的寵物殘留資料，讓 repo 成為乾淨的地基供子專案 1–3 建構。

**Architecture:** 先把非寵物模組（Core、CLI、Security）與寵物解耦並新增 `LegacyPetDataCleanup`，再依序拆 iOS app、Widget、Mac app 的耦合點，最後刪除 `PeerDropPet` 模組本體與素材。每個任務結束時對應的建置閘（`swift build` 或 `xcodebuild`）必須通過。CI 補一個不簽章的 iOS + macOS `xcodebuild` job，杜絕「出貨物 ≠ repo」回歸。

**Tech Stack:** Swift 5.9、SwiftUI、SwiftPM（PeerDropKit）、XcodeGen 2.45（`project.yml`）、XCTest、GitHub Actions（macos-15）、fastlane、Apple String Catalog（`.xcstrings`）。

**Spec:** `docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md` §0（決策）、§1（現況）、§6 子專案 0 列、§8（上架影響）、§9（風險：寵物移除為破壞性變更）。

## Global Constraints

- 平台下限：iOS 16.0、macOS 14.0（`project.yml` `deploymentTarget`），Swift 5.9。
- 分支：從 `main` 開 `feat/remove-pet`。**注意**：開放中的 `fix/arch-review-2026-08` 分支也改到 `ConnectionManager.swift`、`ChatManager.swift`、`TrustedContact.swift`；後併入者需 rebase，衝突僅限本計畫改動的回呼與欄位那幾行。
- Commit 格式：`type: short description`（`refactor` / `feat` / `chore` / `ci` / `i18n` / `docs`），結尾附：
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WwzkHxSjp7ou9MgGct5irQ
  ```
- 新增或刪除 `.swift` 檔後、以及每次改 `project.yml` 後，**必須** `xcodegen generate`。
- 建置閘指令（下列任務的「Run」直接引用）：
  - Kit：`cd PeerDropKit && swift build`
  - Kit 測試：`cd PeerDropKit && swift test --filter <TestClass>`
  - iOS：`xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
  - Mac：`xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' -quiet`
  - 若 `xcodebuild` 出現與 SourceKit 或 explicit-modules 相關的鬼錯誤（「Cannot find type」但 `swift build` 成功），先 `rm -rf ~/Library/Developer/Xcode/DerivedData/PeerDrop-*` 再重跑。
- 五語系：en、zh-Hant、zh-Hans、ja、ko。新字串必須五語齊全。
- 本計畫**保留** iCloud container、ubiquity KVS 與 app group 的 entitlement 各一版，因為 `LegacyPetDataCleanup` 需要它們才能清掉 iCloud 與 app group 的殘留。移除這些 entitlement 排進子專案 1。
- `docs/pet-design/` 以 `git rm` 移出 repo；歷史仍保留在 git log，不需另行備份。
- 不在本計畫範圍：重拍商店截圖、送審、刪除 `origin/badges` 分支（三者為併入 main 後的 operator 步驟，列在最後的「併入後 operator 清單」）。

---

## 檔案總覽

**新增**
- `PeerDropKit/Sources/PeerDropCore/LegacyPetDataCleanup.swift` — 一次性清除寵物殘留資料（本機、app group、iCloud Documents、iCloud KVS、UserDefaults）。
- `PeerDropKit/Tests/PeerDropCoreTests/LegacyPetDataCleanupTests.swift`
- `PeerDropKit/Tests/PeerDropSecurityTests/TrustedContactLegacyPetSnapshotTests.swift` — 舊檔含 `petSnapshot` 仍可解碼的回歸護欄。

**修改**
- `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（回呼改名）、`ChatManager.swift`（移除回呼）、`ScreenshotModeProvider.swift`（移除 mockPetState）
- `PeerDropKit/Sources/peerdrop-cli/Entry.swift`（回呼改名）
- `PeerDropKit/Sources/PeerDropSecurity/TrustedContact.swift`（移除 `petSnapshot`）
- `PeerDropKit/Sources/PeerDropPlatform/PlatformGraphicsRenderer.swift`（註解）
- `PeerDropKit/Package.swift`
- `PeerDrop/App/PeerDropApp.swift`、`PeerDrop/App/Info.plist`、`PeerDrop/UI/ContentView.swift`、`PeerDrop/UI/Chat/ChatView.swift`、`PeerDrop/UI/Security/VerificationView.swift`、`PeerDrop/App/Localizable.xcstrings`
- `PeerDropMac/App/PeerDropMacApp.swift`、`PeerDropMac/App/MacAppDelegate.swift`、`PeerDropMac/Views/MacSidebar.swift`、`MacDetailRouter.swift`、`PeerDropCommands.swift`、`MenuBarContent.swift`、`MacChatWindow.swift`
- `PeerDropMacUITests/MacSnapshotTests.swift`、`MacSnapshotTestsDark.swift`
- `project.yml`、`fastlane/Fastfile`、`fastlane/Snapfile`、`fastlane/SnapfileMac`、`fastlane/metadata/*/release_notes.txt`
- `.github/workflows/ci.yml`、`README.md`、`CHANGELOG.md`

**刪除**
- `PeerDropKit/Sources/PeerDropPet/`（66 檔 + 36 MB `Resources/Pets`）、`PeerDropKit/Tests/PeerDropPetTests/`
- `PeerDrop/Pet/`（14 檔）、`PeerDropMac/Views/PetSectionView.swift`
- `PeerDropWidget/`（整個 target）
- `PeerDropTests/{FoodInventoryTests,InteractionTrackerTests,PetWelcomeFlagTests,SharedPetStateTests,SpriteSheetLoaderTests,V4UpgradeOnboardingTests,V5UpgradeOnboardingTests}.swift`
- `PeerDropUITests/Snapshots/{PetSnapshotTests,PetSnapshotTestsDark}.swift`
- `.github/workflows/asset-coverage-badge.yml`
- `Scripts/` 內 21 個寵物管線檔（Task 9 列出）
- `docs/pet-design/`、`fastlane/screenshots_mac/*/04_Pet.png`

---

### Task 1: Core 與 CLI 解耦 — 回呼改名、移除聊天寵物回呼

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift:209-210`, `:594`, `:627`
- Modify: `PeerDropKit/Sources/PeerDropCore/ChatManager.swift:28`, `:97`
- Modify: `PeerDropKit/Sources/peerdrop-cli/Entry.swift:95`

**Interfaces:**
- Consumes: 無。
- Produces: `ConnectionManager.onPeerConnected: ((String) -> Void)?` 與 `ConnectionManager.onPeerDisconnected: ((String) -> Void)?`（取代 `onPeerConnectedForPet` / `onPeerDisconnectedForPet`；語意與觸發點不變）。`ChatManager.onMessageReceivedForPet` 移除（無非寵物消費者）。

- [ ] **Step 1: 改名 ConnectionManager 的兩個回呼宣告**

把 `ConnectionManager.swift:209-210`

```swift
    public var onPeerConnectedForPet: ((String) -> Void)?
    public var onPeerDisconnectedForPet: ((String) -> Void)?
```

改為

```swift
    /// Fires on the main actor once a peer's data channel is up and the
    /// receive loop has started. Consumer today: peerdrop-cli (replays
    /// buffered process output to a reconnecting peer).
    public var onPeerConnected: ((String) -> Void)?
    /// Fires on the main actor after a peer has been fully torn down.
    public var onPeerDisconnected: ((String) -> Void)?
```

- [ ] **Step 2: 改兩個呼叫點**

`ConnectionManager.swift:594` 的 `onPeerConnectedForPet?(peerID)` → `onPeerConnected?(peerID)`；
`ConnectionManager.swift:627` 的 `onPeerDisconnectedForPet?(peerID)` → `onPeerDisconnected?(peerID)`。

- [ ] **Step 3: 移除 ChatManager 的寵物回呼**

刪除 `ChatManager.swift:28` 的 `    public var onMessageReceivedForPet: (() -> Void)?` 與 `:97` 的 `        onMessageReceivedForPet?()`。

- [ ] **Step 4: 更新 CLI**

`PeerDropKit/Sources/peerdrop-cli/Entry.swift:95` 的 `cm.onPeerConnectedForPet = { [weak session] peerID in` → `cm.onPeerConnected = { [weak session] peerID in`。

- [ ] **Step 5: 建置 Kit 並確認 Kit 內無殘留**

Run: `cd PeerDropKit && swift build && grep -rn "ForPet" Sources/PeerDropCore Sources/peerdrop-cli Sources/webterm Tests/PeerDropCoreTests Tests/PeerDropCLITests; echo "exit=$?"`
Expected: `swift build` 成功；grep 無輸出且 `exit=1`。（`PeerDropPet` 目錄此時仍在，Task 7 才刪。）（iOS/Mac app 此時尚未改，暫時不建置 app。）

- [ ] **Step 6: Commit**

```bash
git add PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift PeerDropKit/Sources/PeerDropCore/ChatManager.swift PeerDropKit/Sources/peerdrop-cli/Entry.swift
git commit -m "refactor(core): rename peer lifecycle hooks, drop chat pet hook"
```

---

### Task 2: Security 與 ScreenshotModeProvider 解耦 — 移除 `petSnapshot` 與 `mockPetState`

**Files:**
- Test: `PeerDropKit/Tests/PeerDropSecurityTests/TrustedContactLegacyPetSnapshotTests.swift`（新增）
- Modify: `PeerDropKit/Sources/PeerDropSecurity/TrustedContact.swift:14`, `:41`, `:55`, `:74`
- Modify: `PeerDropKit/Sources/PeerDropCore/ScreenshotModeProvider.swift:5`, `:307-375`
- Modify: `PeerDropKit/Package.swift:49-60`

**Interfaces:**
- Consumes: 無。
- Produces: `TrustedContact` 不再有 `petSnapshot` 欄位；`init` 不再接受 `petSnapshot:` 參數。`ScreenshotModeProvider.mockPetState` 移除。`PeerDropCore` 不再依賴 `PeerDropPet`。

- [ ] **Step 1: 寫失敗的測試（舊檔相容）**

建立 `PeerDropKit/Tests/PeerDropSecurityTests/TrustedContactLegacyPetSnapshotTests.swift`：

```swift
import XCTest
@testable import PeerDropSecurity

/// Pivot 2026-09: `petSnapshot` was removed from `TrustedContact`. Records
/// persisted by v4–v5 still carry the key; they must keep decoding, and a
/// re-encode must not resurrect it.
final class TrustedContactLegacyPetSnapshotTests: XCTestCase {

    private func legacyJSON() -> Data {
        let key = Data(repeating: 0x42, count: 32).base64EncodedString()
        return """
        {
          "id": "7B4F1C2A-0000-4000-8000-000000000001",
          "displayName": "Old Peer",
          "identityPublicKey": "\(key)",
          "trustLevel": "linked",
          "firstConnected": 0,
          "petSnapshot": "3q2+7w=="
        }
        """.data(using: .utf8)!
    }

    func testLegacyRecordWithPetSnapshotStillDecodes() throws {
        let contact = try JSONDecoder().decode(TrustedContact.self, from: legacyJSON())
        XCTAssertEqual(contact.displayName, "Old Peer")
        XCTAssertEqual(contact.trustLevel, .linked)
        XCTAssertEqual(contact.identityPublicKey.count, 32)
        XCTAssertFalse(contact.isBlocked)
        XCTAssertTrue(contact.keyHistory.isEmpty)
    }

    func testReencodedRecordDoesNotContainPetSnapshot() throws {
        let contact = try JSONDecoder().decode(TrustedContact.self, from: legacyJSON())
        let out = try JSONEncoder().encode(contact)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertFalse(text.contains("petSnapshot"), "petSnapshot must not be re-encoded: \(text)")
    }
}
```

- [ ] **Step 2: 跑測試確認第二個測試失敗**

Run: `cd PeerDropKit && swift test --filter TrustedContactLegacyPetSnapshotTests`
Expected: `testLegacyRecordWithPetSnapshotStillDecodes` PASS；`testReencodedRecordDoesNotContainPetSnapshot` FAIL（目前會把 `petSnapshot` 重新編碼出來）。

- [ ] **Step 3: 從 TrustedContact 移除欄位**

在 `TrustedContact.swift` 刪除以下四行（其餘不動）：

```swift
    public var petSnapshot: Data?                   // Future: peer's pet snapshot
```
```swift
        petSnapshot: Data? = nil,
```
```swift
        self.petSnapshot = petSnapshot
```
```swift
        self.petSnapshot = try c.decodeIfPresent(Data.self, forKey: .petSnapshot)
```

`CodingKeys` 由編譯器合成，移除屬性後 `.petSnapshot` key 自動消失；解碼時多餘的 JSON key 會被忽略。

- [ ] **Step 4: 跑測試確認通過**

Run: `cd PeerDropKit && swift test --filter TrustedContactLegacyPetSnapshotTests`
Expected: 2 tests PASS。

- [ ] **Step 5: 移除 ScreenshotModeProvider 的寵物假資料**

在 `PeerDropKit/Sources/PeerDropCore/ScreenshotModeProvider.swift`：
1. 刪除第 5 行 `import PeerDropPet`。
2. 刪除從 `    // MARK: - Mock Pet State` 起到 `mockPetState` 計算屬性結尾的整段（原 307–375 行，含 `return PetState(...)` 與其後的 `    }`）。保留其後的 `    // MARK: - Check if a peer ID is mock`。

- [ ] **Step 6: 移除 PeerDropCore 對 PeerDropPet 的相依**

`PeerDropKit/Package.swift` 的 `PeerDropCore` target：

```swift
        // PeerDropCore is the keystone — depends on all 4 leaf modules.
        // Per spec §1: "Core consumes Transport/Security/Protocol/Pet";
        // strict single-direction (no cycles).
        .target(
            name: "PeerDropCore",
            dependencies: [
                "PeerDropPlatform",
                "PeerDropTransport",
                "PeerDropSecurity",
                "PeerDropProtocol",
                "PeerDropPet",
            ]
        ),
```

改為

```swift
        // PeerDropCore is the keystone — depends on the 4 leaf modules
        // (Platform/Transport/Security/Protocol); strict single-direction.
        .target(
            name: "PeerDropCore",
            dependencies: [
                "PeerDropPlatform",
                "PeerDropTransport",
                "PeerDropSecurity",
                "PeerDropProtocol",
            ]
        ),
```

- [ ] **Step 7: 建置 Kit 並跑 Security 測試**

Run: `cd PeerDropKit && swift build && swift test --filter "TrustedContact"`
Expected: 建置成功；`TrustedContactKeyHistoryTests`、`TrustedContactPeerVersionTests`、`TrustedContactLegacyPetSnapshotTests` 全 PASS。

- [ ] **Step 8: Commit**

```bash
git add PeerDropKit/Sources/PeerDropSecurity/TrustedContact.swift PeerDropKit/Sources/PeerDropCore/ScreenshotModeProvider.swift PeerDropKit/Package.swift PeerDropKit/Tests/PeerDropSecurityTests/TrustedContactLegacyPetSnapshotTests.swift
git commit -m "refactor(kit): drop TrustedContact.petSnapshot and screenshot pet mock; Core no longer depends on Pet"
```

---

### Task 3: `LegacyPetDataCleanup` — 首次啟動清除寵物殘留

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/LegacyPetDataCleanup.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/LegacyPetDataCleanupTests.swift`

**Interfaces:**
- Consumes: 無。
- Produces:
  ```swift
  public protocol LegacyPetKeyValueStore: AnyObject {
      func removeObject(forKey aKey: String)
      @discardableResult func synchronize() -> Bool
  }
  extension NSUbiquitousKeyValueStore: LegacyPetKeyValueStore {}

  public struct LegacyPetDataCleanup {
      public static let markerKey = "legacyPetDataCleanupDone_v6"
      public init(documentsDirectory: URL, appGroupContainer: URL?, ubiquityContainer: URL?,
                  defaults: UserDefaults, appGroupDefaults: UserDefaults?,
                  kvStore: LegacyPetKeyValueStore?, fileManager: FileManager = .default)
      @discardableResult public func runIfNeeded() -> Bool   // true = 本次執行了清除
      public func run()
      public static func runInBackgroundIfNeeded(appGroupSuite: String = "group.com.hanfour.peerdrop")
  }
  ```
  iOS 與 Mac app 在啟動時呼叫 `LegacyPetDataCleanup.runInBackgroundIfNeeded()`（Task 4、Task 6）。

- [ ] **Step 1: 寫失敗的測試**

建立 `PeerDropKit/Tests/PeerDropCoreTests/LegacyPetDataCleanupTests.swift`：

```swift
import XCTest
@testable import PeerDropCore

final class LegacyPetDataCleanupTests: XCTestCase {

    private final class FakeKVStore: LegacyPetKeyValueStore {
        var removed: [String] = []
        var synchronizeCount = 0
        func removeObject(forKey aKey: String) { removed.append(aKey) }
        @discardableResult func synchronize() -> Bool { synchronizeCount += 1; return true }
    }

    private var root: URL!
    private var docs: URL!
    private var group: URL!
    private var cloud: URL!
    private var defaults: UserDefaults!
    private var groupDefaults: UserDefaults!
    private var defaultsSuite: String!
    private var groupSuite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyPetDataCleanupTests-\(UUID().uuidString)")
        docs = root.appendingPathComponent("Documents")
        group = root.appendingPathComponent("Group")
        cloud = root.appendingPathComponent("Cloud")
        for dir in [docs!, group!, cloud!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defaultsSuite = "test.legacy-pet.\(UUID().uuidString)"
        groupSuite = "test.legacy-pet.group.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        groupDefaults = UserDefaults(suiteName: groupSuite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        groupDefaults.removePersistentDomain(forName: groupSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func seedLegacyData() throws {
        let petData = docs.appendingPathComponent("PetData")
        try FileManager.default.createDirectory(at: petData.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: petData.appendingPathComponent("pet.json"))
        try Data("{}".utf8).write(to: petData.appendingPathComponent("snapshots/lv1_cat.json"))
        try Data("{}".utf8).write(to: group.appendingPathComponent("pet-snapshot.json"))
        try Data([0x89, 0x50]).write(to: group.appendingPathComponent("pet-rendered.png"))
        let cloudPet = cloud.appendingPathComponent("Documents/PetData")
        try FileManager.default.createDirectory(at: cloudPet, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cloudPet.appendingPathComponent("pet.json"))
        for key in LegacyPetDataCleanup.standardDefaultsKeys { defaults.set("x", forKey: key) }
        groupDefaults.set(Data([0xDE, 0xAD]), forKey: LegacyPetDataCleanup.appGroupDefaultsKey)
        // Unrelated data that must survive.
        try Data("keep".utf8).write(to: docs.appendingPathComponent("ChatData.keep"))
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }

    private func makeCleanup(kv: FakeKVStore) -> LegacyPetDataCleanup {
        LegacyPetDataCleanup(
            documentsDirectory: docs,
            appGroupContainer: group,
            ubiquityContainer: cloud,
            defaults: defaults,
            appGroupDefaults: groupDefaults,
            kvStore: kv
        )
    }

    func testRunRemovesEveryLegacyLocationAndKeepsUnrelatedData() throws {
        try seedLegacyData()
        let kv = FakeKVStore()
        makeCleanup(kv: kv).run()

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("PetData").path))
        XCTAssertFalse(fm.fileExists(atPath: group.appendingPathComponent("pet-snapshot.json").path))
        XCTAssertFalse(fm.fileExists(atPath: group.appendingPathComponent("pet-rendered.png").path))
        XCTAssertFalse(fm.fileExists(atPath: cloud.appendingPathComponent("Documents/PetData").path))
        for key in LegacyPetDataCleanup.standardDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertNil(groupDefaults.object(forKey: LegacyPetDataCleanup.appGroupDefaultsKey))
        XCTAssertEqual(Set(kv.removed), Set(LegacyPetDataCleanup.kvStoreKeys))
        XCTAssertEqual(kv.synchronizeCount, 1)

        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("ChatData.keep").path))
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    func testRunIfNeededIsOneShot() throws {
        try seedLegacyData()
        let kv = FakeKVStore()
        let cleanup = makeCleanup(kv: kv)

        XCTAssertTrue(cleanup.runIfNeeded(), "first call must run")
        XCTAssertTrue(defaults.bool(forKey: LegacyPetDataCleanup.markerKey))

        // Re-seed a file; second call must NOT touch it.
        let petData = docs.appendingPathComponent("PetData")
        try FileManager.default.createDirectory(at: petData, withIntermediateDirectories: true)
        XCTAssertFalse(cleanup.runIfNeeded(), "second call must be a no-op")
        XCTAssertTrue(FileManager.default.fileExists(atPath: petData.path))
        XCTAssertEqual(kv.synchronizeCount, 1)
    }

    func testRunToleratesMissingOptionalContainers() throws {
        try seedLegacyData()
        let cleanup = LegacyPetDataCleanup(
            documentsDirectory: docs,
            appGroupContainer: nil,
            ubiquityContainer: nil,
            defaults: defaults,
            appGroupDefaults: nil,
            kvStore: nil
        )
        XCTAssertTrue(cleanup.runIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("PetData").path))
        // Group container untouched because none was supplied.
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.appendingPathComponent("pet-snapshot.json").path))
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd PeerDropKit && swift test --filter LegacyPetDataCleanupTests`
Expected: 編譯失敗，`cannot find 'LegacyPetDataCleanup' in scope`。

- [ ] **Step 3: 實作**

建立 `PeerDropKit/Sources/PeerDropCore/LegacyPetDataCleanup.swift`：

```swift
import Foundation
import os

/// Abstraction over `NSUbiquitousKeyValueStore` so the cleanup is testable
/// without an iCloud entitlement.
public protocol LegacyPetKeyValueStore: AnyObject {
    func removeObject(forKey aKey: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: LegacyPetKeyValueStore {}

/// One-shot removal of everything the retired pet system (v3–v5.6) left on
/// the device and in the user's iCloud. Runs once per install (marker in
/// `UserDefaults`), best-effort: a failure on one location is logged and the
/// others still run. Product pivot 2026-09 — see
/// docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md §6.
public struct LegacyPetDataCleanup {

    /// Set to `true` in `defaults` after the first successful pass.
    public static let markerKey = "legacyPetDataCleanupDone_v6"

    /// `UserDefaults.standard` keys written by the pet UI / migrations.
    public static let standardDefaultsKeys = [
        "renderedImageVersion",
        "hasSeenPetWelcome_v4",
        "v4UpgradeShown",
        "v4MigratedFromEgg",
        "v5UpgradeShown",
    ]

    /// `NSUbiquitousKeyValueStore` keys written by `PetCloudSync.syncMetadata`.
    public static let kvStoreKeys = ["pet_id", "pet_level", "pet_exp"]

    /// Legacy widget bridge key in the app-group `UserDefaults` suite.
    public static let appGroupDefaultsKey = "petSnapshot"

    /// Widget bridge files in the app-group container.
    public static let appGroupFiles = ["pet-snapshot.json", "pet-rendered.png"]

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "LegacyPetDataCleanup")

    let documentsDirectory: URL
    let appGroupContainer: URL?
    let ubiquityContainer: URL?
    let defaults: UserDefaults
    let appGroupDefaults: UserDefaults?
    let kvStore: LegacyPetKeyValueStore?
    let fileManager: FileManager

    public init(
        documentsDirectory: URL,
        appGroupContainer: URL?,
        ubiquityContainer: URL?,
        defaults: UserDefaults,
        appGroupDefaults: UserDefaults?,
        kvStore: LegacyPetKeyValueStore?,
        fileManager: FileManager = .default
    ) {
        self.documentsDirectory = documentsDirectory
        self.appGroupContainer = appGroupContainer
        self.ubiquityContainer = ubiquityContainer
        self.defaults = defaults
        self.appGroupDefaults = appGroupDefaults
        self.kvStore = kvStore
        self.fileManager = fileManager
    }

    /// Runs `run()` unless the marker is already set. Returns `true` when the
    /// cleanup executed in this call.
    @discardableResult
    public func runIfNeeded() -> Bool {
        guard !defaults.bool(forKey: Self.markerKey) else { return false }
        run()
        defaults.set(true, forKey: Self.markerKey)
        return true
    }

    /// Unconditional cleanup of every known location.
    public func run() {
        removeItem(documentsDirectory.appendingPathComponent("PetData"))

        if let group = appGroupContainer {
            for name in Self.appGroupFiles {
                removeItem(group.appendingPathComponent(name))
            }
        }
        appGroupDefaults?.removeObject(forKey: Self.appGroupDefaultsKey)

        if let cloud = ubiquityContainer {
            removeItem(cloud.appendingPathComponent("Documents/PetData"))
        }

        for key in Self.standardDefaultsKeys {
            defaults.removeObject(forKey: key)
        }

        if let kv = kvStore {
            for key in Self.kvStoreKeys {
                kv.removeObject(forKey: key)
            }
            kv.synchronize()
        }
        Self.logger.info("Legacy pet data cleanup completed")
    }

    private func removeItem(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.error("Failed to remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Production wiring. Resolving the ubiquity container can block, so the
    /// whole pass runs on a detached background task.
    public static func runInBackgroundIfNeeded(appGroupSuite: String = "group.com.hanfour.peerdrop") {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let cleanup = LegacyPetDataCleanup(
                documentsDirectory: docs,
                appGroupContainer: fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupSuite),
                ubiquityContainer: fm.url(forUbiquityContainerIdentifier: nil),
                defaults: defaults,
                appGroupDefaults: UserDefaults(suiteName: appGroupSuite),
                kvStore: NSUbiquitousKeyValueStore.default
            )
            cleanup.runIfNeeded()
        }
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd PeerDropKit && swift test --filter LegacyPetDataCleanupTests`
Expected: 3 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add PeerDropKit/Sources/PeerDropCore/LegacyPetDataCleanup.swift PeerDropKit/Tests/PeerDropCoreTests/LegacyPetDataCleanupTests.swift
git commit -m "feat(core): one-shot LegacyPetDataCleanup for local, app-group and iCloud pet residue"
```

---

### Task 4: iOS app 解耦 — PeerDropApp、ContentView、ChatView、VerificationView、`PeerDrop/Pet/`

**Files:**
- Modify: `PeerDrop/App/PeerDropApp.swift`
- Modify: `PeerDrop/UI/ContentView.swift:4`, `:59`, `:107-114`
- Modify: `PeerDrop/UI/Chat/ChatView.swift:7`, `:14-19`, `:27`, `:41`, `:144-150`, `:166-174`
- Modify: `PeerDrop/UI/Security/VerificationView.swift:37`
- Modify: `PeerDrop/App/Info.plist:57-58`
- Modify: `project.yml:41-42`, `:129`
- Delete: `PeerDrop/Pet/`（整個目錄）

**Interfaces:**
- Consumes: `LegacyPetDataCleanup.runInBackgroundIfNeeded()`（Task 3）。
- Produces: iOS app 不再 import `PeerDropPet`；TabView 為四個分頁（Nearby / Connected / Library，第四個 Pet 分頁移除；紙條與日記分頁由子專案 2、3 新增）。

- [ ] **Step 1: PeerDropApp.swift — 移除狀態與 import**

刪除第 6 行 `import PeerDropPet`。

刪除以下宣告（第 14–17 行與第 52–55 行）：

```swift
    @StateObject private var petEngine = PetEngine()
    /// Cross-device pet sync (local ⇄ iCloud). Merges local + cloud at launch,
    /// pushes on background, and observes live changes from other devices.
    private let petSync = PetSyncCoordinator()
```
```swift
    @State private var showV4UpgradeOnboarding = false
    @State private var showV5UpgradeOnboarding = false
    @State private var didStartPetSyncObserver = false
    @AppStorage("renderedImageVersion") private var renderedImageVersion: String = ""
```

- [ ] **Step 2: PeerDropApp.swift — 移除環境物件與浮動寵物 overlay**

在 `body` 中刪除

```swift
                    .environmentObject(petEngine)
```
與
```swift
                    .overlay(FloatingPetView(engine: petEngine).allowsHitTesting(true).ignoresSafeArea())
```

- [ ] **Step 3: PeerDropApp.swift — 以清除呼叫取代寵物載入區塊**

在 `.onAppear` 內，把從註解 `// Load pet (mock for screenshots, merged local⇄cloud for normal).` 開始、到 `connectionManager.chatManager.onMessageReceivedForPet = { ... }` 結尾 `}` 為止的整段（原 173–232 行，含「Wire pet callbacks」三個回呼）替換為：

```swift
                // Pivot 2026-09: the pet system is gone. Purge whatever the
                // old versions left on disk / in iCloud, once per install.
                LegacyPetDataCleanup.runInBackgroundIfNeeded()
```

- [ ] **Step 4: PeerDropApp.swift — 移除升級 sheet 與 scenePhase 的寵物呼叫**

刪除兩個 `.sheet(isPresented: $showV4UpgradeOnboarding) { ... }` 與 `.sheet(isPresented: $showV5UpgradeOnboarding) { ... }` 修飾器（原 252–271 行）。

在 `.onChange(of: scenePhase)` 的 `case .background:` 分支刪除：

```swift
                // Persist locally + push to iCloud (full state + KVS ping) so
                // other devices see this session's edits. Replaces the old
                // save-then-syncFullState pair; push also bumps KVS metadata,
                // which is what fires the other device's change observer.
                petSync.push(petEngine.pet)
                petEngine.syncSharedState()
                petEngine.startLiveActivity()
                // Pause the 6 FPS animation timer to avoid burning CPU/battery
                // while the app is suspended. Resumed on .active.
                petEngine.animator.stopAnimation()
```

在 `case .active:` 分支刪除：

```swift
                petEngine.endLiveActivity()
                // Resume animation timer (no-op if already running).
                petEngine.animator.startAnimation()
```

- [ ] **Step 5: ContentView.swift — 移除 Pet 分頁**

刪除第 4 行 `import PeerDropPet` 與第 59 行 `    @EnvironmentObject var petEngine: PetEngine`。

刪除 TabView 中的第四個分頁（原 107–114 行）：

```swift

            NavigationStack {
                PetTabView()
                    .environmentObject(petEngine)
            }
            .tabItem {
                Label("Pet", systemImage: "pawprint.fill")
            }
            .tag(3)
```

- [ ] **Step 6: ChatView.swift — 移除聊天寵物 overlay 與訊息框架偵測**

1. 刪除第 7 行 `import PeerDropPet`。
2. 刪除 `MessageFramePreferenceKey` 整個 struct（原 14–19 行）。
3. 刪除第 27 行 `    @EnvironmentObject var petEngine: PetEngine`。
4. 刪除第 41 行 `    @State private var messageFrames: [Int: CGRect] = [:]`。
5. 刪除訊息列上的 `.background(GeometryReader { ... })` 修飾器（原 144–150 行）：

```swift
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: MessageFramePreferenceKey.self,
                                        value: [index: geo.frame(in: .named("chatScroll"))]
                                    )
                                }
                            )
```

6. 刪除 `.onPreferenceChange(MessageFramePreferenceKey.self) { ... }` 與 `.overlay { ChatPetOverlay(...) }` 兩個修飾器（原 166–174 行）。`.coordinateSpace(name: "chatScroll")` 可一併刪除（已無讀者）。
7. `index` 只被上面的框架 key 使用，所以第 117 行 `ForEach(Array(chatManager.messages.enumerated()), id: \.element.id) { index, message in` 改為 `ForEach(chatManager.messages, id: \.id) { message in`。

- [ ] **Step 7: VerificationView.swift — 心形標籤改為「You」**

第 37 行 `Text(String(localized: "Your Pet"))` → `Text(String(localized: "You"))`（`"You"` 已存在於字串目錄，五語齊全）。

- [ ] **Step 8: Info.plist 與 project.yml — 拿掉 Live Activity 與 Pet 相依**

`PeerDrop/App/Info.plist` 刪除

```xml
	<key>NSSupportsLiveActivities</key>
	<true/>
```

`project.yml` `PeerDrop` target：刪除

```yaml
      - package: PeerDropKit
        product: PeerDropPet
```

與 `info.properties` 內的 `        NSSupportsLiveActivities: true`。（`- target: PeerDropWidget` 這一行留到 Task 5 一起拿。）

- [ ] **Step 9: 刪除 `PeerDrop/Pet/` 並重新產生專案**

Run: `git rm -r -q PeerDrop/Pet && xcodegen generate`
Expected: 產生成功，無「file not found」警告。

- [ ] **Step 10: iOS 建置**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && grep -rn "PeerDropPet\|petEngine\|PetEngine" PeerDrop; echo "exit=$?"`
Expected: 建置成功（Widget 仍相依 PeerDropPet，此時模組仍在，可建）；grep 無輸出、`exit=1`。

- [ ] **Step 11: Commit**

```bash
git add -A PeerDrop project.yml PeerDrop.xcodeproj
git commit -m "refactor(ios): remove pet tab, floating pet, chat overlay and upgrade sheets"
```

---

### Task 5: 移除 Widget target 與 iOS 寵物測試

**Files:**
- Delete: `PeerDropWidget/`（`Info.plist`、`PeerDropWidget.entitlements`、`PeerDropWidgetBundle.swift`、`PetLiveActivity.swift`、`PetWidget.swift`）
- Delete: `PeerDropTests/FoodInventoryTests.swift`、`InteractionTrackerTests.swift`、`PetWelcomeFlagTests.swift`、`SharedPetStateTests.swift`、`SpriteSheetLoaderTests.swift`、`V4UpgradeOnboardingTests.swift`、`V5UpgradeOnboardingTests.swift`
- Delete: `PeerDropUITests/Snapshots/PetSnapshotTests.swift`、`PetSnapshotTestsDark.swift`
- Modify: `project.yml:43`, `:238-259`, `:292-322`
- Modify: `fastlane/Fastfile:358-360`, `:465-467`
- Modify: `fastlane/Snapfile:54-59`

**Interfaces:**
- Consumes: 無。
- Produces: 專案剩五個 target（PeerDrop、PeerDropMac、PeerDropTests、PeerDropUITests、PeerDropMacUITests）；release lane 只簽主 app profile。

- [ ] **Step 1: 刪除檔案**

Run:
```bash
git rm -r -q PeerDropWidget \
  PeerDropTests/FoodInventoryTests.swift PeerDropTests/InteractionTrackerTests.swift \
  PeerDropTests/PetWelcomeFlagTests.swift PeerDropTests/SharedPetStateTests.swift \
  PeerDropTests/SpriteSheetLoaderTests.swift PeerDropTests/V4UpgradeOnboardingTests.swift \
  PeerDropTests/V5UpgradeOnboardingTests.swift \
  PeerDropUITests/Snapshots/PetSnapshotTests.swift PeerDropUITests/Snapshots/PetSnapshotTestsDark.swift
```

- [ ] **Step 2: project.yml — 拿掉 Widget 與測試的 Pet 相依**

1. `PeerDrop` target 的 `dependencies` 刪除 `      - target: PeerDropWidget`。
2. `PeerDropTests` target：把

```yaml
      - path: PeerDropTests
        # Pet test files and their fixture zips moved to PeerDropPetTests (M1d-3b Task 6).
        # PeerDropTests/Pet/ directory removed; PeerDropTests/Resources/Pets/ removed.
        excludes:
          - "Pet/Fixtures/**"
```
改為
```yaml
      - path: PeerDropTests
```
並刪除其 `dependencies` 中的
```yaml
      - package: PeerDropKit
        product: PeerDropPet
```
3. 刪除整個 `  PeerDropWidget:` target 區塊（從 `  PeerDropWidget:` 到 `          - group.com.hanfour.peerdrop` 為止，緊接在 `schemes:` 之前）。
4. 主 app 的 `entitlements` 中 `com.apple.security.application-groups`、iCloud container、ubiquity KVS **保留**（`LegacyPetDataCleanup` 需要），在該段上方加一行註解：

```yaml
        # Pivot 2026-09: app-group + iCloud entitlements are kept for ONE
        # release so LegacyPetDataCleanup can purge pet residue. Remove in
        # sub-project 1 (see docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md).
```

- [ ] **Step 3: Fastfile — 移除 widget profile**

兩處（`release` lane 約第 358 行、第二個 lane 約第 465 行）把

```ruby
        provisioningProfiles: {
          "com.hanfour.peerdrop" => "com.hanfour.peerdrop AppStore",
          "com.hanfour.peerdrop.widget" => "com.hanfour.peerdrop.widget AppStore"
        }
```
改為
```ruby
        provisioningProfiles: {
          "com.hanfour.peerdrop" => "com.hanfour.peerdrop AppStore"
        }
```

- [ ] **Step 4: Snapfile — 移除寵物截圖測試**

```ruby
only_testing([
  "PeerDropUITests/SnapshotTests",
  "PeerDropUITests/SnapshotTestsDark",
  "PeerDropUITests/PetSnapshotTests",
  "PeerDropUITests/PetSnapshotTestsDark"
])
```
改為
```ruby
only_testing([
  "PeerDropUITests/SnapshotTests",
  "PeerDropUITests/SnapshotTestsDark"
])
```

- [ ] **Step 5: 重新產生並建置 iOS，跑一個既有單元測試確認測試 target 仍可編譯**

Run:
```bash
xcodegen generate && \
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && \
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/HashVerifierTests -quiet
```
Expected: 建置成功；`HashVerifierTests` PASS（證明 `PeerDropTests` target 在拿掉 Pet 相依後仍能編譯）。`ruby -c fastlane/Fastfile` 回 `Syntax OK`。

- [ ] **Step 6: Commit**

```bash
git add -A PeerDropWidget PeerDropTests PeerDropUITests project.yml PeerDrop.xcodeproj fastlane/Fastfile fastlane/Snapfile
git commit -m "chore(ios): remove PeerDropWidget target and pet unit/UI tests"
```

---

### Task 6: macOS app 解耦

**Files:**
- Modify: `PeerDropMac/App/PeerDropMacApp.swift`
- Modify: `PeerDropMac/App/MacAppDelegate.swift:7`, `:20-25`, `:147-152`
- Modify: `PeerDropMac/Views/MacSidebar.swift:4`, `:9-33`
- Modify: `PeerDropMac/Views/MacDetailRouter.swift:7-8`, `:33-34`, `:38`
- Modify: `PeerDropMac/Views/PeerDropCommands.swift:67-77`
- Modify: `PeerDropMac/Views/MenuBarContent.swift:4`, `:8-21`, `:24`, `:43-45`, `:127-145`
- Modify: `PeerDropMac/Views/MacChatWindow.swift:4`, `:16`, `:29`
- Delete: `PeerDropMac/Views/PetSectionView.swift`
- Modify: `PeerDropMacUITests/MacSnapshotTests.swift:74-84`、`MacSnapshotTestsDark.swift:64-71`
- Modify: `project.yml`（PeerDropMac target 的 `PeerDrop/Pet/UI` 來源與 Pet 相依）、`fastlane/SnapfileMac:25`

**Interfaces:**
- Consumes: `LegacyPetDataCleanup.runInBackgroundIfNeeded()`（Task 3）。
- Produces: `MacSidebarSection` 為 `nearby, trusted, relay` 三段；⌘⌥1–3。Mac 的 `MacDetailRouter` 空狀態文案改用新字串鍵 `"Pick Nearby, Library, or Relay from the sidebar."`（Task 8 加翻譯）。

- [ ] **Step 1: PeerDropMacApp.swift**

1. 刪除第 5 行 `import PeerDropPet`。
2. 刪除 `petEngine`、`petTickDriver`、`petSaveCancellable`、`petSync`、`didStartPetSyncObserver` 五個屬性及各自的文件註解（原 21–44 行）。
3. 四個 scene 中的 `.environmentObject(petEngine)` 各刪一行（主視窗、chat 視窗、Settings、MenuBarExtra）。
4. 主視窗 `.onAppear` 內刪除 `appDelegate.petEngine = petEngine` 與整段 `if petTickDriver == nil { ... }`（含其上方註解）。
5. `.onAppear` 內把從 `// M4 screenshot mode (Task 6): when the` 註解開始、到 `petSaveCancellable` sink 區塊結尾 `}` 為止（原 205–248 行）替換為：

```swift
                    // Pivot 2026-09: purge legacy pet residue once per install.
                    LegacyPetDataCleanup.runInBackgroundIfNeeded()
```
注意其後的 `Task { await PushNotificationManager.shared.requestAuthorizationAndRegister() }` 與 `TipJarManager.shared.startObservingTransactions()` 原本在 `else` 分支內；替換後它們要留在 `.onAppear` 的頂層（不再被 `if ScreenshotModeProvider.shared.isActive` 包住），並保持原本的縮排層級。
6. `.onChange(of: scenePhase)` 的 `case .background:` 刪除

```swift
                        // Persist + push the pet so age/evolution/feeding survive
                        // a relaunch (audit round 21) AND reach the user's other
                        // devices. Skip in screenshot mode so the mock pet never
                        // overwrites a real save.
                        if !ScreenshotModeProvider.shared.isActive {
                            petSync.push(petEngine.pet)
                            petEngine.syncSharedState()
                        }
```
7. 刪除第 2 行 `import Combine`（檔內唯一的 Combine 使用者是 `petSaveCancellable`）。

- [ ] **Step 2: MacAppDelegate.swift**

刪除第 7 行 `import PeerDropPet`、`weak var petEngine: PetEngine?` 及其註解（原 20–25 行），以及 `applicationWillTerminate` 內

```swift
        // Persist + push the pet on quit (audit round 21) — scenePhase
        // .background isn't guaranteed before a Cmd+Q termination on macOS.
        // push() also syncs to iCloud so the last edits reach other devices.
        if let pet = petEngine?.pet {
            PetSyncCoordinator().push(pet)
        }
```

- [ ] **Step 3: MacSidebar.swift**

`case pet` 及其在 `localizedName`、`icon` 的兩個分支刪除；第 4 行註解 `⌘⌥{1-4}` 改為 `⌘⌥{1-3}`。

- [ ] **Step 4: MacDetailRouter.swift**

刪除
```swift
            case .pet:
                PetSectionView()
```
把 `description: Text("Pick Nearby, Trusted, Relay, or Pet from the sidebar.")` 改為 `description: Text("Pick Nearby, Library, or Relay from the sidebar.")`。頂部註解中的 `PetSectionView` 字樣刪掉（改為列出三個 view）。

- [ ] **Step 5: PeerDropCommands.swift**

刪除
```swift
            Button("Pet")     { postJump(.pet)     }
                .keyboardShortcut("4", modifiers: [.command, .option])
```
註解 `(⌘⌥{1-4})` 改 `(⌘⌥{1-3})`。

- [ ] **Step 6: MenuBarContent.swift**

刪除第 4 行 `import PeerDropPet`、`@EnvironmentObject var petEngine: PetEngine`、`body` 中的

```swift
            petSpriteSlot

            Divider()

```
以及整個 `// MARK: - Pet sprite slot` 段落與 `petSpriteSlot` 計算屬性。頂部文件註解中「Pet mini-sprite slot」與「Task 9 wires the Pet sprite…」兩段刪除。

- [ ] **Step 7: MacChatWindow.swift**

刪除第 4 行 `import PeerDropPet        // for PetEngine`、`@EnvironmentObject var petEngine: PetEngine`、`.environmentObject(petEngine)`。

- [ ] **Step 8: 刪除 PetSectionView 與 Mac UI 測試中的寵物案例；更新 project.yml 與 SnapfileMac**

Run: `git rm -q PeerDropMac/Views/PetSectionView.swift`

`MacSnapshotTests.swift`：刪除 `test04_Pet()` 整個方法（含 `/// 04:` 文件註解）；檔頭第 11 行與第 27–28、33 行註解中的 「Pet state」「petEngine.pet」「Pet sprite」字樣刪除。
`MacSnapshotTestsDark.swift`：刪除 `test04_Pet_Dark()` 整個方法。

`project.yml` `PeerDropMac` target：刪除

```yaml
      # Pet/UI reuse — needed by ChatView for the chat-side Pet overlay
      # (ChatPetOverlay). FloatingPetView is iOS-only (UIScreen +
      # UIPanGestureRecognizer); PetTabView relies on iOS-only
      # fullScreenCover sheet semantics for the welcome flow.
      - path: PeerDrop/Pet/UI
        excludes:
          - "FloatingPetView.swift"
          - "PetTabView.swift"
```
以及 `dependencies` 中的
```yaml
      - package: PeerDropKit
        product: PeerDropPet
```

`fastlane/SnapfileMac:25` 的 `mock peers + Pet state` 改為 `mock peers`。

- [ ] **Step 9: 重新產生並建置 Mac**

Run:
```bash
xcodegen generate && \
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' -quiet && \
grep -rn "PeerDropPet\|petEngine\|PetEngine\|\.pet\b" PeerDropMac PeerDropMacUITests; echo "exit=$?"
```
Expected: 建置成功；grep 無輸出、`exit=1`。

- [ ] **Step 10: Commit**

```bash
git add -A PeerDropMac PeerDropMacUITests project.yml PeerDrop.xcodeproj fastlane/SnapfileMac
git commit -m "refactor(mac): remove pet sidebar section, menu-bar sprite, tick driver and iCloud pet sync"
```

---

### Task 7: 刪除 `PeerDropPet` 模組、測試與 ZIPFoundation

**Files:**
- Delete: `PeerDropKit/Sources/PeerDropPet/`、`PeerDropKit/Tests/PeerDropPetTests/`
- Modify: `PeerDropKit/Package.swift:6-12`, `:23`, `:33`, `:85-121`, `:137-147`
- Modify: `PeerDropKit/Sources/PeerDropPlatform/PlatformGraphicsRenderer.swift:10`, `:55`（註解）
- Modify: `project.yml:11-14`（packages 註解）

**Interfaces:**
- Consumes: Task 1–6 已移除所有消費者。
- Produces: PeerDropKit 六個 library product（Platform、Core、Transport、Security、Protocol、PTY）＋兩個 executable；外部相依剩 WebRTC、hummingbird、hummingbird-websocket、jwt-kit。

- [ ] **Step 1: 刪除模組與測試**

Run: `git rm -r -q PeerDropKit/Sources/PeerDropPet PeerDropKit/Tests/PeerDropPetTests`

- [ ] **Step 2: Package.swift**

1. 刪除 `defaultLocalization: "en",` 及其上方六行註解（第 6–12 行）。其他 target 沒有在地化資源，SwiftPM 不再要求此欄位。
2. 刪除 `.library(name: "PeerDropPet", targets: ["PeerDropPet"]),`。
3. 刪除 `.package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),`。
4. 刪除整個 `.target(name: "PeerDropPet", ...)` 區塊（從 `.target(` 到其對應的 `),`，含 `exclude:` 與 `resources:`）。
5. 刪除整個 `.testTarget(name: "PeerDropPetTests", ...)` 區塊。

- [ ] **Step 3: 註解整理**

`PlatformGraphicsRenderer.swift` 第 10 行與第 55 行提到 `PetRendererV3` 的註解，改寫為不指涉寵物的說明（例如「Callers that composite CGImages manually y-flip…」）。功能碼不動。

`project.yml` 第 11–14 行註解

```yaml
  # WebRTC + ZIPFoundation are no longer declared at the project level —
  # both reach the app target transitively via PeerDropKit (WebRTC via
  # PeerDropTransport, ZIPFoundation via PeerDropPet). Pinned versions
  # live in PeerDropKit/Package.swift.
```
改為
```yaml
  # WebRTC is not declared at the project level — it reaches the app
  # target transitively via PeerDropKit (PeerDropTransport). The pinned
  # version lives in PeerDropKit/Package.swift.
```

- [ ] **Step 4: 全面建置與測試**

Run:
```bash
cd PeerDropKit && swift package resolve && swift build && \
swift test --filter "PeerDropCoreTests|PeerDropSecurityTests|PeerDropTransportTests|PeerDropProtocolTests|PeerDropPlatformTests" && cd .. && \
xcodegen generate && \
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && \
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' -quiet && \
grep -rn "PeerDropPet\|ZIPFoundation" --include='*.swift' --include='*.yml' --include='Package.swift' --include='*.resolved' . | grep -v "^./docs/"; echo "exit=$?"
```
Expected: 全部成功；grep 無輸出、`exit=1`。（`Package.resolved` 未進版控，resolve 後會自動不再含 ZIPFoundation。）

- [ ] **Step 5: Commit**

```bash
git add -A PeerDropKit project.yml PeerDrop.xcodeproj
git commit -m "chore(kit): delete PeerDropPet module, tests, 36 MB sprite assets and ZIPFoundation dependency"
```

---

### Task 8: 字串目錄 — 移除 10 個寵物鍵、新增 Mac 側邊欄空狀態句

**Files:**
- Modify: `PeerDrop/App/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 6 已把 `MacDetailRouter` 文案改為 `"Pick Nearby, Library, or Relay from the sidebar."`。
- Produces: 字串目錄無任何寵物鍵；新鍵五語齊全。

`.xcstrings` 是 JSON，但 Xcode 以每個 `stringUnit` 單行的緊湊格式輸出；用 `json.dump` 會重排整份 439 鍵的檔案。以下腳本以文字方式刪除／插入頂層鍵區塊，保持其餘內容逐字不變。

- [ ] **Step 1: 寫腳本並執行**

建立暫存腳本 `/tmp/xcstrings_pet.py`（不進 repo）：

```python
import json, re, sys
PATH = "PeerDrop/App/Localizable.xcstrings"
REMOVE = [
    "Your pet", "Tap a treat to feed your pet", "Your pet isn't hungry yet",
    "pet_widget_description", "pet_widget_name", "pet_widget_no_pet",
    "Pet", "Your Pet", "v4_upgrade_egg_hatched",
    "Pick Nearby, Trusted, Relay, or Pet from the sidebar.",
]
NEW_KEY = "Pick Nearby, Library, or Relay from the sidebar."
NEW_BLOCK = '''    "Pick Nearby, Library, or Relay from the sidebar." : {
      "localizations" : {
        "ja" : { "stringUnit" : { "state" : "translated", "value" : "サイドバーから「近くのデバイス」「ライブラリ」「リレー」を選んでください。" } },
        "ko" : { "stringUnit" : { "state" : "translated", "value" : "사이드바에서 근처, 라이브러리 또는 릴레이를 선택하세요." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "从侧边栏选择附近、资料库或中继。" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "從側邊欄選擇附近、資料庫或 Relay。" } }
      }
    },
'''
lines = open(PATH, encoding="utf-8").read().split("\n")
out, i = [], 0
removed = set()
while i < len(lines):
    line = lines[i]
    m = re.match(r'^    "((?:[^"\\]|\\.)*)" : \{\s*$', line)
    if m and json.loads('"' + m.group(1) + '"') in REMOVE:
        key = json.loads('"' + m.group(1) + '"')
        depth = 0
        while True:
            depth += lines[i].count("{") - lines[i].count("}")
            i += 1
            if depth == 0:
                break
        removed.add(key)
        continue
    out.append(line)
    i += 1
missing = set(REMOVE) - removed
if missing:
    sys.exit(f"keys not found: {missing}")
# Insert the new key right after the opening of "strings".
idx = next(n for n, l in enumerate(out) if l.strip() == '"strings" : {')
out.insert(idx + 1, NEW_BLOCK.rstrip("\n"))
open(PATH, "w", encoding="utf-8").write("\n".join(out))
data = json.load(open(PATH, encoding="utf-8"))
assert NEW_KEY in data["strings"], "insert failed"
assert not any(k in data["strings"] for k in REMOVE), "remove failed"
print("ok", len(data["strings"]), "keys")
```

Run: `python3 /tmp/xcstrings_pet.py`
Expected: `ok 430 keys`（439 − 10 + 1）。

若最後一個被刪的區塊原本以 `}` 結尾（無逗號）而它前一個區塊以 `},` 結尾，JSON 會因尾逗號失效；腳本的 `json.load` 會在此時報錯。修法：把 `"strings"` 物件最後一個區塊結尾的 `},` 改為 `}`。

- [ ] **Step 2: 用既有翻譯核對新句**

Run:
```bash
python3 - <<'EOF'
import json
d=json.load(open("PeerDrop/App/Localizable.xcstrings"))["strings"]
for k in ["Nearby","Library","Relay","Pick Nearby, Library, or Relay from the sidebar."]:
    print(k, {l:v["stringUnit"]["value"] for l,v in d[k]["localizations"].items()})
EOF
```
Expected: 新句中的「附近／資料庫／Relay」「近くのデバイス／ライブラリ／リレー」「근처／라이브러리／릴레이」與 `Nearby`、`Library`、`Relay` 三鍵的既有翻譯一致（zh-Hant 的 `Relay` 目前就是英文 "Relay"，沿用）。不一致則手動改新句。

- [ ] **Step 3: iOS 與 Mac 建置（String Catalog 在建置時編譯）**

Run:
```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && \
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' -quiet && \
grep -n -i '"[^"]*\(pet\|egg\)[^"]*" : {' PeerDrop/App/Localizable.xcstrings; echo "exit=$?"
```
Expected: 兩者建置成功；grep 無輸出、`exit=1`。

- [ ] **Step 4: Commit**

```bash
git add PeerDrop/App/Localizable.xcstrings
git commit -m "i18n: drop pet strings, add Mac sidebar empty-state sentence in 5 languages"
```

---

### Task 9: CI、Scripts、README、docs 清理 ＋ 新增 xcodebuild CI job

**Files:**
- Modify: `.github/workflows/ci.yml:9-46`（lint-imports）＋新增 `xcodebuild-apps` job
- Delete: `.github/workflows/asset-coverage-badge.yml`
- Delete: `Scripts/audit_v5_coverage.py`、`build_atlas.py`、`compute_v5_coverage.sh`、`coverage_report.py`、`drop_v5_zip.sh`、`gen_pixellab_zip.py`、`migrate-zips-to-bundle.sh`、`normalize_pixellab.py`、`normalize-pixellab-zip.sh`、`pixellab_client.py`、`pixellab_cost.py`、`run_monthly_batch.py`、`skeleton_animator.py`、`validate_pixellab_raw.py`、`test_build_atlas.py`、`test_compute_v5_coverage.sh`、`test_gen_pixellab_zip.py`、`test_normalize_pixellab.py`、`test_pixellab_client.py`、`test_run_monthly_batch.py`、`test_skeleton_animator.py`、`test_validate_pixellab_raw.py`（保留 `asc-monitor-daemon.sh`、`run-multi-sim-tests.sh`、`mac-iap-attach/`）
- Delete: `docs/pet-design/`、`fastlane/screenshots_mac/{en-US,ja,ko,zh-Hans,zh-Hant}/04_Pet.png`
- Modify: `README.md:3`, `:5`, Features 列表

**Interfaces:**
- Consumes: 無。
- Produces: CI 四個 job：`lint-imports`、`swift-build-macos`、`crypto-coverage-gate`、**`xcodebuild-apps`**（新增，阻擋型）。

- [ ] **Step 1: lint-imports 改掃描範圍**

`.github/workflows/ci.yml`：
- 第 10 行 `name: Lint — no UIKit in Core/ or Pet/ (non-UI)` → `name: Lint — no unguarded UIKit/AppKit in PeerDropKit/Sources`
- 第 16 行 step name 改為 `Scan for unguarded UIKit/AppKit/WidgetKit imports in PeerDropKit/Sources (excl. Platform/iOS)`
- 第 38–40 行

```bash
          done < <(find PeerDrop/Pet PeerDropKit/Sources -name "*.swift" \
            -not -path "*/Platform/iOS/*" \
            -not -path "*/Pet/UI/*")
```
改為
```bash
          done < <(find PeerDropKit/Sources -name "*.swift" \
            -not -path "*/Platform/iOS/*")
```
- 第 42 行錯誤訊息改為 `::error::Unguarded UI-framework imports in PeerDropKit/Sources/:`；第 46 行改為 `Clean: PeerDropKit/Sources/ has no unguarded UI-framework imports.`

- [ ] **Step 2: 新增 xcodebuild-apps job**

在 `crypto-coverage-gate` job 之前（`swift-build-macos` 之後）插入：

```yaml
  xcodebuild-apps:
    name: Xcode build — iOS app + macOS app (unsigned)
    # Pivot 2026-09 / arch-review 2026-08: the shipped binaries are built
    # by xcodebuild from project.yml, not by `swift build`. Without this job
    # an app-target-only breakage (a deleted view, a stale project.yml path)
    # only surfaces at release time.
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
      - name: Provide placeholder Secrets.xcconfig
        run: cp Secrets.xcconfig.example Secrets.xcconfig
      - name: Generate Xcode project
        run: xcodegen generate
      - name: Build iOS app (simulator, unsigned)
        run: |
          set -o pipefail
          xcodebuild build -scheme PeerDrop \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
            -quiet
      - name: Build macOS app (unsigned)
        run: |
          set -o pipefail
          xcodebuild build -scheme PeerDropMac \
            -destination 'platform=macOS' \
            CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
            -quiet
```

- [ ] **Step 3: 刪除徽章工作流、Scripts、docs、截圖**

Run:
```bash
git rm -q .github/workflows/asset-coverage-badge.yml
git rm -q Scripts/audit_v5_coverage.py Scripts/build_atlas.py Scripts/compute_v5_coverage.sh \
  Scripts/coverage_report.py Scripts/drop_v5_zip.sh Scripts/gen_pixellab_zip.py \
  Scripts/migrate-zips-to-bundle.sh Scripts/normalize_pixellab.py Scripts/normalize-pixellab-zip.sh \
  Scripts/pixellab_client.py Scripts/pixellab_cost.py Scripts/run_monthly_batch.py \
  Scripts/skeleton_animator.py Scripts/validate_pixellab_raw.py \
  Scripts/test_build_atlas.py Scripts/test_compute_v5_coverage.sh Scripts/test_gen_pixellab_zip.py \
  Scripts/test_normalize_pixellab.py Scripts/test_pixellab_client.py Scripts/test_run_monthly_batch.py \
  Scripts/test_skeleton_animator.py Scripts/test_validate_pixellab_raw.py
git rm -r -q docs/pet-design
git rm -q fastlane/screenshots_mac/*/04_Pet.png
ls Scripts
```
Expected: `ls Scripts` 只剩 `asc-monitor-daemon.sh`、`mac-iap-attach`、`run-multi-sim-tests.sh`。

- [ ] **Step 4: README**

刪除第 3 行的徽章：

```markdown
[![v5 asset coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/hanfour/peer-drop/badges/v5-coverage.json)](docs/plans/v5.1+-deferred.md)
```

第 5 行簡介改為：

```markdown
A peer-to-peer file transfer and communication app for iOS and macOS. Direct device-to-device connections on the local network, plus an end-to-end-encrypted relay for reaching friends anywhere. Passing notes and exchange diaries are the next major features (see `docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md`).
```

Features 列表不含寵物條目，不需改；Project Structure 樹狀圖不含 Pet，不需改。

- [ ] **Step 5: 本機驗證 CI 設定可解析、lint 掃描範圍存在**

Run:
```bash
ruby -ryaml -e 'y = YAML.load_file(".github/workflows/ci.yml"); puts y["jobs"].keys.inspect'
find PeerDropKit/Sources -name "*.swift" -not -path "*/Platform/iOS/*" | wc -l
test -f Secrets.xcconfig.example && echo "example present"
```
Expected: 印出 `["lint-imports", "swift-build-macos", "xcodebuild-apps", "crypto-coverage-gate"]`；檔案數 > 0；`example present`。`xcodebuild-apps` job 本身的行為由 Task 11 建 PR 後的 CI 執行驗證。

- [ ] **Step 6: Commit**

```bash
git add -A .github Scripts docs/pet-design fastlane/screenshots_mac README.md
git commit -m "ci: drop asset-coverage badge, prune pet pipeline scripts and design docs, add unsigned xcodebuild job"
```

---

### Task 10: 版本號、CHANGELOG、商店更新說明

**Files:**
- Modify: `project.yml:50`（iOS `MARKETING_VERSION`）、`:217`（Mac `MARKETING_VERSION`）
- Modify: `CHANGELOG.md:5`（在 5.4.0 之上插入）
- Modify: `fastlane/metadata/{en-US,zh-Hant,zh-Hans,ja,ko}/release_notes.txt`

**Interfaces:**
- Consumes: 無。
- Produces: iOS `6.0.0`、Mac `6.1.0`；五語 release notes 說明寵物移除。

- [ ] **Step 1: 版本號**

`project.yml` `PeerDrop` target `MARKETING_VERSION: "5.6.0"` → `"6.0.0"`；`PeerDropMac` target `MARKETING_VERSION: "6.0.0"` → `"6.1.0"`。（Widget 的那一份已在 Task 5 隨 target 刪除。）

- [ ] **Step 2: CHANGELOG**

在 `## [5.4.0] — 2026-05-23` 之前插入：

```markdown
## [6.0.0] — Unreleased

### Removed — Pet companion (Neo-Egg)

- The pet system (hatching, feeding, evolution, sprites, widget, Live Activity, iCloud pet sync) is removed from iOS and macOS. On first launch after upgrading, the app deletes its local pet files, the widget bridge files in the app group, the `PetData` folder in iCloud Drive and the three iCloud key-value entries (`LegacyPetDataCleanup`). Nothing else is touched.
- The `PeerDropWidget` extension target, the `PeerDropPet` Swift package module (66 files, 36 MB of sprite atlases) and the ZIPFoundation dependency are gone. App download size drops by roughly 36 MB.
- Motivation and what comes next: `docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md` (passing notes + exchange diaries).

### Changed

- `ConnectionManager.onPeerConnectedForPet` / `onPeerDisconnectedForPet` renamed to `onPeerConnected` / `onPeerDisconnected` (used by `peerdrop-cli`). `ChatManager.onMessageReceivedForPet` removed.
- `TrustedContact.petSnapshot` removed; records written by earlier versions still decode.
- CI now builds the iOS and macOS app targets with `xcodebuild` on every PR.

```

- [ ] **Step 3: release notes（五語）**

覆寫各檔內容：

`fastlane/metadata/en-US/release_notes.txt`
```
PeerDrop 6.0 — a fresh start.

The pet companion has been retired. This update removes it entirely, along with the home-screen widget and Live Activity, and cleans up the pet data it stored on your device and in iCloud. Your devices, chats, transfer history and trusted contacts are untouched.

Why: we're rebuilding PeerDrop around two new ways to connect — passing notes and exchange diaries — arriving in the next updates.

Everything else works as before: nearby discovery, file transfer, chat and voice calls, on the same protocol as 5.x.
```

`fastlane/metadata/zh-Hant/release_notes.txt`
```
PeerDrop 6.0 — 重新出發。

寵物夥伴功能正式退役。本次更新完整移除寵物、主畫面小工具與即時動態，並清除先前存放在裝置與 iCloud 上的寵物資料。你的裝置、聊天、傳輸紀錄與信任聯絡人完全不受影響。

原因：我們正以「傳紙條」與「交換日記」兩種全新的連結方式重塑 PeerDrop，將在接下來的更新登場。

其他功能一如往常：附近探索、檔案傳輸、聊天與語音通話，協議與 5.x 相同。
```

`fastlane/metadata/zh-Hans/release_notes.txt`
```
PeerDrop 6.0 — 重新出发。

宠物伙伴功能正式退役。本次更新完整移除宠物、主屏幕小组件与实时活动，并清除先前存放在设备与 iCloud 上的宠物数据。你的设备、聊天、传输记录与信任联系人完全不受影响。

原因：我们正以「传纸条」与「交换日记」两种全新的连接方式重塑 PeerDrop，将在接下来的更新登场。

其他功能一如往常：附近发现、文件传输、聊天与语音通话，协议与 5.x 相同。
```

`fastlane/metadata/ja/release_notes.txt`
```
PeerDrop 6.0 — 新しいスタート。

ペット機能は引退しました。今回のアップデートでペット、ホーム画面ウィジェット、ライブアクティビティを完全に削除し、端末と iCloud に保存されていたペットデータを片付けます。デバイス、チャット、転送履歴、信頼済み連絡先には影響ありません。

理由：PeerDrop を「メモを渡す」「交換日記」という2つの新しいつながり方を軸に作り直しています。次のアップデートから順次登場します。

その他はこれまで通り：近くのデバイス検出、ファイル転送、チャット、音声通話。プロトコルは 5.x と同じです。
```

`fastlane/metadata/ko/release_notes.txt`
```
PeerDrop 6.0 — 새로운 시작.

펫 기능이 은퇴했습니다. 이번 업데이트는 펫, 홈 화면 위젯, 라이브 액티비티를 완전히 제거하고 기기와 iCloud에 저장돼 있던 펫 데이터를 정리합니다. 기기, 채팅, 전송 기록, 신뢰하는 연락처는 그대로입니다.

이유: PeerDrop을 「쪽지 전달」과 「교환 일기」라는 두 가지 새로운 연결 방식 중심으로 다시 만들고 있습니다. 다음 업데이트부터 순차적으로 선보입니다.

그 외는 이전과 동일합니다: 근처 기기 탐색, 파일 전송, 채팅, 음성 통화. 프로토콜은 5.x와 같습니다.
```

- [ ] **Step 4: 重新產生專案並確認版本**

Run:
```bash
xcodegen generate && grep -n "MARKETING_VERSION" project.yml && \
plutil -p PeerDrop.xcodeproj/project.pbxproj >/dev/null 2>&1; grep -c 'MARKETING_VERSION = 6.0.0' PeerDrop.xcodeproj/project.pbxproj; grep -c 'MARKETING_VERSION = 6.1.0' PeerDrop.xcodeproj/project.pbxproj
```
Expected: `project.yml` 只有兩處 `MARKETING_VERSION`（`"6.0.0"`、`"6.1.0"`）；pbxproj 中兩者各出現 ≥ 2 次（Debug + Release）。

- [ ] **Step 5: Commit**

```bash
git add project.yml PeerDrop.xcodeproj CHANGELOG.md fastlane/metadata
git commit -m "docs(release): bump to iOS 6.0.0 / Mac 6.1.0 with pet-removal notes in 5 languages"
```

---

### Task 11: 最終驗證與 PR

**Files:** 無新增修改；只驗證與整理。

- [ ] **Step 1: 乾淨重建（清 DerivedData）並跑完整測試**

Run:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/PeerDrop-* && \
cd PeerDropKit && swift build && swift test && cd .. && \
xcodegen generate && \
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && \
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' -quiet && \
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```
Expected: 全部成功。若 `swift test` 中 webterm／PTY 測試因環境（tmux 未安裝）失敗，記錄但不視為本計畫回歸（與 main 相同行為）。

- [ ] **Step 2: 全 repo 殘留掃描**

Run:
```bash
grep -rn -i "peerdroppet\|petengine\|pettabview\|floatingpet\|petsync\|neo-egg\|pixellab" \
  --include='*.swift' --include='*.yml' --include='*.yaml' --include='*.rb' --include='Fastfile' \
  --include='*.plist' --include='*.xcstrings' --include='*.md' --include='*.sh' --include='*.py' . \
  | grep -v "^./docs/plans/\|^./docs/superpowers/\|^./docs/security/\|^./docs/release/\|^./CHANGELOG.md\|^./.build/\|^./PeerDropKit/.build/\|^./DerivedData"
echo "exit=$?"
```
Expected: 無輸出、`exit=1`。（歷史設計文件與 CHANGELOG 允許保留寵物字樣。）

- [ ] **Step 3: 在模擬器實跑一次清除路徑**

Run（先安裝含寵物資料的舊版再升級最貼近真實，但本地最低限度驗證如下）：
```bash
xcrun simctl boot "iPhone 16" 2>/dev/null; \
APP=$(find ~/Library/Developer/Xcode/DerivedData/PeerDrop-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name PeerDrop.app | head -1); \
xcrun simctl install booted "$APP" && \
CONTAINER=$(xcrun simctl get_app_container booted com.hanfour.peerdrop data) && \
mkdir -p "$CONTAINER/Documents/PetData/snapshots" && echo '{}' > "$CONTAINER/Documents/PetData/pet.json" && \
xcrun simctl launch booted com.hanfour.peerdrop && sleep 5 && \
ls "$CONTAINER/Documents" && xcrun simctl spawn booted defaults read com.hanfour.peerdrop legacyPetDataCleanupDone_v6
```
Expected: `Documents` 列表中沒有 `PetData`；defaults 讀出 `1`。

- [ ] **Step 4: 建 PR**

Run:
```bash
git push -u origin feat/remove-pet
gh pr create --base main --title "chore: remove the pet system (sub-project 0 of the notes/diary pivot)" --body "$(cat <<'EOF'
## Summary
- Removes the Neo-Egg pet system end to end: `PeerDropPet` module + tests + 36 MB sprite assets, `PeerDrop/Pet/UI`, Mac `PetSectionView` + menu-bar sprite, the `PeerDropWidget` extension (widget + Live Activity), iCloud pet sync, 21 PixelLab pipeline scripts, the asset-coverage badge workflow, `docs/pet-design`, and 10 localisation keys.
- Adds `LegacyPetDataCleanup` (one-shot, tested) so upgrading users get their local, app-group and iCloud pet residue purged.
- Adds an unsigned `xcodebuild` CI job for the iOS and macOS app targets.
- Bumps iOS to 6.0.0 and Mac to 6.1.0; release notes in 5 languages.

Spec: `docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md` §6 (sub-project 0). Plan: `docs/superpowers/plans/2026-09-14-remove-pet-system.md`.

## Not in this PR (operator, after merge)
- `git push origin --delete badges`
- Re-capture App Store screenshots (pet screens are gone; new screens come with sub-projects 2–3)
- Remove app-group / iCloud entitlements in sub-project 1 (kept one release for the cleanup)

## Test plan
- [x] `swift build` + `swift test` in PeerDropKit
- [x] `xcodebuild build` iOS simulator + macOS
- [x] `xcodebuild test` PeerDropTests
- [x] Simulator upgrade path: seeded `Documents/PetData` is deleted on first launch, marker set

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01WwzkHxSjp7ou9MgGct5irQ
EOF
)"
```
Expected: PR 建立成功；CI 四個 job 中 `lint-imports`、`swift-build-macos`、`xcodebuild-apps` 綠燈（`crypto-coverage-gate` 為軟性）。

---

## 併入後 operator 清單（不在計畫任務內）

1. `git push origin --delete badges`（徽章分支，README 已不再引用）。
2. App Store Connect：iOS 6.0.0 與 Mac 6.1.0 送審前重拍截圖；隱私標籤本次不變（帳號相關變更在子專案 1）。
3. 記憶檔 `project-neo-egg.md`、`project-v5-multi-frame.md` 標記為已棄用（Claude 記憶維護，非 repo）。
4. 若 `fix/arch-review-2026-08` 尚未併入：先併它再 rebase 本分支，衝突僅 `ConnectionManager.swift` 回呼兩行、`ChatManager.swift` 一行、`TrustedContact.swift` 四行。
