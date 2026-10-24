# UI 改版 A＋B（MSN 配色、在線三態、四分頁）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PeerDrop 換成 MSN 色盤、加上「在線／附近／下線」三態頭像與 live／note 兩種底色，並把導覽重組為 主頁／紙條／附近／日記 四個分頁（iPhone 與 Mac）。

**Architecture:** 沿用 `PaperToken`／`PaperPalette`／`PaperTheme`，新增 `PaperMode`（`.live` 白底、`.note` 紙感底）與品牌／紙條 token，views 透過 `\.paperMode` 環境值取色。三態由 `PeerDropCore` 的純函式 `PeerPresenceResolver` 判斷，頭像徽章只負責呈現。新分頁 `HomeTab`、`ConversationsTab` 取代 `ConnectedTab`／`LibraryTab`；紙條清單的「最後一則」由 `ChatManager` 新增的唯讀查詢提供，不改儲存格式。

**Tech Stack:** SwiftUI（iOS 16／macOS 14）、XcodeGen、XCTest、PeerDropKit（SwiftPM）。

**Spec:** `docs/superpowers/specs/2026-10-23-ui-overhaul-msn-design.md`（已核可；§13 為建置者補充決定，§14 為專案 E 預留）

**Base（重要）：** 實作分支 `feat/ui-overhaul` 必須從 **`feat/swipe-to-reply`**（它疊在 `fix/blank-display-name` 之上，含 `paperIconButton()`、`ChatDisplayName`、`SwipeToReply`、`MacChatWindow` 名稱修正）切出，worktree 放 `<repo>/.worktrees/peer-drop-ui`。若那兩條分支已先合併進 `main`，改從 `main` 切。不得從尚未含它們的 `main` 切，否則 `PaperTheme.swift`、`ChatView.swift`、`MacChatWindow.swift` 會衝突。

## Global Constraints

- 一律繁體中文台灣用語；commit 格式 `type: short description`，結尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`；**不得 `git commit -a`**，只 `git add` 指定檔；不得提交 `.gitignore` 的未提交修改與 `docs/pet-design/`。
- 不改通訊協定、加密、儲存格式；iOS 16／macOS 14；`PeerDrop/UI` 同時被 iOS 與 Mac target 編譯（`ContentView`、`ConnectionView`、`ConnectedTab`、`SettingsView`、`DiscoveryView` 等 8 檔只有 iOS），iOS 專屬 API 用 `#if os(iOS)`。
- 新增 `.swift` 後執行 `xcodegen generate`（並一起提交 `PeerDrop.xcodeproj/project.pbxproj`）。
- 色票（起始值，可為過對比測試而微調，意圖不變）：brand `#0078D7`（白字）、highlight `#00A2E8`（不放字）、online `#80C41C`（不放字）、note 填 `#FFF1CC`／邊 `#F9A825`／字 `#4A3200`、頭像 `#0078D7`／`#107C41`／`#F9A825`（深色字）／`#C50F1F`。live：bg `#F4F9FD`、line `#DDEAF4`、sub `#5E7387`、text `#1E2B36`、卡片 `#FFFFFF`。note 沿用現有 `PaperPalette` 數值。
- 對比：文字 ≥ 4.5:1，圖示／圖形／placeholder ≥ 3:1；`live`／`note` × 淺／夜間 四種組合各有測試。狀態不得只靠顏色（實心點／空心圈／信封方塊＋VoiceOver 文字）。
- 頭像：≥ 44 pt 圓角 16 pt，其餘 `size × 0.36`；圓角方形，不是圓。
- 五語系（en、zh-Hant、zh-Hans、ja、ko）；`Localizable.xcstrings` **只用文字插入、不可 JSON 整檔重寫**；`SWIFT_EMIT_LOC_STRINGS=NO`，新 key 手動加；zh-Hans／ja／ko 標 `needs_review`；避免僅標點不同的重複 key。
- 建置／測試（外接碟會斷線，一律用 scratchpad 的 derivedDataPath `$S`＝`/private/tmp/claude-501/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/2be360a0-ac37-4ca5-ad88-48c331fbf475/scratchpad`）：
  - Kit：`cd PeerDropKit && swift test --filter <TestClass>`
  - iOS：`xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -derivedDataPath "$S/dd-sim" -only-testing:PeerDropTests/<TestClass>`
  - Mac：`xcodebuild build -scheme PeerDropMac -derivedDataPath "$S/dd-mac-new" CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -allowProvisioningUpdates`
  - 假的「type has no member」錯誤＝過期快取，刪 `$S/dd-sim`。

## Rulings（計畫層級的決定，執行時視為已定；錯了的代價在括號）

