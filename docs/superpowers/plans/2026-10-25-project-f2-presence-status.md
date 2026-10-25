# 專案 F2：分類的「狀態」強制與「狀態消息」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓每個分類可設定「對這個分類顯示上線／離線／定時離線」並真的強制（不接受直連、不撥號、退出一直連線房間、悄悄關閉現有連線），以及把分類的狀態消息經加密點對點訊框 `statusUpdate` 傳給當下連線中的該分類朋友、在朋友列副標題顯示。

**Architecture:** Kit 新增純函式 `PresencePolicy`（可注入 `Calendar`／時間）與純閘門 `StatusUpdateGate`；`ConnectionManager` 新增兩個 extension 檔（`+Presence`：強制與單一計時器；`+StatusUpdate`：送收），在既有入口（`handleIncomingConnection`、`requestConnection(to:)`、`installRendezvousConnection`、`RendezvousManager` 的有效聯絡人篩選）各加一道檢查。能力協商完全仿照 `supportsNotesExchange`；一直連線因為不交換 HELLO，改在金鑰確認後送一個**加密的** HELLO（E 版本的客戶端會驗公鑰後忽略，向後相容）。UI 在 `CategoryDetailView` 加一個新的頁內區段檔。

**Tech Stack:** Swift 5.9、SwiftUI（iOS 16+／macOS 14）、XCTest、PeerDropKit（SwiftPM）、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-10-24-project-f-g-categories-group-rooms-design.md` §0.3、§2.1、§2.4、§2.5、§2.7（本計畫只做 F2）。規格檔在 `.worktrees/peer-drop-fg-docs`，本 worktree 若沒有就讀那一份。F1 計畫：`docs/superpowers/plans/2026-10-25-project-f1-categories.md`。

**Base：** worktree `.worktrees/peer-drop-f2`，分支 `feat/project-f2-presence`（已含 F1，`f88c618`）。行號以 `f88c618` 為準，動手前重新 grep。

## Global Constraints

- 使用者可見文字一律繁體中文（台灣用語）；新字串五語系（en、zh-Hant 為 `translated`，zh-Hans、ja、ko 為 `needs_review`）寫入 `PeerDrop/App/Localizable.xcstrings`。**該檔不得整檔重新序列化**；新條目以文字插入在 `"strings": {` 之後（同 F1）。
- **`FriendCategory` 的 F2 欄位已在 F1 落地**（`PeerDropKit/Sources/PeerDropCore/FriendCategory.swift:22-66`：`presence`、`statusMessage`、`showStatusMessage`，`decodeIfPresent` 向後相容）。F2 **不改**其儲存格式，只加驗證與 setter。
- 「朋友」＝已釘選身分公鑰底下的所有別名：一律用 `ConnectionManager.notificationAliasIDs(for:)`（`ConnectionManager.swift:5367`）展開後再查分類，同一個人的所有 `DeviceRecord` 一致受規範（規格 §0.3）。
- `PresencePolicy` **只改變「對方看到我什麼」**（§2.4）。不可見時：直連來電在 HELLO 解出身分後**不回應地 `NWConnection.cancel()`**；現有連線用 `PeerConnection.cancel()`＋`updateState(.disconnected)`，**絕不**呼叫 `disconnect()`（它會送 `.disconnect` 訊框）——與專案 E 的 `removeRendezvousConnection`（`ConnectionManager+Rendezvous.swift:421-436`）同一做法。一直連線改走 `RendezvousSession` 的 `.disabled`（只 `leaveRoom`，不送任何訊框，`RendezvousSession.swift:14-15`）。
- **中繼房號連線（`relay-<code>`）不受分類狀態影響**：雙方各自手動輸入房號，視為當次明確同意（規格未涵蓋，見 Review Focus 之外的已知缺口，PR 說明寫明）。
- `MessageType.statusUpdate` **只在雙方都宣告 `supportsStatusUpdate`、通道 `.secured`、且訊息在 `secureEnvelope` 內**時才送／收；**不得**加入 `PeerConnection.unwrappedControlTypes`（`PeerConnection.swift:226-230`，既有測試 `test_unwrappedControlTypes_isExactlyTheHonestUnwrappedSet` 會守住）。對方沒宣告就**完全不送**。
- 狀態消息：trim 前後空白、內部換行改成一個空白後 `String.count` ≤ **60**；空字串＝nil；`showStatusMessage == false` 送 `text: nil`；未分類朋友的有效狀態消息＝nil。收端 payload > **1024 bytes** 或清理後 > 60 字一律丟棄。
- 排程：`ScheduleWindow.weekdays` 用 `Calendar` 的 weekday（1＝星期日…7＝星期六），空集合＝每天；`startMinute`／`endMinute` 0…1439、本機時區；視窗為半開區間 `[start, end)`；`start > end` 表示跨午夜，**星期以視窗開始那天為準**；`start == end` 不合法（store 拒絕）。不合法的視窗在 `PresencePolicy` 一律視為「視窗內」（fail closed：離線）。
- 計時器：單一 `Timer`（主 RunLoop、`.common` mode、以絕對 `fireDate` 排程）排到「下一個可能切換點」；iOS 進背景時取消、回前景時立即重算；**Mac 不因背景取消**（Mac 的一直連線在背景仍運作，`rendezvousClosesOnBackground == false`）。強制點（來電、撥號、一直連線篩選）一律**即時**計算，不依賴計時器的快取。
- 新增 .swift 檔後必須 `xcodegen generate`，之後**還原** `PeerDrop.xcodeproj/project.pbxproj` 的機器產物差異：根群組名稱改回 `peer-drop`（id `9EC0E908E1A38EE0458CEC1B`）、`Secrets.xcconfig` 參照 id 改回 `71060D2244B026D50B454D62`；diff 只應新增檔案參照。Kit 內新檔不需 xcodegen。
- `git add` 只加指定檔，**絕不用 `git commit -a`**；不得碰 `.gitignore` 與 `docs/pet-design/`；不 push。commit 格式 `type: short description`，結尾空一行加 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`。
- 建置／測試（`$S`＝`/private/tmp/claude-501/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/2be360a0-ac37-4ca5-ad88-48c331fbf475/scratchpad`）：
  - Kit：`cd PeerDropKit && swift test --filter <Suite>`（已知既有失敗 `IdentityKeyManagerTests.testKeyPersistsAcrossInstances`，與本計畫無關）。
  - iOS：`xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -derivedDataPath "$S/dd-f2-ios" -only-testing:PeerDropTests/<Class>`（磁碟吃緊時只跑相關測試類別，並先刪自己建立的舊 `$S/dd-*`）。
  - Mac：`xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' -derivedDataPath "$S/dd-f2-mac" CODE_SIGNING_ALLOWED=NO`。
- 同一程序內兩個真實 `ConnectionManager` 無法達到 `.secured`（共用 `IdentityKeyManager.shared`）：整合測試用「一個真實 CM＋腳本化對端」——直連範本 `PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerNotesExchangeTests.swift`（`ScriptedPeer`、`connectPeer(advertise:…)`，第 160、374 行；它們是 `private`，新測試檔各自複製一份精簡版，不要改成共用以免動到既有檔）；一直連線範本 `ConnectionManagerRendezvousTests.swift`（`ScriptedRVPeer`、`installVerified`）與 `RendezvousManagerTests.swift`（`FakeSignalingFactory`、`addFriend`）。CM↔CM 與跨版本在**獨立程序**驗證（Task 6）。
- 外接碟可能中途斷線：檔案消失先等它回來、`git status`、重新驗證編輯中的檔案。SourceKit 的 "No such module"／"Cannot find" 是假警報，以真實 build／test 為準。

## Review Focus

1. **舊版對端**（HELLO 沒有 `supportsStatusUpdate`，包括 E 版本的一直連線對端）：任何時機都不得送出 `statusUpdate`，連線不得因 F2 而斷；明文或對方未宣告時送來的 `statusUpdate` 一律丟棄。→ Task 2 `testNoStatusUpdateToPeerWithoutFlag`、`testPlaintextStatusUpdateDropped`；Task 4 `testCategoryEditNeverSendsToLegacyPeer`；Task 6 跨版本實測。
2. **已在線上時轉為不可見**（把連線中的朋友移進「離線」分類、或定時視窗剛好開始）：必須悄悄關閉直連與一直連線，**不送 `.disconnect`**，之後也不自動重連。→ Task 3 `testBecomingHiddenClosesLiveConnectionWithoutFrame`、`testScheduleStartClosesRendezvousWithoutFrame`。
3. **跨午夜＋星期＋時區／夏令時間**：例如「星期五 22:00–07:00」在星期六 06:59 是離線、星期六 22:00 是上線；時區改變後下一次重算立即套用。→ Task 1 表格測試、Task 3 `testTimeZoneChangeReevaluates`。
4. **同一位朋友有多筆紀錄／別名**（區網紀錄＋中繼紀錄＋只靠釘選公鑰關聯的聯絡人）：隱藏與狀態消息都要一致套用到每一筆。→ Task 3 `testHiddenViaSecondRecordOfSamePerson`、Task 4 `testReceivedStatusAppliesToEveryRecordOfThePerson`。
5. **狀態消息邊界**：60 個 emoji（grapheme）可、61 個不可；只有空白＝清除；換行被壓成空白；收端 2 KB payload 丟棄。→ Task 1 `testStatusMessageValidation`、Task 2 `testOversizeOrOverlongStatusUpdateDropped`。

---

### Task 1：`PresencePolicy` 與分類狀態的 setter（Kit，純邏輯）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/PresencePolicy.swift`
- Modify: `PeerDropKit/Sources/PeerDropCore/FriendCategory.swift`（`ScheduleWindow` 加 `isValid`）、`PeerDropKit/Sources/PeerDropCore/FriendCategoryStore.swift`（setter 放在 `setNotificationsEnabled` 之後，約第 89-93 行）
- Test: Create `PeerDropKit/Tests/PeerDropCoreTests/PresencePolicyTests.swift`；Modify `PeerDropKit/Tests/PeerDropCoreTests/FriendCategoryStoreTests.swift`

**Interfaces:**
- Consumes: `FriendCategory`、`CategoryPresence`、`ScheduleWindow`（F1）。
- Produces:
  - `ScheduleWindow.isValid: Bool`：`weekdays ⊆ 1...7`、`startMinute`／`endMinute` ∈ 0...1439、`startMinute != endMinute`。
  - `public enum PresencePolicy`（全部 `nonisolated static`）：
    - `isInWindow(_ w: ScheduleWindow, at date: Date, calendar: Calendar) -> Bool`
    - `isVisible(aliases: [String], categories: [FriendCategory], at date: Date, calendar: Calendar) -> Bool`：找 `friendIDs` 與 `aliases` 有交集的第一個分類；未分類或 `.online` → true；`.offline` → false；`.scheduled(w)` → `!isInWindow(w, …)`；`aliases` 空 → true。
    - `nextTransition(categories: [FriendCategory], after date: Date, calendar: Calendar) -> Date?`：所有 `.scheduled` 分類的每個 `startMinute`／`endMinute` 用 `calendar.nextDate(after:matching: DateComponents(hour:minute:), matchingPolicy: .nextTime)` 取最早者；沒有排程回 nil。（不看星期：多醒一次無害，重算是冪等的。）
    - `statusText(aliases: [String], categories: [FriendCategory]) -> String?`：所屬分類 `showStatusMessage && statusMessage` 非空才回傳，否則 nil。
    - `cleanStatusMessage(_ raw: String) -> String?`：換行（`\n`、`\r`、U+2028）改空白、trim；空字串回 nil；**不截斷**。
    - `public static let maxStatusMessageLength = 60`
  - `FriendCategoryStore`：`@discardableResult public func setPresence(_ p: CategoryPresence, for categoryID: String) -> Bool`（`.scheduled` 且 `!isValid` → false 不變更）、`@discardableResult public func setStatusMessage(_ raw: String, for categoryID: String) -> Bool`（清理後 > 60 → false 不變更；空 → nil）、`public func setShowStatusMessage(_ show: Bool, for categoryID: String)`。三者成功時 `save()`。

- [ ] **Step 1：寫失敗測試** `PresencePolicyTests`，`calendar` 固定為 `Calendar(identifier: .gregorian)`＋`TimeZone(identifier: "Asia/Taipei")`，日期用 `DateComponents` 組出（2026-10-23 是星期五＝weekday 6）。表格測試 `testWindowTable`，每列 `(weekdays, start, end, 日期時間, 預期 inWindow)`，至少包含：
  - 同日 `[]`, 540, 1020：09:00 → true、16:59 → true、17:00 → false、08:59 → false。
  - 跨午夜 `[6]`（星期五）, 1320, 420：星期五 22:00 → true、星期六 06:59 → true、星期六 07:00 → false、星期六 22:00 → false、星期四 23:00 → false、星期五 06:00 → false（那是星期四開始的視窗）。
  - 跨午夜 `[]`, 1380, 60：每天 23:30 → true、00:30 → true、01:00 → false。
  - 星期 `[1,7]`（週末）, 0, 1439：星期六 12:00 → true、星期一 12:00 → false。
  - 不合法（`start == end`、`weekdays: [0]`、`startMinute: 1440`）→ true（fail closed）。
  - 時區：同一個 `Date`，`Asia/Taipei` 在視窗內、`America/Los_Angeles` 不在。
  - 夏令時間：`America/New_York` 2026-03-08 視窗 `[]`, 150, 200（02:30–03:20，02:xx 不存在）在 03:00 → true。
  另寫 `testIsVisibleRules`（未分類、`.online`、`.offline`、`.scheduled` 內外、空 aliases、別名只命中第二筆紀錄 id 也算）、`testNextTransitionPicksEarliestStartOrEndAndNilWithoutSchedules`（`[start 1320, end 420]` 在 21:00 → 當天 22:00；在 23:00 → 隔天 07:00；只有 `.offline` 分類 → nil）、`testStatusMessageValidation`（`cleanStatusMessage("  a\nb  ") == "a b"`；`"   "` → nil；60 個 "👨‍👩‍👧" 清理後 `count == 60`）、`testStatusTextHonoursShowFlagAndUncategorized`。
  `FriendCategoryStoreTests` 加：`testSetPresenceRejectsInvalidScheduleAndPersists`（重開 store 讀回 `.scheduled(w)` 相等）、`testSetStatusMessageTrimsRejectsOverlongAndClears`（61 個 emoji → false 且原值不變；`"  "` → nil）、`testSetShowStatusMessagePersists`。
- [ ] **Step 2：** `cd PeerDropKit && swift test --filter "PresencePolicyTests|FriendCategoryStoreTests"` → 紅（`PresencePolicy` 未定義）。
- [ ] **Step 3：實作** 上述介面。`isInWindow`：`let m = hour*60+minute`（`calendar.dateComponents([.hour,.minute,.weekday], from:)`）；`start < end` → `inDays(weekday) && start <= m && m < end`；`start > end` → `(inDays(weekday) && m >= start) || (inDays(前一天 weekday) && m < end)`，前一天 weekday＝`(weekday + 5) % 7 + 1`；`inDays(d) = weekdays.isEmpty || weekdays.contains(d)`。
- [ ] **Step 4：** 同指令 → 綠；`swift test --filter FriendCategory` 全綠。
- [ ] **Step 5：commit**
```bash
git add PeerDropKit/Sources/PeerDropCore/PresencePolicy.swift PeerDropKit/Sources/PeerDropCore/FriendCategory.swift PeerDropKit/Sources/PeerDropCore/FriendCategoryStore.swift PeerDropKit/Tests/PeerDropCoreTests/PresencePolicyTests.swift PeerDropKit/Tests/PeerDropCoreTests/FriendCategoryStoreTests.swift
git commit -m "feat: presence policy for category schedules and status message setters

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2：能力協商 `supportsStatusUpdate` 與 `statusUpdate` 訊框（Kit，協定層＋閘門）

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropProtocol/MessageType.swift`（在 `notesExchange` 之後加 `case statusUpdate`，註解寫明閘控與「不得進 `unwrappedControlTypes`」）、`PeerDropKit/Sources/PeerDropProtocol/PeerMessage.swift`（仿第 18 行 `notesExchange(_:senderID:)`）
- Create: `PeerDropKit/Sources/PeerDropProtocol/StatusUpdatePayload.swift`、`PeerDropKit/Sources/PeerDropCore/StatusUpdateGate.swift`、`PeerDropKit/Sources/PeerDropCore/ConnectionManager+StatusUpdate.swift`
- Modify: `PeerDropKit/Sources/PeerDropSecurity/PeerIdentity.swift`（第 41-110、152-165 行）、`PeerDropKit/Sources/PeerDropCore/PeerConnection.swift`（第 172-175 行旁）、`PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（`DialAttempt` 第 358-377 行；送 HELLO 三處：2494-2496、2957-2959、3455；`installInitiatorPeerConnection` 第 4213 行；`handleMessageForPeer` 在 `case .notesExchange:`（4021）之後；中繼 HELLO 換身分處 4005-4018）、`PeerDropKit/Sources/PeerDropCore/ConnectionManager+Rendezvous.swift`（`rendezvousDispatchedTypes` 第 75-78 行、`confirmRendezvousConnection` 第 340-351 行、`dispatchRendezvous` 的 `.hello` 分支第 366-379 行）
- Test: Create `PeerDropKit/Tests/PeerDropSecurityTests/PeerIdentityStatusUpdateTests.swift`、`PeerDropKit/Tests/PeerDropCoreTests/StatusUpdateGateTests.swift`、`PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerStatusUpdateTests.swift`；Modify `PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerRendezvousTests.swift`

**Interfaces:**
- Produces:
  - `public struct StatusUpdatePayload: Codable, Equatable { public var text: String?; public var updatedAt: Date }`；`public static func statusUpdate(_ p: StatusUpdatePayload, senderID: String) throws -> PeerMessage`。
  - `PeerIdentity.supportsStatusUpdate: Bool`（兩個 init 參數 `supportsStatusUpdate: Bool = false` 放在最後；`CodingKeys` 加；`decodeIfPresent ?? false`）；`public func withoutStatusUpdate() -> PeerIdentity`；`withoutNotesExchange()` **必須保留** `supportsStatusUpdate`（否則中繼與一直連線 HELLO 會意外清掉）。`local()` 設 `supportsStatusUpdate: true`（含 headless CLI：它只是收端，無分類就送 nil，且跨版本實測要靠它）。
  - `PeerConnection`：`var advertisedStatusUpdate: Bool?`（我方在這條連線的 HELLO 有沒有宣告；nil＝未知＝否）、`var rendezvousPeerSupportsStatusUpdate = false`、`var peerSupportsStatusUpdate: Bool { isRendezvous ? rendezvousPeerSupportsStatusUpdate : peerIdentity.supportsStatusUpdate }`。
  - `DialAttempt.advertisedStatusUpdate: Bool?`。
  - `public struct StatusUpdateFacts: Equatable, Sendable { isInstalled, isSecured: Bool; handshakeKey, helloKey: Data?; pinning: NotesExchangeFacts.Pinning; peerSupports, localAdvertised: Bool }`；`public enum StatusUpdateGate { public static func allows(_ f: StatusUpdateFacts) -> Bool }`：全部成立才 true——installed、secured、`pinning == .trusted`、兩把公鑰都在時必須相等（任一缺 → false）、peerSupports、localAdvertised。
  - `ConnectionManager`：`func statusUpdateFacts(for pc: PeerConnection) -> StatusUpdateFacts`（installed＝`connections[pc.id] === pc && pc.state.isConnected`，或 `rendezvousConnections[pc.id] === pc && pc.rendezvousVerified`；其餘欄位仿 `notesExchangeFacts(for:)`，`ConnectionManager+NotesExchange.swift:188-197`）；`func acceptedStatusUpdate(_ m: PeerMessage, on pc: PeerConnection, origin: PeerConnection.MessageOrigin) -> StatusUpdatePayload?`（`origin == .envelope`、閘門通過、`payload.count <= 1024`、可解碼、`cleanStatusMessage` 後 ≤ 60；回傳 text 已清理的 payload）；`func handleStatusUpdateMessage(_:on:origin:)`——本 task 只呼叫 `acceptedStatusUpdate` 並把結果交給 `applyReceivedStatus(_:from:)`，後者在本 task 是空實作（Task 4 填）。
  - 一直連線：`confirmRendezvousConnection` 成功後送一個加密 HELLO：`PeerMessage.hello(identity: localIdentity.withoutNotesExchange())`，並設 `pc.advertisedStatusUpdate = true`；`dispatchRendezvous` 的 `.hello` 分支在公鑰檢查通過後，**僅當** `origin == .envelope && pc.rendezvousVerified` 時設 `pc.rendezvousPeerSupportsStatusUpdate = claimed.supportsStatusUpdate`，**不得**改動 `pc.peerIdentity`；之後呼叫 Task 4 會用到的掛鉤 `statusUpdateCapabilityLearned(pc)`（本 task 空實作）。`rendezvousDispatchedTypes` 加入 `.statusUpdate`。
  - 安裝一直連線時（`installRendezvousConnection` 第 233 行旁）設 `pc.advertisedStatusUpdate = false`，直到送出加密 HELLO 才改 true。
- Consumes: Task 1 的 `PresencePolicy.cleanStatusMessage`、`maxStatusMessageLength`。

- [ ] **Step 1：寫失敗測試。**
  - `PeerIdentityStatusUpdateTests`（仿 `PeerIdentityNotesExchangeTests.swift`）：`testAbsentKeyDecodesFalse`（舊版 JSON 無此鍵）、`testRoundTrip`、`testWithoutStatusUpdateClearsOnlyThatFlag`、`testWithoutNotesExchangeKeepsStatusUpdate`、`testLocalAdvertisesStatusUpdate`。
  - `StatusUpdateGateTests`：`testAllConditionsAllow`，再逐一翻轉每個條件（含 `pinning: .notEvaluated`／`.mismatch`、`handshakeKey != helloKey`、`handshakeKey == nil`）各自 `XCTAssertFalse`。
  - `ConnectionManagerStatusUpdateTests`（直連腳本對端；複製的 `connectPeer` 多一個參數 `advertiseStatus: Bool = true` 控制對端 HELLO 的 `supportsStatusUpdate`，Task 4 會用到）：`testHelloAdvertisesStatusUpdateAndRecordsPerConnection`（伺服端 HELLO `supportsStatusUpdate == true`，且 `cm.connections[id]?.advertisedStatusUpdate == true`；中繼 HELLO 也帶旗標——以 `PeerMessage.hello(identity: cm.localIdentity.withoutNotesExchange())` 解碼斷言）、`testPlaintextStatusUpdateDropped`（在 secured 前後各注入明文 `statusUpdate`，`acceptedStatusUpdate` 回 nil、連線仍 `isConnected`）、`testEnvelopeStatusUpdateFromFlaggedPeerAccepted`、`testStatusUpdateFromUnflaggedPeerDropped`、`testOversizeOrOverlongStatusUpdateDropped`（2 KB payload、61 字）、`testUnknownMessageTypeStillFailsDecoding`（`PeerMessage.decoded` 對 `"type":"someFutureType"` 丟錯——記錄為何必須閘控）。
  - `ConnectionManagerRendezvousTests` 加：`testConfirmedRendezvousSendsEncryptedHelloWithFlag`（`ScriptedRVPeer` 收到的第一個確認後 envelope 內層為 `.hello` 且 `supportsStatusUpdate == true`）、`testRendezvousCapabilityOnlyFromEncryptedHello`（明文 HELLO 不改旗標；加密 HELLO 改 `rendezvousPeerSupportsStatusUpdate` 但 `peerIdentity` 不變）、`testLegacyRendezvousPeerWithoutHelloNeverGetsCapability`（對端從不送 HELLO → 旗標維持 false）。
- [ ] **Step 2：** `swift test --filter "PeerIdentityStatusUpdateTests|StatusUpdateGateTests|ConnectionManagerStatusUpdateTests|ConnectionManagerRendezvousTests"` → 紅。
- [ ] **Step 3：實作。** 三處送 HELLO：撥號與接受用 `notesExchangeHelloIdentity(for:)` 的結果（它已含 `supportsStatusUpdate`），記錄到 `attempt.advertisedStatusUpdate`／`peerConnection.advertisedStatusUpdate`；`installInitiatorPeerConnection` 照抄 `advertisedNotesExchange` 的那一行；中繼 `startRelayHandshake` 送出前設 `peerConnection.advertisedStatusUpdate = true`。`handleMessageForPeer` 加 `case .statusUpdate: handleStatusUpdateMessage(message, on: peerConnection, origin: origin)`。
- [ ] **Step 4：** 同指令 → 綠；再跑 `swift test --filter "PeerConnectionPlaintextAfterSecureTests|ConnectionManagerNotesExchangeTests|PeerIdentityNotesExchangeTests|PeerDropProtocolTests"` 全綠（確認 `unwrappedControlTypes` 未變、既有旗標不受影響）。
- [ ] **Step 5：commit**
```bash
git add PeerDropKit/Sources/PeerDropProtocol/MessageType.swift PeerDropKit/Sources/PeerDropProtocol/PeerMessage.swift PeerDropKit/Sources/PeerDropProtocol/StatusUpdatePayload.swift PeerDropKit/Sources/PeerDropSecurity/PeerIdentity.swift PeerDropKit/Sources/PeerDropCore/PeerConnection.swift PeerDropKit/Sources/PeerDropCore/StatusUpdateGate.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager+StatusUpdate.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager+Rendezvous.swift PeerDropKit/Tests/PeerDropSecurityTests/PeerIdentityStatusUpdateTests.swift PeerDropKit/Tests/PeerDropCoreTests/StatusUpdateGateTests.swift PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerStatusUpdateTests.swift PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerRendezvousTests.swift
git commit -m "feat: negotiate status-update capability in HELLO and gate the encrypted statusUpdate frame

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3：狀態強制——直連、撥號、一直連線、現有連線、單一計時器（Kit）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/ConnectionManager+Presence.swift`
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（stored properties 放在 `categoryStore` 宣告旁，第 431 行；`init` 內第 849-854 行的 Combine 訂閱旁加分類訂閱；`handleScenePhaseChange` 第 2071 行的 `.active`／`.background`；`requestConnection(to:)` 第 2358 行開頭；`handleIncomingConnection` 第 2585-2590 行之間；`handleInitiatorControlMessage` 的 `.connectionAccept` 與 `.hello` 安裝前，第 4075、4114 行）、`ConnectionManager+Rendezvous.swift`（`startRendezvousIfForeground` 第 111 行、`ensureRendezvousManager` 第 151 行、`currentRendezvousContact` 第 199-207 行）、`PeerDropKit/Sources/PeerDropCore/Rendezvous/RendezvousManager.swift`（`init` 第 233 行、`currentActiveContacts` 第 345 行、`activeContacts` 第 386 行）、`PeerDropKit/Sources/PeerDropCore/Rendezvous/RendezvousWebRTCNegotiator.swift`（`live(...)` 第 187 行）
- Test: Create `PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerPresenceTests.swift`；Modify `PeerDropKit/Tests/PeerDropCoreTests/RendezvousManagerTests.swift`

**Interfaces:**
- Consumes: Task 1 `PresencePolicy.isVisible`／`nextTransition`；既有 `notificationAliasIDs(for:)`、`trustedContactStore.find(byPublicKey:)`、`handlePeerDisconnected`（經 `updateState(.disconnected)` → `onDisconnected` 觸發）。
- Produces（`ConnectionManager`）：
  - stored：`var presenceClock: () -> Date = { Date() }`、`var presenceCalendar: Calendar = .autoupdatingCurrent`、`var presenceTimer: Timer?`（internal，測試可讀 `presenceTimer?.fireDate`）。
  - `func friendAliasIDs(forIdentity identity: PeerIdentity, extraIDs: [String] = []) -> [String]`：`[identity.id] + extraIDs`＋釘選同一把公鑰的 contact 的 `deviceId`，再 `notificationAliasIDs`。把 `shouldPresentNotification(forIdentity:extraIDs:)`（第 5354-5361 行）改為呼叫它（行為不變）。
  - `public func isFriendVisible(aliases ids: [String]) -> Bool`（先 `notificationAliasIDs` 展開，再 `PresencePolicy.isVisible(…, at: presenceClock(), calendar: presenceCalendar)`）；`func isFriendVisible(identity: PeerIdentity) -> Bool`；`func isFriendVisible(contact: TrustedContact) -> Bool`（`[contact.deviceId]`＋所有釘選同一公鑰的 contact 的 deviceId）；`func isFriendVisible(connection pc: PeerConnection) -> Bool`（`friendAliasIDs(forIdentity: pc.peerIdentity, extraIDs: [pc.id, ChatStorageKey.key(forConnection: pc)])`）。
  - `func reevaluatePresence()`：(1) 對 `connections` 中**非** `isRelayTransport`、`state.isActive` 且 `!isFriendVisible(connection:)` 者 `closeQuietly(pc)`；(2) 對 `rendezvousConnections` 中不可見者 `closeRendezvousConnection(pc)`；(3) `rendezvousManager?.contactsDidChange()`；(4) `schedulePresenceTimer()`。
  - `func closeQuietly(_ pc: PeerConnection)`：`pc.cancel()` 後 `pc.updateState(.disconnected)`（其 `onDisconnected` 走既有 `handlePeerDisconnected` 清檔案傳輸／通話／`removeConnection`）；iOS 另 `nearbyInteractionManager?.stopSession(for:)`。不送任何訊框、不設 `statusToast`。
  - `func schedulePresenceTimer()`：先 invalidate；`PresencePolicy.nextTransition(categories: categoryStore.categories, after: presenceClock(), calendar: presenceCalendar)` 為 nil 就不排；否則 `Timer(fire: date + 1, interval: 0, repeats: false)`（加 1 秒避開邊界前觸發）加到 `RunLoop.main` 的 `.common`，觸發時 `reevaluatePresence()`。
  - `func cancelPresenceTimer()`。
  - `RendezvousManager.init(…, visible: @escaping (TrustedContact) -> Bool = { _ in true })`（參數放最後，既有呼叫端不用改）；`activeContacts(_:excluding:visible:)` 在既有 eligibility 篩選**之後**再過濾 `visible`（必須在 `isRendezvousEligible(_, among: all)` 用完整 `all` 判斷之後，否則「deviceId 唯一」的判斷會被改變）。`live(…, visible:)` 轉傳。`ensureRendezvousManager` 傳 `visible: { [weak self] c in self?.isFriendVisible(contact: c) ?? true }`。
- 呼叫點：
  - 來電：在保留 id 檢查（2585-2589）之後、`checkPeerTrust`（2590）之前：`guard isFriendVisible(identity: peerIdentity) else { connection.cancel(); return }`——不通知、不 TOFU、不設 `activeConnection`、不 toast。
  - 撥號：`requestConnection(to:)` 最前面：`guard isFriendVisible(aliases: [peer.id]) else { statusToast = String(localized: "This friend's category shows you as offline"); return }`（`connectToGroup`、`reconnect`、`reconnect(to:)` 都經過這裡）。
  - 撥號端收到對方身分（舊版 Bonjour id 不是 identity id 時才會走到）：`handleInitiatorControlMessage` 在 `.connectionAccept` 帶身分與 `.hello` 兩處 `installInitiatorPeerConnection` 之前，`!isFriendVisible(identity:)` → `if dialAttempt === attempt { dialAttempt = nil }; attempt.connection.cancel()`，不 toast、不 `recordConnectionFailure`。
  - 一直連線安裝：`currentRendezvousContact` 多一個 `isFriendVisible(contact: c)` 條件（防止計時器切換與協商同時發生的競態）。
  - 重算時機：`categoryStore.$categories.dropFirst().receive(on: DispatchQueue.main).sink { reevaluatePresence() }`；`handleScenePhaseChange(.active)` 呼叫 `reevaluatePresence()`；`.background` 在 `rendezvousClosesOnBackground` 為 true 時 `cancelPresenceTimer()`；`startRendezvousIfForeground()`（Mac 喚醒走這裡，`MacAppDelegate.swift:90`）呼叫 `reevaluatePresence()`；`NotificationCenter` 訂閱 `.NSSystemTimeZoneDidChange` 與 `.NSSystemClockDidChange` → `reevaluatePresence()`。

- [ ] **Step 1：寫失敗測試。**
  - `RendezvousManagerTests`：`testInvisibleContactGetsNoRoomAndVisibleAgainRejoins`（`visible` 由測試的 `Bool` 控制；不可見 → `factory.made.isEmpty`；翻成可見＋`contactsDidChange()` → 建房）、`testBecomingInvisibleLeavesRoomAndSendsNothingExtra`（仿 `testDowngradeLeavesRoomAndSendsNothingExtra`：`t.sentSignals == [.ready]`、`t.closed`、`linkState == .inactive`）、`testVisibilityFilterDoesNotChangeDeviceIdUniqueness`（兩個同 deviceId 的聯絡人，其中一個不可見，另一個仍**不**合格）。
  - `ConnectionManagerPresenceTests`（`ConnectionManager(categoryStore:)`＋暫存目錄 store，仿 `CategoryNotificationMuteTests` setUp；`cm.presenceClock`、`cm.presenceCalendar` 固定）：
    - `testHiddenFriendIncomingIsCancelledWithoutAnyFrame`：腳本對端送 HELLO（其 id 在 `.offline` 分類）＋`connectionRequest`；斷言 socket 讀到 EOF／錯誤而**沒有任何訊框**、`pendingIncomingRequest == nil`、`state` 未變成 `.incomingRequest`。
    - `testVisibleFriendIncomingStillShowsConsent`（對照組）。
    - `testHiddenViaSecondRecordOfSamePerson`：分類只含區網紀錄 id，HELLO 的 id 是另一筆紀錄但釘選同一把公鑰 → 也被 cancel。
    - `testScheduledWindowHidesOnlyInsideWindow`：`presenceClock` 設在視窗內／外各一次。
    - `testDialToHiddenFriendRefusedWithToast`：`requestConnection(to: DiscoveredPeer(id:…))` 後 `dialAttempt == nil`、`statusToast` 為新字串。
    - `testBecomingHiddenClosesLiveConnectionWithoutFrame`：先建立連線（腳本對端），再 `categoryStore.setPresence(.offline, …)`；斷言對端收到的訊框中**沒有** `.disconnect`、`cm.connections[id] == nil`。
    - `testRelayConnectionUnaffected`：`isRelayTransport` 的連線在對方變不可見後仍在。
    - `testScheduleStartClosesRendezvousWithoutFrame`：`installVerified` 一條一直連線，把 clock 推進視窗並呼叫 `reevaluatePresence()`；`rendezvousConnections` 空、對端沒收到任何新訊框。
    - `testInstallRefusedForHiddenContact`：`installRendezvousConnection` 回 nil。
    - `testTimerScheduledAtNextTransitionAndClearedWithoutSchedules`：`presenceTimer?.fireDate` ＝ `nextTransition + 1`；改成 `.online` 後 `presenceTimer == nil`。
    - `testTimeZoneChangeReevaluates`：post `.NSSystemTimeZoneDidChange` 後（換 `presenceCalendar.timeZone`）既有連線依新時區被關閉。
    - `testIOSBackgroundCancelsTimerMacKeepsIt`：`rendezvousClosesOnBackground` 分別設 true／false，`handleScenePhaseChange(.background)` 後斷言 timer。
- [ ] **Step 2：** `swift test --filter "ConnectionManagerPresenceTests|RendezvousManagerTests"` → 紅。
- [ ] **Step 3：實作** 上述介面與呼叫點。
- [ ] **Step 4：** 同指令 → 綠；再跑 `swift test --filter "ConnectionManagerRendezvousTests|CategoryNotificationMuteTests|ConnectionManagerNotesExchangeTests"` 全綠（確認 `friendAliasIDs` 重構未改通知行為）。
- [ ] **Step 5：commit**
```bash
git add PeerDropKit/Sources/PeerDropCore/ConnectionManager+Presence.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager+Rendezvous.swift PeerDropKit/Sources/PeerDropCore/Rendezvous/RendezvousManager.swift PeerDropKit/Sources/PeerDropCore/Rendezvous/RendezvousWebRTCNegotiator.swift PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerPresenceTests.swift PeerDropKit/Tests/PeerDropCoreTests/RendezvousManagerTests.swift
git commit -m "feat: enforce per-category presence on direct, dial and always-connected paths with a single transition timer

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4：狀態消息的送出與接收、`DeviceRecord` 欄位（Kit）

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropCore/DeviceRecord.swift`（欄位、`init`、`merge(with:)` 第 57-71 行）、`PeerDropKit/Sources/PeerDropCore/DeviceRecordStore.swift`（`addOrUpdate` 同名合併重建記錄處第 43-55 行要帶上新欄位；新增 setter）、`PeerDropKit/Sources/PeerDropCore/ConnectionManager+StatusUpdate.swift`、`PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（`handleSecureChannelEstablished` 第 4941 行結尾；中繼 `.hello` 換身分後第 4017 行；`removeConnection` 第 1012 行；`addConnection` 覆蓋舊連線處第 953-958 行；分類訂閱同 Task 3 那一條 sink）、`ConnectionManager+Rendezvous.swift`（`removeRendezvousConnection` 第 421 行）
- Test: Create `PeerDropKit/Tests/PeerDropCoreTests/DeviceRecordStatusTests.swift`；Modify `PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerStatusUpdateTests.swift`、`ConnectionManagerRendezvousTests.swift`

**Interfaces:**
- Consumes: Task 1 `PresencePolicy.statusText`；Task 2 `StatusUpdateGate`、`statusUpdateFacts(for:)`、`acceptedStatusUpdate`、`applyReceivedStatus(_:from:)` 與 `statusUpdateCapabilityLearned(_:)` 的空殼；Task 3 `friendAliasIDs(forIdentity:extraIDs:)`。
- Produces:
  - `DeviceRecord.statusMessage: String?`、`statusUpdatedAt: Date?`（`init` 參數預設 nil，放最後；合成 Codable 對 Optional 用 `decodeIfPresent`，舊資料可讀；`merge` 採 `statusUpdatedAt` 較新的一方）。
  - `DeviceRecordStore.setStatus(_ text: String?, updatedAt: Date, forRecordIDs ids: Set<String>)`：更新 `id ∈ ids` 的每一筆，無命中則不動、不新增；有變更才 `save()`。
  - `ConnectionManager`：
    - stored：`var sentStatusTexts: [ObjectIdentifier: String?] = [:]`（放在 Task 3 的 stored 旁）。
    - `func effectiveStatusText(for pc: PeerConnection) -> String?`＝`PresencePolicy.statusText(aliases: friendAliasIDs(forIdentity: pc.peerIdentity, extraIDs: [pc.id, ChatStorageKey.key(forConnection: pc)]), categories: categoryStore.categories)`。
    - `func sendStatusUpdateIfNeeded(to pc: PeerConnection, force: Bool = false)`：`StatusUpdateGate.allows(statusUpdateFacts(for: pc))` 且 `isFriendVisible(connection:)`，`force` 或 `sentStatusTexts[key] != text`（字典沒這個鍵也算不同）才送；先寫入 `sentStatusTexts` 再 `Task { try? await pc.sendMessage(.statusUpdate(StatusUpdatePayload(text:, updatedAt: presenceClock()), senderID: localIdentity.id)) }`。
    - `func broadcastStatusUpdates()`：對 `connections.values` 與 `rendezvousConnections.values` 各呼叫 `sendStatusUpdateIfNeeded(to:)`（不 force，靠差異判斷）。
    - `applyReceivedStatus(_ p: StatusUpdatePayload, from pc: PeerConnection)`：`deviceStore.setStatus(p.text, updatedAt: p.updatedAt, forRecordIDs: Set(friendAliasIDs(forIdentity: pc.peerIdentity, extraIDs: [pc.id])))`。**最後收到者為準**，不比較 `updatedAt`（同一條連線有序、無重放；跨連線以收到順序為準，避免對方時鐘回撥造成更新被擋）。
- 送出時機：`handleSecureChannelEstablished` 設好 pinning 判決之後 `sendStatusUpdateIfNeeded(to:, force: true)`（`PeerConnection.sendMessage` 會等到可加密才送）；中繼 HELLO 換身分後再呼叫一次（不 force）；一直連線在 `statusUpdateCapabilityLearned(pc)` 內 `force: true`；分類變更 sink 內 `broadcastStatusUpdates()`（在 `reevaluatePresence()` 之後，已關閉的連線自然不送）。`removeConnection`、`addConnection` 覆蓋、`removeRendezvousConnection` 移除該 pc 的 `sentStatusTexts`。

- [ ] **Step 1：寫失敗測試。**
  - `DeviceRecordStatusTests`：`testOldRecordJSONWithoutStatusDecodes`（用 F1 前格式的 JSON 字串）、`testStatusRoundTrip`、`testMergeKeepsNewerStatus`、`testSetStatusUpdatesOnlyMatchingRecordsAndNeverInserts`（直接用 `cm.deviceStore`；測完 `replaceAll(with:)` 還原）。
  - `ConnectionManagerStatusUpdateTests` 加：`testConnectSendsCurrentStatusInsideEnvelope`（對端在 `.offline` 以外的分類、`statusMessage = "在山上"` → 對端解出 `.statusUpdate` 且 `text == "在山上"`，外層是 `.secureEnvelope`）、`testUncategorizedFriendGetsNilOnConnect`、`testShowStatusOffSendsNil`、`testEditingMessageResendsOnlyOnChange`（同值 `setStatusMessage` 兩次只送一次）、`testMovingFriendOutOfCategorySendsNil`、`testCategoryEditNeverSendsToLegacyPeer`（`connectPeer(advertiseStatus: false)`：連線、改訊息、切開關，對端從未收到 `.statusUpdate`、連線仍在）、`testReceivedStatusStoredOnRecord`、`testReceivedStatusAppliesToEveryRecordOfThePerson`、`testReceivedNilClearsStatus`。
  - `ConnectionManagerRendezvousTests` 加：`testRendezvousSendsStatusOnlyAfterPeerEncryptedHello`、`testLegacyRendezvousPeerNeverReceivesStatusUpdate`。
- [ ] **Step 2：** `swift test --filter "DeviceRecordStatusTests|ConnectionManagerStatusUpdateTests|ConnectionManagerRendezvousTests"` → 紅。
- [ ] **Step 3：實作** 上述介面與呼叫點。
- [ ] **Step 4：** 同指令 → 綠；`swift test`（整個 Kit）只剩已知失敗。
- [ ] **Step 5：commit**
```bash
git add PeerDropKit/Sources/PeerDropCore/DeviceRecord.swift PeerDropKit/Sources/PeerDropCore/DeviceRecordStore.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager+StatusUpdate.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift PeerDropKit/Sources/PeerDropCore/ConnectionManager+Rendezvous.swift PeerDropKit/Tests/PeerDropCoreTests/DeviceRecordStatusTests.swift PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerStatusUpdateTests.swift PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerRendezvousTests.swift
git commit -m "feat: send category status messages to connected friends and store received ones on device records

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5：分類詳細頁的狀態與狀態消息、分類列圖示、朋友列副標題、在地化（App，iOS＋Mac 共用）

**Files:**
- Create: `PeerDrop/UI/Home/CategoryStatusSection.swift`（狀態選擇＋時段＋狀態消息，讓 `CategoryDetailView` 不再變長）
- Modify: `PeerDrop/UI/Home/CategoryDetailView.swift`（第 65-102 行的第一個 Section 之後插入新區段；第 104-117 行「全部連線」在分類目前隱藏時停用並加 footer；第 8 行註解改掉「F2 deliberately not shown」）、`PeerDrop/UI/Home/CategoryRow.swift`（參數與圖示、`CategoryRowAccessibility`）、`PeerDrop/UI/Home/HomeTab.swift`（第 579-600 行兩處 `CategoryRow(...)` 傳新參數）、`PeerDrop/UI/Home/ChatTarget.swift`（`FriendSubtitle.text` 第 166 行）、`PeerDrop/UI/Home/FriendRow.swift`（第 24-28 行傳 `record.statusMessage`）、`PeerDrop/App/Localizable.xcstrings`
- Test: Modify `PeerDropTests/HomeTabLogicTests.swift`、`PeerDropTests/HomeCategoriesLogicTests.swift`

**Interfaces:**
- Consumes: Task 1 的 store setter、`PresencePolicy`；Task 4 的 `DeviceRecord.statusMessage`；`connectionManager.presenceClock`／`presenceCalendar`（判斷「目前是否隱藏中」）。
- Produces（UI 行為）：
  - `FriendSubtitle.text(presence:lastConnected:connectionCount:source:isConnecting:statusMessage: String? = nil, now:)`：連線中（`isConnecting && presence != .online`）仍顯示「Connecting...」；否則 `statusMessage` 非空就顯示它；再否則維持原邏輯。`FriendRow` 傳 `record.statusMessage`（所有朋友列、分類成員列、已連線列自動生效）。
  - `CategoryRow` 新增 `presence: CategoryPresence = .online`、`hiddenNow: Bool = false`：`.offline` 顯示 `eye.slash`；`.scheduled` 在視窗內顯示 `moon.zzz`、視窗外顯示 `clock`；`.online` 不顯示。`CategoryRowAccessibility.label(name:count:notificationsEnabled:presence:hiddenNow:)` 依序追加 "Shown as offline"／"Offline now (scheduled)"／"Offline on a schedule"。
  - `CategoryStatusSection(store:category:hiddenNow:)`：
    - 區段標題 "Status for this category"；`Picker` 用 `.pickerStyle(.inline)`（頁內勾選列，不開選單或彈窗），選項 "Show as online"／"Show as offline"／"Offline on a schedule"；切到定時時預設 `ScheduleWindow(weekdays: [], startMinute: 1320, endMinute: 420)`。
    - 定時時顯示：星期列（7 個膠囊切換鈕，標籤 `Calendar.current.veryShortStandaloneWeekdaySymbols`，順序從 `Calendar.current.firstWeekday` 起；每顆 `accessibilityLabel` 用 `standaloneWeekdaySymbols`、`.isSelected` trait）＋說明 "No days selected means every day."；兩個 `DatePicker(displayedComponents: .hourAndMinute)`："Offline from"、"Until"；兩者相同時不寫入 store 並顯示 "Start and end can't be the same time."（`paper(.warning)`）。純函式 `ScheduleEditorLogic.orderedWeekdays(firstWeekday: Int) -> [Int]`、`minutes(from: Date, calendar:) -> Int`、`date(fromMinutes:on:calendar:) -> Date` 放在同檔供測試。
    - footer（誠實說明，永遠顯示）："Friends in this category see you as offline and can't connect to you, and you won't be connected to them either. On the same Wi-Fi they may still see this device under Nearby."
    - 狀態消息：頁內 `TextField`（仿 `InlineCategoryNameField` 的提交／失焦處理，`MoveToCategorySheet.swift:98-137`），右側 `n/60` 計數；Return 或失焦時 `store.setStatusMessage`，超過 60 時保留文字並以警告色顯示 "Up to 60 characters."；`Toggle` "Show status message"；footer "Sent directly to friends in this category while you're connected, never through a server."
    - 無障礙識別：`category-presence-picker`、`category-schedule-day`、`category-schedule-start`、`category-schedule-end`、`category-status-field`、`category-status-toggle`。
  - `CategoryDetailView`：`hiddenNow`＝`category.presence` 經 `PresencePolicy` 判斷（`.offline` 或定時視窗內）；隱藏中「Connect All」停用，footer 顯示 "This friend's category shows you as offline"（與 Task 3 的 toast 同一個 key）。
  - macOS：同一份 View（`PeerDrop/UI` 已編進 PeerDropMac，`project.yml:174`）；`DatePicker` 在 macOS 用預設 stepper field；不需另做 Mac 視窗。
- 新字串（en → zh-Hant）：`Status for this category`→對這個分類顯示的狀態、`Show as online`→上線、`Show as offline`→離線、`Offline on a schedule`→定時離線、`Offline from`→離線開始、`Until`→離線結束、`No days selected means every day.`→沒有選擇星期代表每天。、`Start and end can't be the same time.`→開始與結束不能是同一個時間。、`Friends in this category see you as offline…Nearby.`→這個分類的朋友會看到你離線，也無法連線到你；你也不會和他們連線。在同一個 Wi-Fi 下，他們仍可能在「附近」看到這台裝置。、`Status message`→狀態消息、`Show status message`→顯示狀態消息、`Up to 60 characters.`→最多 60 字。、`Sent directly to friends…server.`→只會在連線時直接傳給這個分類的朋友，不經過伺服器。、`This friend's category shows you as offline`→這位朋友的分類目前顯示你離線、`Shown as offline`→顯示為離線、`Offline now (scheduled)`→定時離線中。zh-Hans／ja／ko 填譯文並標 `needs_review`。

- [ ] **Step 1：寫失敗測試。** `HomeTabLogicTests`：`testSubtitlePrefersStatusMessage`（`.offline` 有歷史＋`statusMessage: "在山上"` → "在山上"）、`testSubtitleConnectingBeatsStatusMessage`、`testSubtitleIgnoresEmptyStatusMessage`。`HomeCategoriesLogicTests`：`testCategoryRowAccessibilityMentionsPresence`（三種狀態各一）、`testOrderedWeekdaysStartsAtFirstWeekday`（`firstWeekday: 2` → `[2,3,4,5,6,7,1]`）、`testMinutesRoundTrip`（`date(fromMinutes: 1320…)` → `minutes == 1320`，`Asia/Taipei`）。
- [ ] **Step 2：** `xcodebuild test … -only-testing:PeerDropTests/HomeTabLogicTests -only-testing:PeerDropTests/HomeCategoriesLogicTests` → 紅（編譯失敗即算）。
- [ ] **Step 3：實作** UI 與字串；`xcodegen generate`；還原 pbxproj 兩處機器差異（見 Global Constraints），`git diff PeerDrop.xcodeproj/project.pbxproj` 只剩 `CategoryStatusSection.swift` 的新增。
- [ ] **Step 4：** 同測試指令 → 綠；Mac 建置通過；以 `python3 -I -c "import json;json.load(open('PeerDrop/App/Localizable.xcstrings'))"` 確認 JSON 仍合法、`git diff --stat` 該檔只有新增行。模擬器 `-SCREENSHOT_MODE 1` 截圖：分類詳細頁（上線／定時離線展開）、主頁分類列圖示、朋友列顯示狀態消息，淺色與最大字級各一張，描述看到的內容。
- [ ] **Step 5：commit**
```bash
git add PeerDrop/UI/Home/CategoryStatusSection.swift PeerDrop/UI/Home/CategoryDetailView.swift PeerDrop/UI/Home/CategoryRow.swift PeerDrop/UI/Home/HomeTab.swift PeerDrop/UI/Home/ChatTarget.swift PeerDrop/UI/Home/FriendRow.swift PeerDrop/App/Localizable.xcstrings PeerDrop.xcodeproj/project.pbxproj PeerDropTests/HomeTabLogicTests.swift PeerDropTests/HomeCategoriesLogicTests.swift
git commit -m "feat: category status picker with schedule, status message field, presence icons and status subtitles

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6：整合驗證、跨版本互連、PR 說明

**Files:** 無新產品程式碼（發現問題修在對應 Task 的檔案並另開 `fix:` commit，不 squash）。

- [ ] **Step 1：全部測試。** Kit `cd PeerDropKit && swift test`（只剩已知失敗）；iOS `xcodebuild test … -only-testing:PeerDropTests`；Mac 建置。
- [ ] **Step 2：跨版本迴路測試（獨立程序）。** 以 `.worktrees/interop-old/PeerDropKit/Sources/interop-harness`（scratch，`--role accept|dial|raw`，stdin 指令、stdout JSON 事件）為底，在兩個 scratch worktree（舊＝`origin/main`，含專案 E 但無 F；新＝本分支）各放一份並 `swift build`（`.build` 放外接碟）。驗證：①新撥舊、舊撥新：連線**不斷**、新版從不送 `statusUpdate`（在新版 harness 印出送出的訊息型別）；②新↔新：harness 在接受端建一個含對方 id 的分類並設狀態消息 → 撥號端記錄收到 `statusUpdate` 並存入 `DeviceRecord`；把分類設 `.offline` 後再撥 → 撥號端看到 socket 關閉且**沒收到任何訊框**；③已連線中把分類設 `.offline` → 對端只看到斷線、無 `.disconnect`。若 harness 缺少操作，在 scratch 裡補最小驅動並說明；一直連線的跨程序 WebRTC 若本機跑不起來，明確標記改由實機驗證。
- [ ] **Step 3：模擬器實測。** 新增分類→設定定時離線（把時段設成包含現在）→主頁該分類列顯示 `moon.zzz`→改成上線圖示消失；狀態消息輸入 61 字被擋、清空後清除。
- [ ] **Step 4：Mac 檢查。** 確認 `PeerDropMac` 沒有分類設定視窗需要同步（`PeerDropMac/Views/MacSettingsView.swift` 只有 General／Profile／Relay／Support 分頁；分類詳細頁走共用的 `HomeTab`→`CategoryDetailView`，`MacDetailRouter.swift:44`）——規格 §2.7「Mac 同步設定視窗」記為**不適用**；Mac 執行起來開一個分類詳細頁確認狀態區段可用鍵盤操作。
- [ ] **Step 5：** 在規格的 F2 段落旁補實作差異註記（若規格檔在本 worktree 才改；否則寫進 PR 說明）。PR 說明草稿（繁體中文）放 `$S/pr-notes-project-f2.md`：設計決定（中繼不受影響、加密 HELLO 傳一直連線能力、已連線轉隱藏會悄悄斷線、最後收到者為準）、已知缺口（Bonjour 側信道、隱藏也會讓自己看不到對方、`DeviceRecordStore` 是明文 `UserDefaults`）、需實機驗證項目（真實 Wi-Fi 來電被擋、一直連線跨網路的狀態消息、背景回前景重算、Mac 睡眠喚醒）。不 push。
