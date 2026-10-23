# 專案 C：紙條進入朋友對話串 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 兩人在本地加密連線中「雙方都按下」才交換紙條帳號，綁定後紙條與即時聊天出現在同一個對話串，下線時可寄紙條。

**Architecture:** 新增一種受能力旗標閘控、只收「加密信封內」的訊息 `notesExchange`，以先承諾（intent）後揭露（reveal）的純函式狀態機驅動；驗證通過後寫入 `TrustedContact` 的帳號綁定（唯一）。對話串在顯示層合併 `ChatManager` 聊天訊息與 `NotesStore` 紙條（`ThreadItem`），輸入框模式由純函式 `ThreadTransport.decide` 決定；寄出走新的本機加密待寄清單。不改既有儲存格式與伺服器。

**Tech Stack:** Swift 5.9、SwiftUI、PeerDropKit（SwiftPM：PeerDropProtocol／Security／Core／Notes／Account）、XCTest、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-10-23-project-c-notes-threads-design.md`（已核可；**§10 修正 §4，以 §10 為準**）。程式碼對照表：`/private/tmp/claude-501/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/2be360a0-ac37-4ca5-ad88-48c331fbf475/scratchpad/code-map-c-plan.md`（行號可能位移，動手前重新 grep）。

**Base（重要）：** 實作分支 `feat/project-c` 從 **`docs/project-c-notes-threads`**（已含完整的 UI 改版 `feat/ui-overhaul`）切出，worktree `.worktrees/peer-drop-c`。不得從 `main` 切。

## Global Constraints

- 繁體中文台灣用語；commit 格式 `type: short description`，結尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`；不得 `git commit -a`；不得提交 `.gitignore` 的未提交修改與 `docs/pet-design/`；不得 push。
- **隱私鐵律**：雙方都按下之前，不得傳送任何帳號資訊；`intent` 不含帳號資訊。第一版**不做盲發**。
- 不改既有儲存格式、既有訊息、伺服器；新增僅限：HELLO 一個可選旗標、一種訊息型別 `notesExchange`、`TrustedContact` 的可選欄位、本機待寄清單。
- 新 `MessageType` 只有在**雙方都宣告 `supportsNotesExchange`** 時才送；舊版收到未知型別會斷線，所以閘控是硬性要求；`notesExchange` **不得**加入 `unwrappedControlTypes`。
- 守門條件（缺一不可）：`secureChannelState == .secured`；握手實際對方公鑰（`handshakePeerIdentityKey`）＝ HELLO 自稱公鑰 ＝ 釘選公鑰；`pinningVerdict` 已評估且為 `matched` 或 `firstTrust`（`notChecked`、`mismatch` 皆拒絕）；本地直連（**非中繼、非 tailnet**）；訊息來源為**加密信封**；明文一律丟棄。
- `reveal` 驗證：`AccountID(raw:)` 嚴格解析；目錄 `entry.accountId.raw == 揭露值`、`entry.identityKey == 握手公鑰`、`entry.signingKey == 揭露的 signingKey`；簽章（Ed25519，signingKey）通過，摘要依角色排序、不做字典序排序：`SHA256("peerdrop-notes-exchange-v1" ‖ accountId(8 bytes utf8) ‖ 揭露者握手公鑰(32) ‖ 驗證者握手公鑰(32) ‖ 揭露者 nonce(32) ‖ 驗證者 nonce(32))`（nonce 來自雙方 `intent`；簽署用 (keys.mine, keys.theirs, nonces.mine, nonces.theirs)，驗證用 (keys.theirs, keys.mine, nonces.theirs, nonces.mine)）；小階 Ed25519 簽章金鑰與全零簽章拒絕。
- 所有「透過帳號 ID 寄信」都必須斷言 `entry.accountId == 綁定帳號` 且 `entry.identityKey == 釘選公鑰`（目錄會先以 ID 找、再以暱稱找）。
- 五語系（en、zh-Hant、zh-Hans、ja、ko）；`Localizable.xcstrings` 只用文字插入；非繁中 `needs_review`；新增 Swift 檔後 `xcodegen generate`，並還原 pbxproj 雜訊（根 group 名稱 `peer-drop` id `9EC0E908E1A38EE0458CEC1B`、Secrets.xcconfig ref `71060D2244B026D50B454D62`）；diff 只應新增。
- 建置／測試（外接碟會斷線，derivedDataPath 用 scratchpad `$S`＝`/private/tmp/claude-501/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/2be360a0-ac37-4ca5-ad88-48c331fbf475/scratchpad`）：Kit `cd PeerDropKit && swift test --filter <Class>`（預期唯一既有失敗 `IdentityKeyManagerTests.testKeyPersistsAcrossInstances`）；iOS `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -derivedDataPath "$S/dd-sim" -only-testing:PeerDropTests/<Class>`；Mac `xcodebuild build -scheme PeerDropMac -derivedDataPath "$S/dd-mac-new" CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -allowProvisioningUpdates`（Apple Development 簽名，勿 ad-hoc）。
- **同一程序內兩個真實 `ConnectionManager` 無法達到 `.secured`**（共用 `IdentityKeyManager.shared`，握手拒絕相同公鑰）：整合測試用「一個真實 CM ＋ 腳本化的 `PeerConnection` 對端」（範本：`ConnectionManagerSenderBindingTests` 的 `test_M3_…`）；CM↔CM 與跨版本在**獨立程序**驗證（peerdrop-cli `--name`）。