1. 預設分頁改為「主頁」（原為紙條）。（小）
2. 「邀請朋友加入 PeerDrop」列與「邀請連結」快速入口：`RemoteInviteView` 目前**沒有任何呈現者且需要 MailboxManager**，不復活它。主頁邀請列＝系統分享面板分享 App Store 連結 `https://apps.apple.com/app/id6759594513`；附近的「邀請連結」入口＝開啟既有 `RelayConnectView`（可產生可分享的連線邀請）。（需改文件 §6.2/§6.4 措辭）
3. 「掃描」入口只在確認 `ConnectionQRView` 或其他現有畫面有掃描功能時才放（找不到就只放 3 個入口）。（小）
4. iOS：主頁「已連線」列 → `ConnectionView`（保留傳檔／通話／斷線）；「朋友」列 → 聊天（`ChatView`），對方在線時聊天標題旁有資訊鈕通往 `ConnectionView`。Mac：任何列都開 `MacChatWindow`。（小）
5. TabView 選取用 `.tint(brand)`，不做 highlight 圓角底（SwiftUI 原生 TabView 做不到）；與草稿略有差異。（小）
6. 三態比對只用 id 集合（record.id、peerDeviceId、連線 key、peerIdentity.id、探索 id）；不比憑證指紋；`.connecting` 算「附近」。（同裝置不同 id 仍可能誤判，PR 說明標註）
7. 日記本階段只套 tint 與 `.note` 底，不重做版面。（小）

## Review Focus

1. 已存紀錄的 id 與連線 key／探索 id 不一致（Bonjour 舊式 `name.type.domain`、手動 `host:port`、BLE `ble-…`、中繼 `relay-<code>`）→ 明明連著卻顯示「下線」。Task 2 測試涵蓋別名比對。
2. 夜間 `live` 色票的對比（brand 泡泡白字、勾勾在泡泡上、placeholder）。Task 1 測試。
3. 極長名字與最大動態字級下，主頁／紙條／附近的列不得截斷關鍵資訊或溢出（名字 `lineLimit(1)` 尾端省略，次要字最多兩行）。Task 6–8 手動截圖驗證。
4. 空狀態：沒有朋友、沒有對話、附近無裝置、沒有任何已連線。每個新畫面都要有非空白的說明（不得整段隱藏，見 v5.3.2 被拒教訓）。Task 6–8。
5. 刪除朋友後殘留聊天檔、同名合併造成 record id 變更（`DeviceRecordStore.addOrUpdate` 會採用新 id）→ 紙條清單不得出現幽靈列或崩潰。Task 5 測試。

---

### Task 0: 工作區與基準

**Files:** 無程式碼變更

- [ ] **Step 1:** 在 repo 根目錄 `git worktree add .worktrees/peer-drop-ui -b feat/ui-overhaul feat/swipe-to-reply`（`.worktrees` 已被忽略則略過 ignore 檢查；否則確認 `git check-ignore .worktrees`）。
- [ ] **Step 2:** 在 worktree 內 `xcodegen generate`，跑 `swift test`（PeerDropKit）與 iOS 全部測試一次，記錄基準：Kit 預期只有既有失敗 `IdentityKeyManagerTests.testKeyPersistsAcrossInstances`；iOS 預期全過。
- [ ] **Step 3:** 把計畫與設計文件從 `docs/ui-overhaul-msn-design` 分支帶進來：`git checkout docs/ui-overhaul-msn-design -- docs/superpowers/specs/2026-10-23-ui-overhaul-msn-design.md docs/superpowers/plans/2026-10-23-ui-overhaul-msn.md`，提交 `docs: add UI overhaul spec and plan`。

### Task 1: 主題支援 live／note 模式與新 token

**Files:**
- Modify: `PeerDrop/UI/Components/PaperTheme.swift`
- Test: `PeerDropTests/PaperThemeTests.swift`（加案例；既有案例不得改動結果）

**Interfaces:**
- Produces:
  - `enum PaperMode { case live, note }`
  - `PaperToken` 新增 cases：`brand`、`highlight`、`online`、`noteFill`、`noteBorder`、`noteText`、`noteBadge`（不分模式，兩模式同值）
  - `PaperPalette.hex(_ token: PaperToken, dark: Bool, mode: PaperMode = .note) -> UInt32`
  - `PaperTheme.color(_ token: PaperToken, mode: PaperMode = .note) -> Color`
  - `private struct PaperModeKey: EnvironmentKey`；`extension EnvironmentValues { var paperMode: PaperMode }`；`extension View { func paperMode(_ m: PaperMode) -> some View }`（設定環境值）
  - `PaperTheme.tick(for:)` 不變

- [ ] **Step 1: 寫失敗測試**（`PaperThemeTests`）：
  - `testLiveTextPairsMeetAA`：for dark in [false,true]，`(.incomingText,.incomingBubble)`、`(.outgoingText,.outgoingBubble)`、`(.incomingText,.background)`、`(.datePillText,.datePillFill)` 於 `mode: .live` ≥ 4.5。
  - `testLiveNonTextMeets3to1`：`.inputPlaceholder` on `.inputFill`、`.tickSent/.tickDelivered/.tickRead` on `.outgoingBubble`、`.highlight` on `.background`、`.online` on `.background` ≥ 3.0；`tickSent`、`tickDelivered`、`tickRead` 三值兩兩不同。
  - `testBrandWithWhiteLabel`：`contrastRatio(0xFFFFFF, hex(.brand, dark: d, mode: m))` ≥ 4.5（兩模式、淺深）。
  - `testNoteTokensContrast`：`.noteText` on `.noteFill` ≥ 4.5；`.noteBorder` on `.background`（live 與 note、淺深）≥ 3.0。
  - `testDefaultModeIsNoteAndUnchanged`：`hex(.background, dark:false)` == `0xFBF6EE`，`hex(.background, dark:true)` == `0x2A221C`。
  - `testLiveBackgroundValues`：light `.background` == `0xF4F9FD`、`.border` == `0xDDEAF4`、`.incomingText` == `0x1E2B36`。
