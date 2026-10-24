# 專案 F1：朋友「分類」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把主頁的「群組」區換成「分類」：朋友可放進分類，每個分類可改名、管理成員、開關通知；現有 `DeviceGroup` 一次性遷移；移除舊的 P2P 裝置群組聊天入口。

**Architecture:** Kit 新增 `FriendCategory`＋`FriendCategoryStore`（`ChatDataEncryptor` 加密落盤，注入目錄以利測試），`ConnectionManager` 持有它並在本機通知的出口檢查分類的通知開關；UI 以分類區取代群組區，分類詳細頁取代 `GroupDetailView`。F2（狀態強制、狀態消息）不在本計畫：模型先帶好欄位但 UI 不顯示、不強制。

**Tech Stack:** Swift 5.9、SwiftUI（iOS 16+／macOS）、XCTest、`ChatDataEncryptor`、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-10-24-project-f-g-categories-group-rooms-design.md` §2（本計畫只做其中 F1 部分）。

## Global Constraints

- 一律繁體中文（台灣用語）的使用者可見文字；新字串五語系（en、zh-Hant 為 `translated`，zh-Hans、ja、ko 為 `needs_review`），寫入 `PeerDrop/App/Localizable.xcstrings`。**該檔混用兩種縮排格式，不得整檔重新序列化；新條目以文字插入在 `"strings": {` 之後**（見 `git log` 上 PR #190 的做法）。
- 分類不得沿用 `DeviceGroupStore` 的存法（它把明文 JSON 放 `UserDefaults`）；分類檔必須用 `ChatDataEncryptor` 加密。
- 一位朋友最多在一個分類；分類名稱 trim 後 1–20 字、不可只有空白；分類數 ≤ 20。
- 朋友以 `DeviceRecord.id` 記在分類裡；比對時要把同一個 `peerIdentityId`（或同一把已釘選公鑰）的紀錄視為同一人（規格 §0.3）。
- 新增 .swift 檔後必須 `xcodegen generate`，之後**還原** `PeerDrop.xcodeproj/project.pbxproj` 的三個機器產物差異：根群組名稱改回 `peer-drop`（id `9EC0E908E1A38EE0458CEC1B`）、`Secrets.xcconfig` 參照 id 改回 `71060D2244B026D50B454D62`。
- `git add` 只加指定檔，**絕不用 `git commit -a`**；commit 格式 `type: short description`，結尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`。
- iOS 建置：`xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,id=DDBBB4DD-1FE8-466E-A176-7C8E144B01FB' -derivedDataPath <worktree 外的暫存目錄> -quiet`；Mac：`-scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`。Kit 測試：`cd PeerDropKit && swift test --filter <Suite>`（已知失敗 `IdentityKeyManagerTests.testKeyPersistsAcrossInstances` 與本計畫無關）。
- 外接碟可能中途斷線：發現檔案消失先等它回來、`git status`、重新驗證編輯中的檔案。
- 暫存與 DerivedData 放 `/private/tmp/claude-501/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/2be360a0-ac37-4ca5-ad88-48c331fbf475/scratchpad/`；磁碟吃緊時先清自己建立的舊 `dd-*`。
- SourceKit 的 "No such module"／"Cannot find" 是已知假警報，以真實 build／test 為準。

## Review Focus

- 遷移不可丟朋友或把同一位朋友放進兩個分類；遷移要冪等（跑兩次結果相同）。
- 刪除分類後成員回到「朋友」未分類區，不是被刪。
- 通知關閉只影響**本機呈現**（橫幅與聲音），不影響訊息本身的收發與未讀數。
- 兩筆 `DeviceRecord` 屬同一位朋友時，分類與通知設定要一致。
- 舊的群組聊天（`GroupChatView`）入口全部移除後，紙條／對話清單不得留下點了會壞掉的列。

---

### Task 1: `FriendCategory` 與 `FriendCategoryStore`（Kit）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/FriendCategory.swift`、`PeerDropKit/Sources/PeerDropCore/FriendCategoryStore.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/FriendCategoryStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct FriendCategory: Identifiable, Codable, Equatable { id: String; name: String; order: Int; friendIDs: [String]; notificationsEnabled: Bool; presence: CategoryPresence; statusMessage: String?; showStatusMessage: Bool }`，`presence` 預設 `.online`、`statusMessage` 預設 nil、`showStatusMessage` 預設 true（F2 才使用；解碼時缺欄位要容忍，用 `decodeIfPresent`）。
  - `public enum CategoryPresence: Codable, Equatable { case online, offline, scheduled(ScheduleWindow) }`、`public struct ScheduleWindow: Codable, Equatable { weekdays: Set<Int>; startMinute: Int; endMinute: Int }`。
  - `@MainActor public final class FriendCategoryStore: ObservableObject`，`@Published public private(set) var categories: [FriendCategory]`（依 `order` 排序）；`public init(storageKey: String = "categories", directory: URL? = nil, encryptor: ChatDataEncryptor = .shared, legacyGroups: [DeviceGroup] = [], migrationDefaults: UserDefaults = .standard)`。
  - `@discardableResult public func create(name: String) -> FriendCategory?`（名稱不合法或已達 20 個回傳 nil）、`rename(id:to:) -> Bool`、`delete(id:)`（成員回到未分類）、`move(order from:to:)` 或 `reorder(ids: [String])`、`setNotificationsEnabled(_:for:)`。
  - `public func assign(friendID: String, to categoryID: String?)`：先從所有分類移除再加入目標（nil＝未分類）。
  - `public func category(containingAnyOf ids: [String]) -> FriendCategory?`（任何一個 id 命中即回傳）。
  - `public func notificationsEnabled(forAnyOf ids: [String]) -> Bool`：找得到分類回傳其開關，找不到回傳 true。
  - `public static func migrate(legacy groups: [DeviceGroup]) -> [FriendCategory]`：每個群組一個分類（同 id、name、成員）；成員同在多個群組者歸入**名稱排序（`localizedStandardCompare`）最前**的那個群組；名稱 trim 後空白或超過 20 字者截成 20 字／改為「分類」；`order` 依原群組順序。純函式。
- Consumes: `DeviceGroup`（`id`、`name`、`deviceIDs`）、`ChatDataEncryptor.shared.encrypt/decrypt`、仿 `PeerDropKit/Sources/PeerDropAccount/AccountStore.swift` 的「注入 directory」與 atomic 寫檔。

- [ ] **Step 1：寫失敗測試。** 測試名稱與斷言（用暫存目錄＋測試用 encryptor，仿 `AccountStore` 的測試）：`testCreateTrimsAndRejectsBlankAndOverlong`、`testCreateRejectsAfter20`、`testAssignKeepsOneCategoryPerFriend`、`testAssignNilUncategorizes`、`testDeleteReturnsMembersToUncategorized`、`testCategoryContainingAnyOfMatchesEitherRecordOfSamePerson`、`testNotificationsDefaultTrueWhenUncategorized`、`testPersistenceRoundTripIsEncryptedOnDisk`（檔案內容不含分類名稱明文）、`testDecodesFileMissingF2Fields`、`testMigrateDeterministicForFriendInTwoGroups`（歸入名稱排序最前者）、`testMigrateIsIdempotent`（以 `migrationDefaults` 旗標 `peerDropCategoriesMigrated`：第二次 init 不再覆蓋已存在的分類）、`testMigrateKeepsEmptyGroups`、`testMigrateNameEdgeCases`。
- [ ] **Step 2：** 跑測試確認紅（`swift test --filter FriendCategoryStoreTests`）。
- [ ] **Step 3：實作** 上述型別。落盤路徑 `<directory 或 Documents>/Security/<storageKey>.enc`（目錄不存在要建立）；`init` 載入檔案，檔案不存在且旗標未設且 `legacyGroups` 非空 → 遷移並存檔並設旗標；旗標已設不再遷移。解密失敗或損毀 → 空清單並保留壞檔改名 `.corrupt`，不 crash。
- [ ] **Step 4：** Kit 全部測試通過（僅已知失敗）。
- [ ] **Step 5：** commit `feat: friend categories model and encrypted store with legacy group migration`

---

### Task 2: `ConnectionManager` 接縫與本機通知開關（Kit）

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（持有 `categoryStore`、傳入舊群組做遷移、通知呼叫點）、`PeerDropKit/Sources/PeerDropCore/NotificationManager.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/CategoryNotificationMuteTests.swift`

**Interfaces:**
- Produces: `ConnectionManager.categoryStore: FriendCategoryStore`（`let`，用 `groupStore.groups` 當 `legacyGroups` 建立）；`ConnectionManager.isNotificationMuted(forPeer ids: [String]) -> Bool`（`!categoryStore.notificationsEnabled(forAnyOf: ids)`）；`NotificationManager.postChatMessage(from:text:muted:)`、`postIncomingConnection(from:muted:)`、`postTransferComplete(fileName:success:muted:)`，`muted == true` 直接 return（參數預設 `false` 以免破壞其他呼叫端）。
- Consumes: Task 1 的 `FriendCategoryStore`。傳給 `isNotificationMuted` 的 id 要涵蓋該朋友的所有別名：`DeviceRecord.id`、`PeerIdentity.id`、`peerDeviceId`、`chatKey(forRecord:)`、已釘選公鑰對應的其他紀錄（實作者讀 `ConnectionManager` 既有的別名解析，如 `presence(for:sources:)` 用的 id 集合）。
- 呼叫點（現況行號）：`ConnectionManager.swift` 約 2662（來電連線）、3777／3803／3899（聊天、檔案名稱、其他聊天提示）；每一處改傳 `muted:`。

- [ ] **Step 1：寫失敗測試** `testMutedCategoryMutesChatNotification`（用可注入的假通知出口——若 `NotificationManager` 是 `shared` 單例無法注入，先把「要不要發」抽成純函式 `ConnectionManager.shouldPresentNotification(forPeer:)` 再測）、`testUncategorizedFriendNotMuted`、`testSecondRecordOfSamePersonIsMutedToo`、`testMutingDoesNotChangeUnreadCounts`（呼叫靜音後 `chatManager.unreadCounts` 照常增加）。
- [ ] **Step 2：** 紅。**Step 3：** 實作並改各呼叫點。**Step 4：** Kit 測試全過；iOS 與 Mac 建置通過。
- [ ] **Step 5：** commit `feat: wire categories into ConnectionManager and honour per-category notification mute`

---

### Task 3: 主頁「分類」區、分類詳細頁、移到分類、移除舊群組入口（App）

**Files:**
- Modify: `PeerDrop/UI/Home/HomeTab.swift`、`PeerDrop/UI/Home/HomeListLogic.swift`（若存在；`sections(records:presence:query:name:)` 要能排除已分類的朋友並提供每個分類的成員）、`PeerDrop/UI/Conversations/ConversationsTab.swift`、`PeerDrop/UI/Conversations/ConversationsLogic.swift`（拿掉群組對話列）、`PeerDrop/App/Localizable.xcstrings`
- Create: `PeerDrop/UI/Home/CategoryRow.swift`、`PeerDrop/UI/Home/CategoryDetailView.swift`、`PeerDrop/UI/Home/MoveToCategorySheet.swift`
- Delete（確認無其他引用後）：`PeerDrop/UI/Library/GroupDetailView.swift`、`GroupRow.swift`、`AssignGroupSheet.swift`、`GroupEditorView.swift`、`PeerDrop/UI/Chat/GroupChatView.swift`；`ChatManager` 的群組訊息程式碼**保留不動**（G1 完成後再刪）。
- Test: `PeerDropTests/HomeCategoriesLogicTests.swift`、更新 `ConversationsLogicTests.swift`

**Interfaces:**
- Consumes: `connectionManager.categoryStore`（Task 1、2）。
- Produces（UI 行為）：
  - 主頁區段順序：已連線 → **分類** → 朋友（**只列未分類**）→（群組：G2 之前不顯示）→ 聯絡人（iOS）。已連線的朋友不論分類都出現在「已連線」，同時其所屬分類的人數仍計入。
  - 「分類」區標題可收合（沿用 `collapsibleHeader`）；每個分類一列 `CategoryRow`（名稱、人數、通知關閉時顯示 `bell.slash`、chevron）→ `NavigationLink` 到 `CategoryDetailView`；區尾一列「新增分類」（輸入名稱的 alert／sheet，名稱不合法時按鈕停用）。沒有任何分類時仍顯示該區與「新增分類」。
  - `CategoryDetailView`：名稱（可改，同樣驗證）、成員清單（`FriendRow`，點了進聊天，左滑「移出分類」）、「加入朋友」（`MoveToCategorySheet` 的反向：列出所有朋友，已在別的分類者標示現所屬分類，選了就移過來）、通知 `Toggle`、「全部連線」（沿用舊 `GroupDetailView.connectAll()` 的行為：對成員中在線者呼叫既有的連線 API）、刪除分類（確認後成員回未分類）。**不顯示**狀態、時段、狀態消息（F2）。
  - 朋友列的長按選單與左滑加「移到分類…」→ `MoveToCategorySheet`（列出分類與「不分類」，目前所屬打勾）。VoiceOver 要有同名的 `accessibilityAction`。
  - macOS：`HomeTab` 的 `#if os(macOS)` 分支同樣顯示分類區；詳細頁用 NavigationStack push，不用 sheet；鍵盤可操作。
  - 紙條分頁的對話清單不再出現群組對話列，也不得留下指向 `GroupChatView` 的導覽。
- 無障礙識別：分類列 `category-row`、新增分類 `category-add`、詳細頁通知開關 `category-notifications-toggle`。

- [ ] **Step 1：寫失敗測試**（`HomeListLogic` 純邏輯）：`testCategorizedFriendsLeaveFriendsSection`、`testConnectedCategorizedFriendStillShownInConnected`、`testCategoryMemberCountIncludesConnected`、`testSearchFiltersCategoriesByNameAndMembers`；`ConversationsLogicTests` 更新：群組對話不再出現。
- [ ] **Step 2：** 紅。**Step 3：** 實作 UI 與邏輯，新字串五語系：`Categories`／分類、`New category`／新增分類、`Category name`／分類名稱、`Move to category…`／移到分類…、`No category`／不分類、`Remove from category`／移出分類、`Delete category`／刪除分類、`Delete this category?`／要刪除這個分類嗎？、`Friends in this category return to Friends.`／分類裡的朋友會回到「朋友」。、`Notifications`／通知（若已存在就沿用）、`Add friends`／加入朋友、`Connect all`（既有則沿用）。
- [ ] **Step 4：** `xcodegen generate`＋還原 pbxproj 兩處；iOS 單元測試全過（`-only-testing:PeerDropTests`）；iOS 與 Mac 建置通過；用模擬器 `-SCREENSHOT_MODE 1` 截圖確認「分類」區、詳細頁、移到分類 sheet（淺色與最大字級各一張）並描述看到的內容。
- [ ] **Step 5：** commit `feat: categories section on Home, category detail page and move-to-category, retire device-group chat entry`

---

### Task 4: 整合驗證與說明

**Files:** 無新程式碼（發現問題時修在對應 Task 的檔案並另開 fix commit）。

- [ ] 全部 Kit 測試、iOS 單元測試、Mac 建置、`ConversationsLogicTests`。
- [ ] 模擬器實測：新增分類 → 把兩位朋友移進去 → 關閉通知 → 刪除分類成員回到朋友 → 舊裝置群組資料遷移成分類（先在舊版寫入 `peerDropDeviceGroups` 再啟動新版，以 `xcrun simctl spawn <sim> defaults write` 預寫）。
- [ ] 更新 `docs/superpowers/specs/2026-10-24-project-f-g-categories-group-rooms-design.md` 的 F1 實作差異註記（若有）；PR 說明草稿放 scratchpad。