## Rulings（計畫層級決定）

1. **tailnet 不算面對面**：以 `isTailnetIP(remoteHost)` 排除，與中繼同樣拒絕。
2. **綁定掛在 `TrustedContact`**（以握手公鑰為準）；主動撥號端從不呼叫 `checkPeerTrust`，因此綁定時若找不到聯絡人要**建立**（trustLevel `.unknown`），若找到（以握手公鑰）但 `deviceId == nil` 要補上 `deviceId = peerIdentity.id`。
3. **每連線的隨機值**由 `intent` 帶（各 32 bytes），因為加密通道沒有可讀的連線隨機值。
4. 交換 session 狀態存在 CM 的 `[ObjectIdentifier(PeerConnection): NotesExchangeSession]`，於 `handlePeerDisconnected`／`removeConnection` 清除。
5. `ConversationSummary` 增加 `lastActivity` 可被覆寫的建構方式，用來折入紙條。
6. 手動輸入 ID 寄紙條、紙條信箱、已寄出清單：行為不變。

## Review Focus

1. **同時按下、重放舊 `intent`／`reveal`、未 `intent` 先收 `reveal`、`intent` 逾時、明文注入**——全部不得導致綁定或洩漏帳號（C3、C4）。
2. **綁錯人**：握手公鑰≠HELLO 公鑰、目錄 `identityKey` 不符、目錄以暱稱命中別的帳號、簽章綁定別的連線（C3、C4）。
3. **舊版相容**：新版不對舊版（無旗標）或中繼連線送 `notesExchange`；舊版 HELLO 解碼不受影響（C1、C10）。
4. **紙條歸屬與去重**：已綁定的紙條不重複出現在信箱；未讀只算一次；匿名／未驗證／無法解密不併入（C7、C9）。
5. **寄信失敗不消失**：離線、重複、綁定期間被清除、重試上限與 24 小時（C6）。

---

### Task 0: 工作區

- [ ] 在 repo 根 `git worktree add .worktrees/peer-drop-c -b feat/project-c docs/project-c-notes-threads`；複製被忽略的 `Secrets.xcconfig`（不提交）；`xcodegen generate` 後還原 pbxproj 雜訊。
- [ ] 跑 Kit `swift test` 與 iOS 全部測試記錄基準（預期只有已知失敗）。無程式碼變更不需 commit。

### Task 1: 能力旗標、訊息型別、信封來源

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropSecurity/PeerIdentity.swift`、`PeerDropKit/Sources/PeerDropProtocol/MessageType.swift`、`PeerDropProtocol/PeerMessage.swift`、`PeerDropCore/PeerConnection.swift`、`PeerDropCore/ConnectionManager.swift`
- Create: `PeerDropKit/Sources/PeerDropProtocol/NotesExchangePayload.swift`
- Test: `PeerDropKit/Tests/PeerDropSecurityTests/PeerIdentityNotesExchangeTests.swift`、`PeerDropKit/Tests/PeerDropCoreTests/PeerConnectionMessageOriginTests.swift`、`PeerDropKit/Tests/PeerDropProtocolTests/NotesExchangePayloadTests.swift`

**Interfaces:**
- Produces:
  - `PeerIdentity.supportsNotesExchange: Bool`（`public let`；兩個 init 預設 `false`；`CodingKeys` 新增；解碼 `decodeIfPresent ?? false`；`local()` 設 `true`，headless（`fileStore != nil`）為 `false`）
  - `MessageType.notesExchange`
  - `public struct NotesExchangePayload: Codable, Equatable { public var phase: String; public var nonce: Data?; public var accountId: String?; public var signingKey: Data?; public var signature: Data? }` 與 `PeerMessage.notesExchange(_:senderID:) throws`；`NotesExchangePhase`（`intent|reveal|cancel|unavailable`，以字串比對，**未知值為 no-op 不拋錯**）
  - `PeerConnection.MessageOrigin { case envelope, plaintext }`；`PeerConnection.onMessageReceivedWithOrigin: ((PeerMessage, MessageOrigin) -> Void)?`；私有 `deliver(_:_:)` 優先用新 closure，否則退回原 `onMessageReceived`（信封分支 `.envelope`、明文分支 `.plaintext`），**既有約 10 個測試站點的單參數 closure 必須照常編譯**
  - CM：`dispatchBound(_:on:origin:)`、`handleMessageForPeer(_:peerConnection:origin: MessageOrigin = .plaintext)`；`addConnection` 設定新 closure；新增 `case .notesExchange:` 暫時只做「非信封或非 `.secured` 則靜默丟棄」的守門（內容於 C4 實作）
  - 中繼 HELLO（CM `startRelayHandshake` 發送處）改送 `supportsNotesExchange: false` 的 `PeerIdentity` 副本

- [ ] **Step 1: 寫失敗測試**
  - `PeerIdentityNotesExchangeTests`：`testLegacyHelloDecodesWithoutFlag`（舊 JSON `{"id":"abc","displayName":"Old","supportsSecureChannel":true}` → false）、`testFlagRoundTrips`、`testOldDecoderIgnoresUnknownKey`（以舊欄位集合解碼含新鍵的 JSON 不失敗）。
  - `NotesExchangePayloadTests`：往返、未知 `phase` 解碼成功、缺少欄位解碼成功。
  - `PeerConnectionMessageOriginTests`（用 `makeSecuredPair()`，範本 `PeerConnectionPlaintextAfterSecureTests`）：信封內的 `notesExchange` 以 `.envelope` 送達；明文 `notesExchange`（secured 通道、legacy 接受期）以 `.plaintext` 送達；既有單參數 closure 仍被呼叫。
  - `MessageType.allCases` 的既有不變式測試（plaintext-after-secure）仍通過：`notesExchange` 不在 `unwrappedControlTypes`。
- [ ] **Step 2:** 跑上述測試，預期編譯失敗。
- [ ] **Step 3:** 實作上列介面（機械式；`PeerIdentity` 四處編輯依對照表第 1 項；CM 中繼 HELLO 用副本）。
- [ ] **Step 4:** Kit `swift test` 全部（僅既有失敗）；iOS 與 Mac 建置通過（`PeerIdentity` 被兩邊共用）。
- [ ] **Step 5:** commit `feat: notes-exchange capability flag, message type and envelope-origin plumbing`

### Task 2: TrustedContact 帳號綁定

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropSecurity/TrustedContact.swift`、`TrustedContactStore.swift`
- Test: `PeerDropKit/Tests/PeerDropSecurityTests/TrustedContactAccountBindingTests.swift`