- [ ] **Step 2:** 跑 `-only-testing:PeerDropTests/PaperThemeTests`，預期因 `PaperMode` 不存在而編譯失敗。
- [ ] **Step 3:** 實作。`hex` 內部對 `.live` 查獨立表；夜間 live 起始值：background `0F1720`、border `2A3846`、incomingBubble `1A2430`、incomingText `E6EEF5`、datePillText `93A4B5`、inputFill `1A2430`、inputPlaceholder `93A4B5`、`brand` 夜間 `0B6FC4`；live 淺色 outgoingBubble＝brand、outgoingText＝`FFFFFF`、tick 三值用白色的三種遞增不透明度混出的實色，且須通過上面測試；其餘未列 token 由實作者選值並以測試為準。`PaperTheme.color` 的動態色解析沿用現有 UIKit／AppKit 分支。
- [ ] **Step 4:** 跑 `PaperThemeTests` 全過（含既有案例）。
- [ ] **Step 5:** `git add` 兩檔，commit `feat: add live/note paper modes and MSN tokens`。

### Task 2: 在線三態純函式

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/PeerPresence.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/PeerPresenceTests.swift`

**Interfaces:**
- Produces:
  - `public enum PeerPresence: Equatable { case online, nearby, offline }`
  - `public struct PresenceSources { public var connected: Set<String>; public var connecting: Set<String>; public var discovered: Set<String>; public var server: Set<String> /* 專案 E 預留，現在恆為空 */ ; public init(connected:connecting:discovered:server: = []) }`
  - `public enum PeerPresenceResolver { public static func presence(ids: Set<String>, sources: PresenceSources) -> PeerPresence }` — `ids ∩ (connected ∪ server)` 非空→online；否則 `ids ∩ (connecting ∪ discovered)` 非空→nearby；否則 offline。
  - `extension ConnectionManager { public func presenceSources() -> PresenceSources; public func presence(for record: DeviceRecord) -> PeerPresence; public func presence(forGroup group: DeviceGroup) -> (online: Int, total: Int) }` — `presenceSources()`：connected＝`connections.values` 中 `state.isConnected` 者的 `{ $0.id, $0.peerIdentity.id }`；connecting＝`state == .connecting` 者同上；discovered＝`discoveredPeers.map(\.id)`。`presence(for:)` 的 ids＝`{record.id, record.peerDeviceId}`（非 nil 者）。

- [ ] **Step 1: 寫失敗測試**（純函式，無需 ConnectionManager）：`testConnectedWins`（ids 命中 connected 且同時命中 discovered → online）、`testConnectedByAliasIdentityID`（ids 含 peerIdentity.id，connected 含該 id → online）、`testRelayKeyDoesNotMatchButIdentityDoes`（connected `{"relay-ab","uuid-1"}`，ids `{"uuid-1"}` → online）、`testConnectingIsNearby`、`testDiscoveredOnlyIsNearby`、`testNothingIsOffline`、`testEmptyIDsIsOffline`、`testServerSourceCountsAsOnline`（server 命中 → online，驗證專案 E 擴充點）。
- [ ] **Step 2:** `swift test --filter PeerPresenceTests`，預期編譯失敗。
- [ ] **Step 3:** 實作上述型別；`ConnectionManager` 擴充放同檔，`@MainActor` 與該類別一致。
- [ ] **Step 4:** 跑測試全過；再跑 `swift test` 全部，確認只有既有失敗。
- [ ] **Step 5:** commit `feat: add PeerPresence resolver for online/nearby/offline`。

### Task 3: 頭像圓角、MSN 色盤、三態徽章

**Files:**
- Modify: `PeerDrop/UI/Components/PeerAvatar.swift`、`PeerDrop/UI/Chat/ChatAvatarSlot.swift`
- Create: `PeerDrop/UI/Components/PresenceBadge.swift`
- Test: `PeerDropTests/PeerAvatarTests.swift`（若既有同名檔則在其中加案例）
- Modify: `PeerDrop/App/Localizable.xcstrings`（三個 VoiceOver 字串）

**Interfaces:**
- Consumes: Task 1 的 `PaperTheme.color(_:mode:)`、Task 2 的 `PeerPresence`
- Produces:
  - `struct AvatarSwatch { let fill: UInt32; let label: UInt32 }`；`PeerAvatarPalette.swatches: [AvatarSwatch]`（四個 MSN 色，黃色的 label 為深色 `0x3A2A05`，其餘 `0xFFFFFF`）；`PeerAvatarPalette.swatch(for name: String) -> AvatarSwatch`（沿用 `StableHash` FNV-1a）
  - `enum PeerAvatarShape { static func cornerRadius(forSize size: CGFloat) -> CGFloat }`（≥44→16，否則 `size*0.36`）
  - `PeerAvatar.init(name:size:palette:presence:)`：`palette: [Color]? = nil`（nil＝MSN swatches；舊的 `paper`／`standard` 陣列保留供既有測試）、`presence: PeerPresence? = nil`（nil＝不畫徽章）
  - `struct PresenceBadge: View { let presence: PeerPresence; let avatarSize: CGFloat }`
  - `PeerPresence.accessibilityLabel: String`（本地化）
- 畫法：圓角方形；`.offline` 時頭像 `saturation(0.35)`；徽章右下角、以 `PaperTheme.color(.background)` 描 2pt 邊分離：online＝`.online` 實心圓；nearby＝`.highlight` 描邊白心圓；offline＝`.noteBadge` 圓角方形內放 `envelope.fill` SF Symbol（深色 glyph）。徽章直徑 ≈ `max(12, size*0.36)`。整個 `PeerAvatar` 的 accessibilityLabel 為「頭像 + 狀態文字」（現有 `accessibilityHidden(true)` 在有 presence 時改為不隱藏）。

- [ ] **Step 1: 寫失敗測試：** `testCornerRadius`（44→16、40→14.4、32→11.52、64→16）、`testSwatchStableForName`（同名回傳同色；`"Mika"` 與 `"小安"` 的 index 落在 0..<4）、`testSwatchLabelContrast`（四色 fill 與 label 對比 ≥ 4.5）、`testPresenceAccessibilityLabelsDistinct`（三態兩兩不同且非空）。
- [ ] **Step 2:** 跑測試，預期失敗。
- [ ] **Step 3:** 實作；把 `ChatAvatarSlot` 改用預設（MSN）調色盤。三個 VoiceOver 字串（en：`Online`、`Nearby, not connected`、`Offline, notes only`）用 `String(localized:)` 並補五語系。
- [ ] **Step 4:** 跑 `PeerAvatarTests` 與 `PaperThemeTests`；`xcodebuild build` iOS 與 Mac scheme 皆需成功（確認 `PeerAvatar` 的 11 個既有呼叫端無需修改即可編譯）。
- [ ] **Step 5:** commit `feat: rounded MSN avatars with presence badge`。

### Task 4: 聊天畫面 live／note 切換與下線提示

**Files:**
- Modify: `PeerDrop/UI/Chat/ChatView.swift`、`ChatBubbleView.swift`、`GroupChatView.swift`、`DecryptFailureBannerView.swift`、`ReactionPickerView.swift`、`TypingIndicatorView.swift`、`GroupReadReceiptView.swift`、`ChatDatePill.swift`、`ChatSearchView.swift`、`EmptyChatView.swift`、`PeerDrop/UI/Components/StatusToastView.swift`、`PeerDropMac/Views/MacChatWindow.swift`
- Modify: `PeerDrop/App/Localizable.xcstrings`
- Test: `PeerDropTests/ChatPresenceModeTests.swift`

**Interfaces:**
- Consumes: Task 1 `\.paperMode`、`PaperTheme.color(_:mode:)`；Task 2 `ConnectionManager.presence(for:)`／`presenceSources()`
- Produces: `enum ChatPresenceMode { static func mode(for presence: PeerPresence) -> PaperMode }`（online→`.live`；nearby 與 offline→`.note`，因為只有已連線才能即時聊）；`ChatView` 內 `.paperMode(mode)` 套在根視圖，並 `.animation(.easeInOut(duration: 0.25), value: mode)`；`PeerDrop/UI/Chat` 內每個 view 以 `@Environment(\.paperMode)` 取模式並呼叫 `PaperTheme.color(token, mode:)`。

- [ ] **Step 1: 寫失敗測試：** `testOnlineIsLive`、`testNearbyIsNote`、`testOfflineIsNote`。
- [ ] **Step 2:** 跑測試，預期失敗。
- [ ] **Step 3:** 實作 `ChatPresenceMode`；ChatView 以 `ChatPeerPresence`／presence 判斷模式（沿用現有 `isPeerDisconnected` 結果：斷線→note）；機械式地把 Chat 目錄所有 `PaperTheme.color(.x)` 換成帶 `mode:` 的版本（共約 70 處，`grep -rn "PaperTheme.color(" PeerDrop/UI PeerDropMac` 確認清零）；ChatView 標題 principal 改為 `PeerAvatar(name:, size: 30, presence:)`＋名字；斷線橫幅（`ChatView.swift` 約 L202）文案改為 `"%@ is offline. Chat again when they're back."`（zh-Hant：`%@ 下線了，上線後再聊`），輸入列維持現有停用行為與 placeholder；**不實作**紙條泡泡樣式與離線寄送。`MacChatWindow` 背景改為依 mode。
- [ ] **Step 4:** 跑 `ChatPresenceModeTests`、`PaperThemeTests`、其餘 Chat 相關測試（`SwipeReplyLogicTests` 等）；iOS 與 Mac 建置通過；模擬器截圖：在線（用 SCREENSHOT_MODE 的假對象）與下線的聊天畫面各一張，淺色與夜間，目視確認底色切換、勾勾可見、橫幅文字。
- [ ] **Step 5:** commit `feat: live/note chat modes and offline banner`。

### Task 5: 紙條清單所需的對話摘要查詢（Kit）

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropCore/ChatManager.swift`
- Create: `PeerDropKit/Sources/PeerDropCore/ConversationSummary.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/ConversationSummaryTests.swift`

**Interfaces:**
- Produces:
  - `public struct ConversationSummary: Identifiable, Equatable { public let id: String /* peerID 或 groupID */; public let isGroup: Bool; public let lastMessage: ChatMessage?; public let lastActivity: Date?; public let unread: Int }`
  - `public enum ConversationPreview { public static func text(for message: ChatMessage) -> String }`：已刪除→本地化「訊息已刪除」；純文字→`text`；媒體依 `mediaType` 分別為「📷 照片」「🎙 語音訊息」「📄 {fileName}」，未知媒體→「附件」（實作者讀 `ChatMessage.swift` 確認 `mediaType` 字串值）。
  - `ChatManager.summary(forPeer id: String) -> ConversationSummary` 與 `summary(forGroup id: String) -> ConversationSummary`（`@MainActor`、唯讀）：最後一則＝`pendingMessages[id]?.last`，否則讀檔取最後一則；讀檔結果以「檔案修改時間」為鍵快取，不需在寫入路徑加失效程式；檔案不存在或解密失敗→`lastMessage == nil`；`unread` 取 `unreadCounts`／`groupUnreadCount(for:)`。**不得**呼叫 `loadMessages(forPeer:)`（它會改動全域 `messages`）。

- [ ] **Step 1: 寫失敗測試**（用 `ChatManager(rootDirectory: tempDir)`）：`testSummaryOfPeerWithMessagesReturnsLast`、`testSummaryOfPeerWithoutFileHasNilLast`、`testPendingMessageIsVisibleBeforeFlush`（剛 `saveOutgoing` 未 flush 即可看到）、`testSummaryDoesNotChangeActiveChat`（呼叫後 `messages`、`activeChatPeerID` 不變）、`testCacheRefreshesWhenFileChanges`（flush 新訊息後 summary 更新）、`testDeletedPeerHasNilLast`（`deleteMessages(forPeer:)` 後 nil）、`testGroupSummary`、`testPreviewTexts`（文字／已刪除／各媒體類型）。
- [ ] **Step 2:** `swift test --filter ConversationSummaryTests`，預期失敗。
- [ ] **Step 3:** 實作；摘要型別放新檔，`ChatManager` 只加兩個方法與一個私有快取字典。
- [ ] **Step 4:** 測試全過，再 `swift test` 全部。
- [ ] **Step 5:** commit `feat: add read-only conversation summaries to ChatManager`。