**Interfaces:**
- Produces:
  - `public struct PendingAccountBinding: Codable, Equatable { public let accountId: String; public let signingKey: Data; public let handshakeKeyHash: Data; public let receivedAt: Date }`
  - `TrustedContact.pendingAccountBinding: PendingAccountBinding?`（init 參數預設 `nil`；`CodingKeys`、`decodeIfPresent`）
  - `TrustedContactStore.find(byAccountId:) -> TrustedContact?`
  - `TrustedContactStore.setAccountBinding(for id: UUID, accountId: String?)`：設定時**清除其他所有聯絡人的相同 `accountId`**，同時清空該聯絡人的 `pendingAccountBinding`；`nil` 表示解除綁定
  - `TrustedContactStore.setPendingBinding(for id: UUID, _ binding: PendingAccountBinding?)`
  - `TrustedContactStore.setDeviceId(for id: UUID, _ deviceId: String)`（只在目前為 `nil` 時填入）
  - `updatePublicKey(for:newKey:…)` 當 `oldKey != newKey` 時，**清除該聯絡人的 `accountId` 與 `pendingAccountBinding`**

- [ ] **Step 1: 寫失敗測試**：`testFindByAccountId`、`testSetBindingClearsSameAccountOnOtherContacts`、`testUnbindClearsAccount`、`testBindingClearsPending`、`testKeyChangeClearsBindingAndPending`、`testSameKeyUpdateKeepsBinding`、`testLegacyJSONWithoutPendingDecodes`、`testPendingRoundTripsEncrypted`、`testSetDeviceIdOnlyWhenNil`。
- [ ] **Step 2:** 跑測試確認失敗。
- [ ] **Step 3:** 實作（沿用現有 mutator 形狀與 `scheduleSave()`）。
- [ ] **Step 4:** `swift test --filter TrustedContact` 全過，再跑全部。
- [ ] **Step 5:** commit `feat: unique account binding and pending binding on TrustedContact`

### Task 3: 交換狀態機、守門與簽章（純函式）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/NotesExchange/NotesExchangeSession.swift`、`NotesExchangeGate.swift`、`NotesExchangeCrypto.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/NotesExchangeSessionTests.swift`、`NotesExchangeGateTests.swift`、`NotesExchangeCryptoTests.swift`

**Interfaces:**
- Produces:
  - `public struct NotesExchangeFacts { isSecured: Bool; handshakeKey: Data?; helloKey: Data?; pinning: NotesExchangeFacts.Pinning /* trusted | notEvaluated | mismatch，由 PinningVerdict 對映 */; isLocalDirect: Bool; peerSupportsExchange: Bool; localSupportsExchange: Bool }` 與 `NotesExchangeGate.evaluate(_:) -> NotesExchangeGate.Result`（`allowed` 或 `denied(Reason)`，Reason 涵蓋每個守門條件，供測試與 UI 文案；`handshakeKey == helloKey` 且非空）
  - `public enum NotesExchangeCrypto`：`static func revealDigest(accountId: String, revealerKey: Data, verifierKey: Data, revealerNonce: Data, verifierNonce: Data) -> Data?`（依角色排序、不排序，固定長度欄位）、`static func makeNonce() -> Data`（32 bytes，可注入）、`static func verifyReveal(payload:, handshakeKeys:, nonces:) -> Bool`（用 `Curve25519.Signing.PublicKey(rawRepresentation:)`）、`sign` 以注入的 `(Data) throws -> Data` 簽名器（生產：`IdentityKeyManager.shared.sign`）
  - `public struct NotesExchangeSession`（值型別）：`enum Event { userPressed(nonce: Data, now: Date), userCancelled, receivedIntent(nonce: Data, now: Date), receivedReveal(NotesExchangePayload, now: Date), receivedUnavailable, receivedCancel, localAccountReady(AccountSnapshot?, now: Date), verificationSucceeded, verificationFailed, localRevealFailed, tick(now: Date), disconnected }`；`enum Action { sendIntent(nonce: Data), sendReveal(account: AccountSnapshot, nonces: NotesExchangePair), sendUnavailable, sendCancel, verify(reveal: NotesExchangePayload, nonces: NotesExchangePair), updateState(UIState) }`（實作後更新：以 `NotesExchangeSession.swift` 為準）；`enum UIState { idle, waitingForPeer, peerWantsExchange, exchanging, verifying, bound, peerUnavailable, expired, failed(Reason) }`；`mutating func handle(_ event: Event) -> [Action]`；`static let intentLifetime: TimeInterval = 600`
  - 規則：兩邊 `intent` 都在才產生 `sendReveal`（若我方帳號不可用則改 `sendUnavailable`）；**只在雙方 `intent` 都在時才接受 `reveal`**（否則忽略、不改狀態）；每次連線 `reveal` 最多送一次；重複 `intent` 忽略；`intent` 逾時 600 秒自動 `expired` 並 `sendCancel`；`disconnected` 清空；`cancel` 僅清除對方 intent，不影響已成立的綁定；配對已鎖定但我方尚未回應時，使用者取消或我方 intent 逾時會改送 `unavailable`（撤回，不再送 `reveal`）。

- [ ] **Step 1: 寫失敗測試**
  - Session：`testBothPressSendsReveal`、`testSimultaneousPressNoDuplicateReveal`、`testRevealWithoutMyIntentIgnored`、`testDuplicateIntentIgnored`、`testReplayedRevealAfterDisconnectIgnored`、`testIntentExpiresAfter600s`、`testCancelClearsPeerIntentOnly`、`testLocalAccountUnavailableSendsUnavailable`、`testPeerUnavailableEndsExchange`、`testSecondRevealIgnored`。
  - Gate：每個 `denied` 分支各一測（不在 secured、握手公鑰≠HELLO、HELLO 公鑰缺、pinning 未評估（`notChecked`）、mismatch、非本地直連、對方不支援、我方不支援），以及 `allowed`（`matched`、`firstTrust` 允許）。
  - Crypto：依角色排序的測試：`testOwnRevealReflectedBackDoesNotVerify`（反射回簽署者失敗）、`testRevealVerifiesOnlyOnItsOwnConnection`（第三方連線驗證失敗）、正確角色順序可驗證、`testSignatureVerifies`、`testSignatureFailsOnDifferentAccountId`、`testSignatureFailsOnDifferentNonce`（跨連線重放失敗）、`testSignatureFailsOnDifferentHandshakeKey`、`testWrongSizeFieldsRejected`。
- [ ] **Step 2:** 跑測試確認失敗。
- [ ] **Step 3:** 實作純函式（不碰 CM、網路或時鐘：時間與隨機值皆注入）。
- [ ] **Step 4:** `swift test --filter NotesExchange` 全過。
- [ ] **Step 5:** commit `feat: notes-exchange session state machine, gate and reveal signature`

### Task 4: CM 整合（收發、驗證、綁定、待驗證）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/NotesExchange/ConnectionManager+NotesExchange.swift`
- Modify: `PeerDropCore/ConnectionManager.swift`（掛接 `case .notesExchange`、斷線清理、前景重試）
- Test: `PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerNotesExchangeTests.swift`

**Interfaces:**
- Consumes: C1 origin／旗標、C2 儲存、C3 狀態機。
- Produces（CM 公開）：
  - `@Published public private(set) var notesExchangeStates: [String: NotesExchangeSession.UIState]`（key＝`PeerConnection.id`）
  - `public func pressExchangeNotes(with peerID: String)`（先過 `NotesExchangeGate`；否則回報原因）
  - `public func cancelExchangeNotes(with peerID: String)`
  - `public func unbindNotes(contactID: UUID)`
  - `public func retryPendingBindings() async`（App 回前景與網路恢復時呼叫；驗證 `pendingAccountBinding`）