### Task 6: 主頁（HomeTab）

**Files:**
- Create: `PeerDrop/UI/Home/HomeTab.swift`、`PeerDrop/UI/Home/FriendRow.swift`、`PeerDrop/UI/Home/ChatTarget.swift`
- Modify: `PeerDrop/UI/SettingsView.swift`（最上方加「傳輸紀錄」列，點了以 sheet 開 `TransferHistoryView`）
- Modify: `PeerDrop/App/Localizable.xcstrings`
- Test: `PeerDropTests/HomeTabLogicTests.swift`

**Interfaces:**
- Consumes: Task 2 `presence(for:)`／`presence(forGroup:)`；Task 3 `PeerAvatar(presence:)`；Task 1 live 主題
- Produces:
  - `struct ChatTarget: Hashable { let peerID: String; let name: String }`（`navigationDestination(for:)` 的資料）
  - `enum HomeListLogic { static func sections(records: [DeviceRecord], presence: (DeviceRecord) -> PeerPresence, query: String) -> (connected: [DeviceRecord], friends: [DeviceRecord]) }` — connected＝presence==online；friends＝其餘；兩區各依 `displayName` 排序；`query` 非空時只留名字包含（大小寫與全半形不敏感）者；同一個 record 不會同時出現在兩區。
  - `enum FriendSubtitle { static func text(presence: PeerPresence, lastConnected: Date, connectionCount: Int, source: String) -> String }`：online＝「已連線 · 區域網路／中繼」；nearby＝「附近 · 可連線」；offline 且 `connectionCount > 0`＝「上次在線 {相對時間}」；offline 且 0＝「尚未連線過」。
  - `struct HomeTab: View`：無參數，`@EnvironmentObject connectionManager`。版型（見設計文件 §6.2）：粗體大標題「主頁」；toolbar 搜尋（`.searchable`，只搜名字）、加朋友（切到附近分頁：透過 `@Binding var selectedTab: AppTab`，由 Task 9 提供型別；本任務先用 `var onAddFriend: () -> Void` 閉包）、設定齒輪（`#if os(iOS)` sheet `SettingsView`，Mac 不顯示）；自己的資料列（44pt 頭像＋ `connectionManager.localIdentity.displayName`，點擊：iOS 開 `SettingsView`，Mac 無動作；實作者先確認是否存在 `UserProfileView`，存在就用它）；區段「已連線 N」「朋友 N」「群組」（沿用 `GroupRow`、`GroupDetailView`、`GroupEditorView`、「New Group」按鈕、刪除群組）；列右側：附近且未連線者顯示填色膠囊「連線」（呼叫 `connectionManager.reconnect(to: record.id)`）；最底「邀請朋友加入 PeerDrop」列（Ruling 2：`ShareLink`／`ShareSheet` 分享 App Store 連結）。刪除朋友沿用 `connectionManager.forgetDevice(id:)`（swipe）。
  - 導覽：iOS「已連線」列→ `ConnectionView`（先 `connectionManager.focus(on:)`）；「朋友」列→ `ChatView`（`ChatTarget`）；Mac 兩者皆 `openWindow(id: "chat", value: peerID)`。peerID 取 `connectionManager.connection(for: record.id)?.peerIdentity.id ?? record.id`。
  - 空狀態：沒有任何紀錄與群組時顯示說明＋「到『附近』找朋友」按鈕（不可整段隱藏）。