- 行為：
  1. `case .notesExchange:` 必須 `origin == .envelope && secureChannelState == .secured` 且 gate `allowed`，否則靜默丟棄；以 `try?` 解碼 payload，未知 `phase` 忽略。
  2. 所有送出都用**已驗證的那個 `PeerConnection` 實例**（同一個主 actor turn），且送出前再確認 `.secured`，避免被包成明文。
  3. 收到合法 `reveal`（雙方 intent 都在）：先嘗試 `accountManager.lookup(handle: accountId, includeBundle: false)`；斷言 `AccountID(raw:)` 成功、`entry.accountId.raw == accountId`、`entry.identityKey == handshakeKey`、`entry.signingKey == payload.signingKey`、簽章驗證通過 → `setAccountBinding`。聯絡人以握手公鑰 `find(byPublicKey:)` 取得；找不到則建立（`.unknown`，`deviceId = peerIdentity.id`）；找到但 `deviceId == nil` 則補上。
  4. 目錄查詢因離線／網路錯誤失敗：把 `{accountId, signingKey, handshakeKeyHash}` 存為 `pendingAccountBinding` 並顯示「正在確認」；`retryPendingBindings()` 重試；重試時目錄 `identityKey` 與釘選不符、帳號不存在，或 `entry.accountId` 不同 → 清除 pending 並標示失敗（需重新交換）。我方帳號非 `ready` 時，簽章需求不變（簽名不需要帳號，只需要 `accountId`——**我方帳號不可用時回 `unavailable`**）。
  5. `handlePeerDisconnected`／`removeConnection`：清除該 PC 的 session 與 `notesExchangeStates`。
  6. 前景（`.active`）與 `syncNotes()` 之後呼叫 `retryPendingBindings()`。
  7. 目錄查詢的錯誤不得洩漏到聊天；UI 只看 `UIState`。

- [ ] **Step 1: 寫失敗測試**（一個真實 CM ＋ 腳本化 `PeerConnection` 對端，範本 `test_M3_…`；`AccountManager(mock:)`＋`TestURLProtocol` 假目錄）：`testExchangeBindsAfterBothIntentsAndValidReveal`、`testPlaintextExchangeMessageDropped`、`testRevealWithoutLocalIntentIgnored`、`testHandshakeKeyMismatchWithHelloDenies`、`testRelayConnectionDenied`、`testTailnetConnectionDenied`、`testDirectoryIdentityKeyMismatchDoesNotBind`、`testDirectoryNicknameCollisionDoesNotBind`（entry.accountId 不同）、`testBadSignatureDoesNotBind`、`testOfflineLookupStoresPendingAndRetriesOnForeground`、`testRetryWithChangedKeyClearsPending`、`testBindingCreatesContactWithDeviceIdOnDialer`（主動撥號端沒有聯絡人）、`testBindingFillsMissingDeviceId`、`testDisconnectClearsSession`、`testPeerUnavailableShowsState`、`testNoNotesExchangeSentToPeerWithoutFlag`、`testUnknownPhaseIgnored`。
- [ ] **Step 2:** 跑測試確認失敗。
- [ ] **Step 3:** 實作；簽名器注入（生產用 `IdentityKeyManager.shared.sign`；測試用固定金鑰）。
- [ ] **Step 4:** Kit 全部測試；iOS／Mac 建置。
- [ ] **Step 5:** commit `feat: notes-exchange over the secure local channel with verified account binding`

### Task 5: 朋友綁定解析、寄信模式、紙條查詢

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/FriendBinding.swift`、`PeerDropCore/ThreadTransport.swift`
- Modify: `PeerDropKit/Sources/PeerDropNotes/NotesStore.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/FriendBindingTests.swift`、`ThreadTransportTests.swift`、`PeerDropKit/Tests/PeerDropNotesTests/NotesStoreThreadTests.swift`

**Interfaces:**
- Produces:
  - `FriendBinding`：`@MainActor` 的解析器（持有 CM 的 `trustedContactStore`、`deviceStore`、`connections`）：`contact(forChatPeerID:) -> TrustedContact?`（依序：活連線的握手公鑰 → `find(byPublicKey:)`；`find(byDeviceId: peerID)`；`DeviceRecord(id:)` → `find(byDeviceId: record.id)`；候選多於一個或名稱被合併則回 `nil`）、`boundAccount(forChatPeerID:) -> (accountId: String, verified: Bool)?`（`verified` 表示 `pendingAccountBinding == nil` 且 `accountId != nil`）
  - `ThreadTransport.decide(presence: PeerPresence, binding: BindingState, account: AccountAvailability) -> Decision`：`BindingState { none, pending, verified }`、`AccountAvailability { ready, notReady }`、`Decision { live(showExchangeButton: Bool), note(canSendNow: Bool), locked(reason: LockReason) }`；表格：online → `live`；非 online＋verified＋ready → `note(true)`；非 online＋verified＋notReady → `note(false)`；其餘 → `locked`（`pending` 用 `.verifying`，`none` 用 `.notExchanged`）
  - `NotesStore.notes(forAccount accountId: String) -> [NoteRecord]`（收到：`.verified(accountId:)` 相符；寄出：`recipientAccountId` 相符且 **不含匿名寄出**）；`unreadCount(forAccount:)`；`boundUnreadIDs`
  - `NotesStore.sendToBound(text:accountId:expectedIdentityKey:) async throws -> NoteRecord`：目錄查詢後斷言 `entry.accountId.raw == accountId` 與 `entry.identityKey == expectedIdentityKey`，不符丟 `NotesStoreError.recipientMismatch`（新增 case）；簽名寄出（非匿名）；其餘步驟沿用現有 `send`（抽出共用私有函式，**現有 `send(text:to:anonymous:)` 行為與測試不變**）

- [ ] **Step 1: 寫失敗測試**：`ThreadTransportTests` 全表；`FriendBindingTests`（活連線取握手公鑰、離線以 deviceId、同名合併回 nil、多候選回 nil、pending 不算 verified）；`NotesStoreThreadTests`（歸屬規則、匿名／未驗證／無法解密排除、`sendToBound` 的 mismatch 與暱稱碰撞、未讀只算已驗證歸屬者）。
- [ ] **Step 2:** 跑測試確認失敗。
- [ ] **Step 3:** 實作（重用 `NotesStoreTests` 的 `FakeCrypto`／`RecipientFixture`）。
- [ ] **Step 4:** Kit 全部測試；既有 `NotesStoreTests` 全過。
- [ ] **Step 5:** commit `feat: friend binding resolver, thread transport decision and bound-note queries`

### Task 6: 本機待寄清單與寄送服務

**Files:**
- Create: `PeerDropKit/Sources/PeerDropNotes/NoteOutboxStore.swift`、`PeerDropNotes/NoteOutboxSender.swift`
- Modify: `PeerDropCore/ConnectionManager.swift`（建立、觸發）
- Test: `PeerDropKit/Tests/PeerDropNotesTests/NoteOutboxStoreTests.swift`、`NoteOutboxSenderTests.swift`

**Interfaces:**
- Produces:
  - `NoteOutboxEntry: Codable { id: UUID; contactID: UUID; accountId: String; expectedIdentityKey: Data; text: String; createdAt: Date; attempts: Int; state: queued|failed; failReason: String? }`
  - `NoteOutboxStore`（`@MainActor`，加密 `outbox.enc` 位於 `Documents/<scopedKey("Notes")>/`，注入 `ChatDataEncryptor` 供測試；每次變更整檔加密寫入，範本 `OutboundRetryQueue`）：`enqueue`、`entries(forContact:)`、`markFailed(id:reason:)`、`remove(id:)`、`all`、`@Published entries`
  - `NoteOutboxSender`：`func flush(now: Date) async`——對 `queued` 項逐一嘗試 `notesStore.sendToBound`；成功→移除（紙條已存入 `sent`）；可重試錯誤（`.network`、`.rateLimited`、`.proofOfWorkFailed`、`.opkExhausted`）→ `attempts += 1`，指數退避，**超過 3 次或建立超過 24 小時→`failed`**；終止性錯誤（`.recipientNotFound`、`.recipientHasNoKeys`、`.recipientMismatch`、`.textTooLong`）→`failed`；綁定被清除（聯絡人 `accountId` 已不等於項目的 `accountId`）→`failed("綁定已取消")`，**不自動寄、不刪**；使用者重試 = 重置 `attempts` 並回到 `queued`
  - 觸發：使用者按傳送（立即嘗試一次）、`.active`、網路路徑恢復；**不會**自動寄出尚在輸入框的文字
  - 簽章的 `sentAt` 為實際寄出時刻（沿用 `NoteCrypto.seal(now:)`）

- [ ] **Step 1: 寫失敗測試**：往返與損毀檔案處理、`testRetryableErrorBacksOffAndFailsAfterThree`、`testTerminalErrorFailsImmediately`、`testExpiresAfter24Hours`、`testBindingClearedFailsEntry`、`testSuccessRemovesEntry`、`testManualRetryResetsAttempts`、`testNeverSendsUnqueuedText`、`testDuplicateRiskIsDocumented`（成功但回應遺失視為失敗並重試，接受重複，測試只確認不崩潰且不無限重試）。
- [ ] **Step 2:** 跑測試確認失敗。 **Step 3:** 實作。 **Step 4:** Kit 全部測試。
- [ ] **Step 5:** commit `feat: encrypted local outbox for notes sent from friend threads`

### Task 7: 對話串合併（純邏輯）與對話摘要

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/ThreadItem.swift`
- Modify: `PeerDropCore/ConversationSummary.swift`、`PeerDropCore/ChatManager.swift`（如需）
- Test: `PeerDropKit/Tests/PeerDropCoreTests/ThreadItemTests.swift`、`ConversationSummaryTests.swift`