- [ ] **Step 1: 寫失敗測試**（`HomeListLogic`、`FriendSubtitle` 純函式）：已連線與朋友分區不重疊、排序、搜尋（`"mi"` 找到 `Mika`、找不到 `Jordan`）、搜尋全形、空 query 全列、各副標題四種情況。
- [ ] **Step 2:** 跑測試，預期失敗。
- [ ] **Step 3:** 實作；新字串補五語系（Home、Friends、Connected %lld、Friends %lld、Invite friends to PeerDrop、Connect、No friends yet、Find nearby friends、Last online %@、Not connected yet、Nearby · ready to connect 等）。`LibraryTab`、`ConnectedTab` 先不刪。
- [ ] **Step 4:** 測試過；iOS／Mac 建置過；用 SCREENSHOT_MODE 暫時掛上 HomeTab 截圖（不提交）檢查：淺色／夜間、最大字級、超長名字（20 字）、空狀態。
- [ ] **Step 5:** commit `feat: add Home tab`。

### Task 7: 紙條分頁（ConversationsTab）

**Files:**
- Create: `PeerDrop/UI/Conversations/ConversationsTab.swift`、`ConversationRow.swift`
- Modify: `PeerDrop/App/Localizable.xcstrings`
- Test: `PeerDropTests/ConversationsLogicTests.swift`

**Interfaces:**
- Consumes: Task 5 `ConversationSummary`／`ConversationPreview`；Task 6 `ChatTarget`；Task 2 presence
- Produces:
  - `enum ConversationsLogic { static func rows(records: [DeviceRecord], groups: [DeviceGroup], summaryForPeer: (String) -> ConversationSummary, summaryForGroup: (String) -> ConversationSummary, query: String) -> [ConversationSummary + 顯示名稱的 row 模型 ConversationRowModel] }` — 只列有 `lastMessage != nil` 的朋友與群組；依 `lastActivity` 由新到舊；`query` 只比對名稱。沒有對應 `DeviceRecord` 的孤兒聊天檔**不列**。
  - `struct ConversationsTab: View`：大標題「紙條」；toolbar 搜尋、新增（開啟朋友挑選：點朋友→聊天）；最上方固定一列「紙條信箱（N 張未讀）」＝`NavigationLink` 到既有 `NotesInboxView`（Ruling：遠端紙條功能原封不動；需要 `NotesStore`、`AccountManager`、`openNoteID`、`path` 綁定的部分，由 ContentView 注入或沿用現有 `NotesTabContent` 的呼叫方式，由 Task 9 接線，本任務以 `@ViewBuilder var inbox: () -> Inbox` 參數注入）；對話列＝頭像（含三態）、名字、最後一則預覽（`ConversationPreview.text`）、時間、`brand` 色未讀徽章；群組列頭像用 `person.3.fill` 方塊且不顯示三態；點擊→ `ChatTarget` 聊天／`GroupChatView`。
  - 空狀態：「還沒有對話。到『主頁』選一位朋友開始聊。」＋按鈕。

- [ ] **Step 1: 寫失敗測試：** 排序最新在上、無訊息者不列、孤兒聊天檔（summary 有但 records 無）不列、群組混排、`query` 過濾、名稱相同兩人各一列（以 id 區分）、同名合併後（record id 改變、舊 id 有聊天檔）不崩潰且不出現幽靈列。
- [ ] **Step 2:** 跑測試，預期失敗。
- [ ] **Step 3:** 實作；新字串補五語系。
- [ ] **Step 4:** 測試過；iOS／Mac 建置過；截圖檢查淺／夜、最大字級、預覽很長的訊息（單行省略）、空狀態。
- [ ] **Step 5:** commit `feat: add Notes conversation list tab`。

### Task 8: 附近分頁改版