**Interfaces:**
- Produces:
  - `public enum ThreadItem: Identifiable, Equatable { case chat(ChatMessage), note(NoteRecord), queued(NoteOutboxEntry) }`，`id`（`chat:<id>`／`note:<id>`／`queued:<uuid>`）、`date`（chat＝`timestamp`；收到的紙條＝`receivedAt`；寄出的紙條＝`sentAt`；queued＝`createdAt`）、`isOutgoing`
  - `ThreadMerge.items(chat: [ChatMessage], notes: [NoteRecord], queued: [NoteOutboxEntry], oldestLoadedChatDate: Date?, hasMoreChat: Bool) -> [ThreadItem]`：升冪；`hasMoreChat` 為真時只納入 `date >= oldestLoadedChatDate` 的紙條與待寄；不重複；穩定排序（同時間以 id 決勝）
  - `ThreadMerge.runStartIDs/dayStartIDs`（對 `[ThreadItem]` 的版本，與 `ChatMessageRuns` 規則一致）
  - `ConversationSummary` 新增 `init(id:isGroup:lastMessage:lastNote: NoteRecord?, unread:)`：`lastActivity` 取兩者較新者；`ConversationPreview.text(for: NoteRecord)`（紙條預覽以「📮 」開頭，無法解密回傳空字串）
  - `ConversationsLogic.rows` 以「有 lastMessage 或 lastNote」判斷是否列出（修正「只有紙條的綁定朋友被隱藏」）

- [ ] **Step 1: 寫失敗測試**：排序與決勝、時鐘偏差情境（收到的紙條 `sentAt` 很舊但 `receivedAt` 新）、`hasMoreChat` 夾制、日期分隔與連發分組、摘要取較新者與未讀合計、只有紙條的朋友也列出、匿名／未驗證排除（資料由呼叫端先過濾，這裡驗證輸入正確處理）。
- [ ] **Step 2–4:** 紅→綠→Kit 全部測試。
- [ ] **Step 5:** commit `feat: thread item merge and note-aware conversation summaries`

### Task 8: ChatView 整合（對話串、輸入框模式、交換按鈕）

**Files:**
- Create: `PeerDrop/UI/Chat/NoteBubbleView.swift`、`PeerDrop/UI/Chat/ExchangeNotesButton.swift`、`PeerDrop/UI/Chat/ThreadModel.swift`（`@MainActor ObservableObject`，持有合併後的 `[ThreadItem]`，依 `chatManager`／`notesStore`／outbox／`trustedContactStore` 變更於 main 上節流重建，**不在 `body` 內逐列計算**）
- Modify: `PeerDrop/UI/Chat/ChatView.swift`、`ChatBubbleView.swift`（僅必要）、`PeerDropMac/Views/MacChatWindow.swift`（如需注入環境物件）、`PeerDrop/App/Localizable.xcstrings`
- Test: `PeerDropTests/ThreadModelTests.swift`、`PeerDropTests/ExchangeNotesButtonStateTests.swift`

**Interfaces:**
- Consumes: C5 `FriendBinding`／`ThreadTransport`、C6 outbox、C7 `ThreadMerge`、C4 `notesExchangeStates`。
- 行為（對照設計 §4.3–§4.5、§10.11）：
  1. 訊息清單改用 `ThreadModel.items`；聊天氣泡沿用 `ChatBubbleView`，紙條用新的 `NoteBubbleView`（`noteFill`／`noteBorder`／`noteText`，狀態文字「📮 已寄出」，待寄「待寄出」，失敗「未寄出，點此重試」）。紙條氣泡**沒有**反應、編輯、回覆、滑動回覆、已讀勾勾；長按選單：複製、刪除這張紙條（`NotesStore.delete`）、封鎖、檢舉（沿用既有 API，以紙條 ID）。
  2. 搜尋維持只搜聊天；「載入更早」同時擴大紙條納入範圍。
  3. 輸入框由 `ThreadTransport.decide` 決定：`live`＝現狀；`note(canSendNow)`＝開啟、提示字「寫一張紙條給 X…」、傳送鈕為紙條樣式、2,000 字元計數（接近上限才顯示）、`canSendNow == false` 時提示「有網路時才能寄出」並進入待寄；`locked`＝灰色橫條與誠實文案（`.notExchanged`：「雙方交換紙條後才能離線聯絡」；`.verifying`：「正在確認對方的紙條帳號」）。移除寫死的 `.disabled(!isPeerConnected)`。
  4. 連線中途斷線：**不自動改寄**；文字保留，畫面切為紙感並提示「已改為紙條」；切換成紙條模式時 `replyingToMessage = nil`。
  5. `ExchangeNotesButton`（工具列右上；iOS 與 Mac 聊天視窗）：狀態圖示＋VoiceOver 文字——可按（未綁定、對方支援）、對方過舊（停用，「對方的 App 需要更新才能交換紙條」）、等待對方（已按下）、對方想交換（可同意）、確認中、已綁定（郵戳徽章，點擊可取消綁定）、對方尚未開通（結果訊息）。按下前跳確認：「若 X 也同意，將分享你的紙條帳號」。純函式 `ExchangeButtonPresentation.state(from:)` 可測。
  6. `onAppear`：對該帳號的收到紙條呼叫 `markRead`（已讀同步伺服器，與現行一致）。