**Files:**
- Modify: `PeerDrop/UI/Discovery/NearbyTab.swift`、`PeerDrop/UI/Discovery/PeerRowView.swift`、`PeerDrop/UI/Components/PeerGridItemView.swift`
- Create: `PeerDrop/UI/Discovery/NearbyQuickActions.swift`
- Modify: `PeerDrop/App/Localizable.xcstrings`
- Test: `PeerDropTests/NearbyQuickActionsTests.swift`

**Interfaces:**
- Produces:
  - `enum NearbyQuickAction: CaseIterable { case qr, manual, invite, scan }` 與 `static func available(relayEnabled: Bool, hasScanner: Bool) -> [NearbyQuickAction]`（`invite` 需 `relayEnabled`；`scan` 需 `hasScanner`；順序固定 qr、manual、invite、scan）
  - `NearbyTab.init(selectedTab: Binding<AppTab>)`（`AppTab` 由 Task 9 建立；**本任務為了可獨立編譯，先在 `NearbyTab.swift` 內不改簽名，Task 9 一次改**——因此本任務只動版面，不動 `selectedTab` 型別）
- 內容：頂端一排快速入口（圖示＋文字）：QR→`.connectionQR`、手動連線→`.manualConnect`、邀請連結→`.relayConnect`（Ruling 2）、掃描（Ruling 3）；其後依來源分段「區域網路」「藍牙」（沿用 `networkPeers`／`bleOnlyPeers`），列右側改為 `PeerRowView` 的填色膠囊「連線」（brand 底白字）；另加一列「用邀請碼連線（中繼）」入口列（僅 `FeatureSettings.isRelayEnabled`）開 `RelayConnectView`；toolbar 移除設定與傳輸紀錄（已搬到主頁／設定）；保留上線開關、格狀／列表切換、排序、搜尋；`.sheet` 的 `.settings`、`.transferHistory` case 刪除；`GuidanceCard` 與「Searching…」空狀態保留。頭像傳入 `presence`。
- [ ] **Step 1: 寫失敗測試：** `available` 在 relay 關閉時不含 invite、無 scanner 時不含 scan、順序固定、全開時四項。
- [ ] **Step 2:** 跑測試，預期失敗。
- [ ] **Step 3:** 實作（版面用 live 底色：`.scrollContentBackground(.hidden)` ＋ `PaperTheme.color(.background, mode: .live)`）。
- [ ] **Step 4:** 測試過；iOS／Mac 建置過；截圖檢查（淺／夜／最大字級／無裝置空狀態）。確認 §9 清單：QR、手動 IP、中繼、LAN／BLE 探索、編輯手動 peer 仍可達。
- [ ] **Step 5:** commit `feat: redesign Nearby tab with quick actions`。

### Task 9: iOS 殼層四分頁

**Files:**
- Create: `PeerDrop/UI/AppTab.swift`
- Modify: `PeerDrop/UI/ContentView.swift`、`PeerDrop/UI/Discovery/NearbyTab.swift`、`PeerDrop/App/AppDelegate.swift`（只改註解）、`PeerDropMac/Views/MacDetailRouter.swift`（`NearbyTab` 的 binding 型別）
- Delete: `PeerDrop/UI/Connection/ConnectedTab.swift`、`PeerDrop/UI/Library/LibraryTab.swift`、`PeerDrop/UI/Discovery/DiscoveryView.swift`（無人使用；`GroupRow`、`GroupDetailView`、`DeviceRecordRow` 保留）；`project.yml` 的 Mac exclude 清單同步移除已刪檔案
- Test: `PeerDropTests/AppTabTests.swift`

**Interfaces:**
- Produces: `enum AppTab: Int, CaseIterable { case home, notes, nearby, diaries }`；`NearbyTab(selectedTab: Binding<AppTab>)`。
- ContentView：`@State private var selectedTab: AppTab = .home`；TabView 順序 主頁／紙條／附近／日記，標籤文字 `Home`（新 key）、`Notes`、`Nearby`、`Diaries`（沿用）；`HomeTab`、`ConversationsTab(inbox: { NotesTabContent … })`、`NavigationStack { NearbyTab }`、`DiaryTabContent` 各自包 `NavigationStack` 與 `.navigationDestination(for: ChatTarget.self) { ChatView(chatManager:peerID:peerName:) }`；所有原本的數字改為：`.openNote`→`.notes`、`.openDiary`→`.diaries`、錯誤對話框兩處→`.nearby`、連線成功（`.connected/.transferring/.voiceCall`）→`.home`、`NearbyTab` 點擊已連線 peer（原 `selectedTab = 1`）→`.home`；Notes 分頁的 `.badge(store.unreadCount)` 保留；`ConversationsTab` 的紙條信箱列取代 Notes 原分頁的入口；整個 TabView `.tint(PaperTheme.color(.brand))`；日記 tab 套 `.paperMode(.note)`（Ruling 7）。
- 刪除檔案前 `grep -rn "ConnectedTab\|LibraryTab\|DiscoveryView" PeerDrop PeerDropMac PeerDropTests` 確認無殘留參照（`ConnectedTab` 的 `reconnect` 邏輯已由 `ConnectionManager.reconnect(to:)` 取代）。

- [ ] **Step 1: 寫失敗測試：** `testRawValuesAreStable`（home 0、notes 1、nearby 2、diaries 3）、`testAllCasesOrder`、`testNoMagicNumbersRemain`（讀 `ContentView.swift` 原始碼字串，斷言不含 `selectedTab = ` 後接數字的樣式——用 Regex `selectedTab\s*=\s*\d`；測試以 `#filePath` 定位檔案）。
- [ ] **Step 2:** 跑測試，預期失敗。
- [ ] **Step 3:** 實作。推播深連結（`openNote`／`openDiary`）行為需手動驗證仍切到正確分頁。
- [ ] **Step 4:** `xcodegen generate`；iOS 全部測試；iOS 與 Mac 建置；模擬器逐頁截圖四個分頁（淺／夜），並逐項走完設計文件 §9 清單，在 commit 描述或 PR 說明列出每項新入口位置。
- [ ] **Step 5:** commit `feat: four-tab navigation (Home, Notes, Nearby, Diaries)`。

### Task 10: Mac 側邊欄與選單

**Files:**
- Modify: `PeerDropMac/Views/MacSidebar.swift`、`MacContentView.swift`、`MacDetailRouter.swift`、`PeerDropCommands.swift`
- Modify: `PeerDrop/App/Localizable.xcstrings`
- Test: `PeerDropTests/MacSidebarSectionTests.swift`（若 PeerDropTests 無法編入 Mac 型別，改用 `PeerDropMacUITests`；實作者確認後擇一，檔案位置在 commit 說明記載）

**Interfaces:**
- `MacSidebarSection`：`case home, notes, nearby, diaries`；`localizedName`（`NSLocalizedString("Home"/"Notes"/"Nearby"/"Diaries")`）、`icon`（home `house`、notes `envelope.fill`、nearby `wifi`、diaries `book.closed`）；`MacContentView` 預設 `.home`；`MacDetailRouter` 的 `.home`→`NavigationStack { HomeTab(...) }`（Mac 不顯示齒輪），`.notes`→`ConversationsTab`（inbox 參數為 `NotesInboxView`），`.nearby`→`NearbyTab`（中繼入口列開 sheet `RelayConnectView`），移除 `.trusted`／`.relay`；`.none` 說明文字改為 `Pick Home, Notes, Nearby, or Diaries from the sidebar.`；`PeerDropCommands`：⌘⌥1 主頁、⌘⌥2 紙條、⌘⌥3 附近、⌘⌥4 日記，刪除 ⌘⌥5 與 Library／Relay 項；`.openNote`→`.notes`、`.openDiary`→`.diaries`（`MacContentView`）；主頁與紙條的朋友列→ `openWindow(id: "chat", value:)`。
- [ ] **Step 1: 寫失敗測試：** `testSectionOrderAndCount`、`testEveryCaseHasNameAndIcon`、`testNoRetiredSections`（`allCases.map(\.rawValue)` == `["home","notes","nearby","diaries"]`）。
- [ ] **Step 2:** 跑測試，預期失敗。
- [ ] **Step 3:** 實作；用 `grep -rn "\.trusted\|\.relay\|Library\|macSidebarJump" PeerDropMac` 確認沒有殘留；字串 `Library`／`Relay` 若不再被任何地方使用則不刪 catalog 項（避免破壞其他語系資料），只在 PR 說明提及。
- [ ] **Step 4:** Mac 建置（用 Apple Development 簽名，避免 ad-hoc 的 keychain 提示）；實際啟動 `-SCREENSHOT_MODE` 版本，驗證四段側邊欄、快捷鍵、點朋友開聊天視窗、下線朋友聊天視窗底色為 note、夜間外觀；`.macSidebarJump` 與推播深連結行為。
- [ ] **Step 5:** commit `feat(mac): four-section sidebar and shortcuts`。

### Task 11: 在地化檢查與全面驗證

**Files:**
- Modify: `PeerDrop/App/Localizable.xcstrings`（僅補缺）
- 不新增程式碼

- [ ] **Step 1:** 用唯讀 Python（`-I`，只讀不寫）列出本分支相對 `feat/swipe-to-reply` 新增的 key，確認每個都有 en、zh-Hant、zh-Hans、ja、ko；缺的以文字插入補齊；非繁中確認有 `needs_review`。
- [ ] **Step 2:** 跑 Kit 全部測試與 iOS 全部測試，預期僅有既有的 Keychain 失敗；iOS 與 Mac scheme 皆建置成功。
- [ ] **Step 3:** 實機：以 `devicectl` 安裝到 iPhone 17 Pro、Mac 安裝開發版；請使用者驗證：三態徽章在真實連線／斷線時的變化、聊天底色切換、四分頁的所有功能入口（§9）、推播深連結、最大字級。**實機項目由使用者確認，我不宣稱通過。**
- [ ] **Step 4:** PR 說明列出：Rulings、已知缺口（同裝置不同 id 可能誤判）、與 `product-goals.md` 的差異、§9 功能入口對照表、zh-Hans／ja／ko 待校對。
- [ ] **Step 5:** 不 push、不開 PR，待使用者決定。