- 在地化：本任務新增字串全部五語系（文字插入，非繁中 `needs_review`），先檢查既有 key 可否重用。

- [ ] **Step 1: 寫失敗測試**：`ThreadModelTests`（合併重建只在來源變動時發生；模式切換清除 reply；待寄與失敗項目呈現）、`ExchangeNotesButtonStateTests`（每個 `UIState` ＋ 對方旗標 → 呈現狀態／可按性／標籤）。
- [ ] **Step 2:** 紅。 **Step 3:** 實作。
- [ ] **Step 4:** iOS 全部單元測試；iOS 與 Mac 建置；模擬器（SCREENSHOT_MODE 暫時 harness，不提交）截圖：live、紙條可寄、鎖定、等待對方、已綁定、含紙條氣泡的對話串，淺色與夜間，最大字級；如無法目視請明說。
- [ ] **Step 5:** commit `feat: merged notes thread, transport-aware composer and exchange button in chat`

### Task 9: 對話清單、紙條信箱、徽章、推播路由

**Files:**
- Modify: `PeerDrop/UI/Conversations/ConversationsTab.swift`、`ConversationsLogic.swift`、`ConversationsTabContent.swift`、`PeerDrop/UI/Notes/NotesInboxView.swift`、`PeerDrop/UI/ContentView.swift`、`PeerDropMac/Views/MacContentView.swift`、`MacDetailRouter.swift`
- Test: `PeerDropTests/ConversationsLogicTests.swift`（擴充）、`PeerDropTests/InboxDeepLinkTests.swift`（擴充）、`PeerDropTests/NotesInboxFilterTests.swift`

**行為：**
1. `ConversationsTab` 需取得 `NotesStore` 與 `FriendBinding`；`refreshSummaries()` 將綁定帳號的最後一則紙條與未讀折入摘要；`RefreshHub` 加入 `notesStore.objectWillChange` 與 `trustedContactStore.objectWillChange`（保持節流與「畫面不在時不刷新」）。
2. `NotesInboxView`：過濾掉「已驗證綁定且歸入對話串」的紙條；紙條信箱列與分頁徽章的未讀 = `store.unreadCount − 已歸入對話串的未讀`；同一張紙條的未讀只計一次。
3. `.openNote` 路由：寄件人為已驗證綁定 → 開啟該朋友的對話串（iOS 切到紙條分頁並推入 `ChatTarget`；Mac 開聊天視窗），否則維持現有開信箱／指定紙條（沿用 `InboxDeepLink` 純函式並擴充分支，單元測試）。
4. 取消綁定（朋友列或聊天按鈕）後：既有紙條回到信箱，對話串不再合併。

- [ ] **Step 1: 寫失敗測試**：只有紙條的綁定朋友會列出；信箱過濾（匿名／未驗證／未綁定留在信箱，已綁定移出）；未讀不重複；深連結分支（已綁定→對話串、未綁定→信箱、信箱已開著、聊天已開著）。
- [ ] **Step 2–4:** 紅→綠→iOS 全部單元測試；iOS 與 Mac 建置。
- [ ] **Step 5:** commit `feat: fold bound notes into conversations list, inbox filter and push routing`

### Task 10: 相容與端對端驗證、在地化稽核、PR 說明

**Files:** 腳本與文件；除補缺的字串外不新增功能。

- [ ] **Step 1: 跨版本迴路測試（獨立程序）**：建立 App Store 現行版（以 `main` 的上一個發佈 tag／commit）與本分支的 `peerdrop-cli` 兩個二進位，依專案既有做法（`feedback-sandbox-interop-testing`）本機互連：①新↔舊：舊版連線**不被斷開**、新版不送 `notesExchange`；②新↔新（兩個程序、各自 `--name`）：雙方按下→綁定→斷線後寄紙條→對方收到並出現在對話串。若 CLI 沒有對應操作，寫最小的測試驅動並說明；**做不到的項目請明確標記留給使用者實機驗證**。
- [ ] **Step 2: 在地化稽核**（唯讀 Python `-I`）：相對 Base 新增／變更的 key 皆具五語系、非繁中 `needs_review`、格式符號一致；補缺（只文字插入）；列出硬編碼英文。
- [ ] **Step 3:** 跑全部：Kit、iOS 單元、iOS／Mac 建置；確認 pbxproj 無雜訊。
- [ ] **Step 4:** 檢查 fastlane／截圖腳本是否引用到新舊 UI（只回報）。
- [ ] **Step 5:** 草擬 PR 說明（繁體中文）至 scratchpad `pr-notes-project-c.md`：Rulings、設計 §10 決定、已知缺口、需實機驗證項目（真實藍牙／Wi-Fi 交換、斷線後寄紙條並在另一台收到、舊版相容）、延後項目。不 push。
