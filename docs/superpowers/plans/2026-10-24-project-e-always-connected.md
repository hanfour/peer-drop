# 專案 E：一直連線（碰面代號、跨網路即時聊天）與陌生人匣 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓使用者對少數已綁定的朋友逐人開啟「一直連線」：雙方 App 都開著時，經由只有兩人算得出的碰面代號建立跨網路加密連線並顯示綠點；降級時對方無從察覺；另提供本機的陌生人匣與全域紙條通知開關。

**Architecture:** 客戶端由雙方長期身分金鑰的靜態 DH 衍生每日碰面代號與信令加密金鑰；Cloudflare Worker 新增匿名路由 `/rv`（新 Durable Object `RendezvousRoom`，代號放第一個訊框、無 KV 寫入、不記日誌）只做盲轉送。連線管理放在新的 `RendezvousManager`（不擴大 4,900 行的 `ConnectionManager`），以預先帶入身分的 `PeerConnection` 加嚴格安全通道策略（不退回明文、握手公鑰須等於釘選公鑰）接入現有訊息協定與專案 C 的對話串。

**Tech Stack:** Swift 5.9／SwiftUI、PeerDropKit（SwiftPM）、WebRTC（現有 `DataChannelClient`）、Cloudflare Workers + Durable Objects（TypeScript、vitest）、XcodeGen、XCTest。

**Spec:** `docs/superpowers/specs/2026-10-24-project-e-always-connected-design.md`（§6.1 威脅模型與 §12 決定為準）。程式碼對照表：`/private/tmp/claude-501/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/2be360a0-ac37-4ca5-ad88-48c331fbf475/scratchpad/code-map-project-e.md`（行號可能位移，動手前重新 grep）。

**Base（重要）：** 實作分支 `feat/project-e` 從 `origin/main`（至少含專案 C，`ca49cb4`）切出，worktree `.worktrees/peer-drop-e-impl`。本機的 `main` 是舊的，**不得**從本機 `main` 切。

## Global Constraints

- 繁體中文台灣用語；commit 格式 `type: short description`，結尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`；不得 `git commit -a`；不得提交 `.gitignore` 的未提交修改與 `docs/pet-design/`；**不得 push**（由使用者決定）。
- **Worker 變更合併即自動部署**（`.github/workflows/worker-deploy.yml`）：所有伺服器變更必須**惰性**（沒有客戶端使用時零影響）、可向前相容；任何 D1 migration 必須可重複套用且不破壞既有資料。
- **隱私條款（硬性）**：新路由 `/rv` 不寫任何含代號、IP、裝置 ID 的日誌（不得寫入 `wslog`、KV、`console.log`、回報）；代號只出現在第一個 WebSocket 訊框（不在網址）；不使用 Bearer／裝置 ID；新路由**不做 KV 寫入**。客戶端日誌與錯誤回報不得帶代號、房間或朋友關係。
- **安全條款（硬性）**：跨網路連線**絕不退回明文**——5 秒內未建立安全通道就斷線；只有當 `secureChannelState == .secured` 且**握手公鑰**（`handshakePeerIdentityKey`，不是 HELLO 宣稱的公鑰）等於 `TrustedContact` 釘選公鑰、且該聯絡人有 `verifiedAccount` 綁定時，才視為已連線／綠點。
- 自動連線**不得**改變前景 UI 狀態：不呼叫 `focusedPeerID` 設定／`focusIfUnfocused`、不觸發全域 `state` 轉換、不跳出 TOFU／SAS／金鑰變更對話框（遇到需要使用者決定的情況就**不連線**並記錄原因）。
- **悄悄降級**：關閉開關＝不再加入該代號房間、不再為他進行信令、不發送任何通知；不得新增任何「對方是否已開啟」的訊號。
- 一直連線上限 **5 位**；跨網路連線單獨計數，不佔用既有 `maxConnections`。
- 不改既有儲存格式；新增僅限：`TrustedContact` 的一個可選欄位（`decodeIfPresent`）、新路由／DO 類別、每帳號一個布林值（紙條通知）、新連線管理類別。
- 五語系（en、zh-Hant、zh-Hans、ja、ko）；`Localizable.xcstrings` **只用文字插入、不可 JSON 整檔重寫**；非繁中 `needs_review`；新增 Swift 檔後 `xcodegen generate`，並還原 pbxproj 雜訊（根 group 名稱 `peer-drop` id `9EC0E908E1A38EE0458CEC1B`、Secrets.xcconfig ref `71060D2244B026D50B454D62`）；diff 只應新增。
- 建置／測試（外接碟會斷線，derivedDataPath 用 scratchpad `$S`＝`/private/tmp/claude-501/-Volumes-SATECHI-DISK-Media-UserFolders-Projects-applications-peer-drop/2be360a0-ac37-4ca5-ad88-48c331fbf475/scratchpad`）：Kit `cd PeerDropKit && swift test --filter <Class>`（預期唯一既有失敗 `IdentityKeyManagerTests.testKeyPersistsAcrossInstances`）；iOS `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -derivedDataPath "$S/dd-sim-e" -only-testing:PeerDropTests/<Class>`；Mac `xcodebuild build -scheme PeerDropMac -derivedDataPath "$S/dd-mac-e" CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -allowProvisioningUpdates`（Apple Development 簽名）；Worker `cd cloudflare-worker && npm test`（`scripts/run-tests.sh`；若 `/tmp` shadow node_modules 損壞：`rm -rf /tmp/peerdrop-cf-*/node_modules` 後重跑）。
- 同一程序內兩個真實 `ConnectionManager` 無法達到 `.secured`（共用 `IdentityKeyManager.shared`）：整合測試用「一個真實物件＋腳本化對端」；真正的雙端與跨版本在**獨立程序**驗證。

## Rulings（計畫層級決定）

1. 連線鍵＝`TrustedContact.deviceId`（對方 `PeerIdentity.id`），預先帶入身分；與直連同鍵，天然去重，偏好直連。
2. 新建 `RendezvousManager`（PeerDropCore），**不**把狀態機塞進 `ConnectionManager`；`ConnectionManager` 只提供最小接縫（安裝連線、查綁定、查直連）。
3. 在線新增一態 `.connecting`（`PeerPresence`），所有 switch 與徽章、無障礙文字同步。
4. 陌生人匣第一版：本機分類＋全域「紙條通知」伺服器布林值；匿名紙條本機處理；不做逐陌生人抑制推播。
5. 不遷移舊的 `relay-` 聊天檔，只讓新訊息用穩定鍵。
6. 代號以 UTC 日為 epoch，日界前後 10 分鐘同時加入相鄰兩天的代號。
7. 加入房間前的隨機延遲 0–30 秒。
8. 工作量證明難度沿用既有 16 bits，綁定代號＋當前小時；已承認其防濫用能力有限，另以每日額度與用量告警補足（文件說明）。

## Review Focus

1. **降級不可區分**：關閉開關的任何路徑都不得產生對方可見的差異（連線拒絕訊息、關閉原因碼、時間特徵）；`unavailable`／拒絕的回應不得洩漏「對方沒開」與「對方降級」的差別（E3、E4、E5）。
2. **綁錯人／冒名**：代號只有擁有同一 DH 的兩人能算；房間內任何人（含營運者）轉送的信令都須通過 AEAD；握手公鑰≠釘選公鑰一律斷線；重放舊 offer 只會失敗（E3、E4）。
3. **隱私條款**：Worker 與客戶端沒有任何路徑記錄代號、IP 或朋友關係；`/rv` 不寫 KV（E2）。
4. **不干擾前景**：背景自動連線不改全域狀態、焦點、對話框；與直連並存時不互相覆蓋（E4）。
5. **在線與可傳訊一致**：綠點＝已通過驗證的連線；房間內等待／協商中不是綠點；`ThreadTransport` 選 live 時 `sendTextMessage` 一定有連線可送（E4、E5）。

---

### Task 0: 工作區

- [ ] 在 repo 根 `git fetch origin && git worktree add .worktrees/peer-drop-e-impl -b feat/project-e origin/main`；複製被忽略的 `Secrets.xcconfig`（不提交）；把設計與計畫文件帶進來：`git checkout docs/project-e-always-connected -- docs/superpowers/specs/2026-10-24-project-e-always-connected-design.md docs/superpowers/plans/2026-10-24-project-e-always-connected.md` 並提交 `docs: add project E spec and plan`。
- [ ] 跑 Kit `swift test`、Worker `npm test`、iOS 全部測試記錄基準。無程式碼變更不需 commit。

### Task 1: 修復既有中繼聊天錯誤（E1）

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（`isPeerTrustedForUserActions`、`sendTextMessage`／媒體送出、`saveIncoming` 站點、`deviceIdExchange` 處理）
- Test: `PeerDropKit/Tests/PeerDropCoreTests/RelayChatFixesTests.swift`

**Interfaces:**
- Produces:
  - `ConnectionManager.isPeerTrustedForUserActions(peerID:)` 改為先用別名查詢（`connection(for:)`），與送出路徑一致。
  - 新增純函式 `ChatStorageKey.key(forConnection pc: PeerConnection) -> String`：`pc.isRelayTransport || pc.id.hasPrefix("relay-")` 時回傳 `pc.peerIdentity.id`（HELLO 換身分後；尚未換則維持原鍵），否則 `pc.id`。收到的文字／媒體／回條訊息一律以此鍵儲存，使收發落在同一檔案。**不遷移舊 `relay-` 檔**。
  - `deviceIdExchange`：在 `relay-<碼>` 紀錄尚不存在時**暫存**對方 deviceId，待 PIN 確認建立紀錄後套用（不再靜默丟失）。

- [ ] **Step 1: 寫失敗測試**：`testTrustGateResolvesRelayAlias`（以 `peerIdentity.id` 查詢中繼連線通過）、`testSendToRelayPeerOpenedByIdentityIDIsNotMarkedFailed`、`testIncomingAndOutgoingShareOneChatFileForRelayPeer`、`testStorageKeyBeforeHelloSwapFallsBackToConnectionID`、`testDeviceIdExchangeBeforePinConfirmationIsApplied`、`testNonRelayStorageKeyUnchanged`。
- [ ] **Step 2:** 跑測試確認失敗。 **Step 3:** 實作。 **Step 4:** Kit 全部測試；iOS 與 Mac 建置。
- [ ] **Step 5:** commit `fix: relay chat trust gate alias, shared chat storage key, deviceIdExchange ordering`

### Task 2: Worker——碰面房間 `/rv`（E2）

**Files:**
- Create: `cloudflare-worker/src/rendezvousRoom.ts`、`cloudflare-worker/src/rendezvousRoute.ts`
- Modify: `cloudflare-worker/src/index.ts`（路由註冊、DO 匯出）、`cloudflare-worker/wrangler.toml`（binding `RENDEZVOUS_ROOM`、migration `v6`: `new_sqlite_classes = ["RendezvousRoom"]`）、`cloudflare-worker/worker-configuration.d.ts`
- Test: `cloudflare-worker/test/rendezvous.test.ts`（沿用現有 vitest 與 miniflare 設定）

**Interfaces:**
- Produces:
  - `GET /rv`（WebSocket 升級，**路徑不含代號**）：不經 Bearer／API key（不在 `requiresAuth`），也不寫 `wslog`。連線後 **第一個文字訊框** 必須是 JSON `{"v":1,"t":"<base64url 32 bytes 代號>","pow":{"h":"<hour>","n":"<nonce>"}}`；否則在 5 秒內關閉（關閉碼與原因對所有失敗情況**一律相同**，不洩漏差異）。
  - 驗證：代號長度／編碼正確；PoW 以 `SHA256(token ‖ hour ‖ nonce)` 前導零位元 ≥ 16，`hour` 須為當前或前一小時（UTC）；通過後以 `RENDEZVOUS_ROOM.idFromName(token)` 轉入 DO。
  - 速率限制：以 (IP 雜湊, 代號雜湊) 為鍵、每分鐘 12 次連線，**計數存在 DO 記憶體或 Workers 記憶體，不寫 KV**；超過時用與一般失敗相同的關閉。**絕不與 `/room` 共用桶**。
  - `RendezvousRoom` DO：2 人上限；使用休眠 API 與 `setWebSocketAutoResponse("ping","pong")`；盲轉送訊框（不解析、不儲存）；收到第二人加入時對雙方送 `{"t":"joined"}`；任一方離開對另一方送 `{"t":"left"}`；**不會因房間滿而踢掉較舊的 socket**——第三人加入直接被拒（相同關閉）；伺服器端閒置 2 小時無訊框即關閉；同一 clientId 重連由客戶端自行處理（DO 不辨識身分）。
  - `POST /rv/ice`：body `{"t":"<代號>","pow":{...}}` → 回傳 TURN／STUN 設定（沿用 `/room/:code/ice` 的 Cloudflare TURN 憑證取得，但**不要求登入、不回傳任何房間 token、不記錄代號**）；同一套 PoW 與速率限制；TURN 憑證有效期沿用 900 秒。
  - 所有新程式碼**不使用** `console.log` 輸出代號／IP；回應標頭不含可關聯資訊。

- [ ] **Step 1: 寫失敗測試**（vitest）：合法代號＋PoW 可配對兩個 socket 並盲轉送；PoW 不足／過期小時／代號格式錯誤→相同關閉；第三人被拒且不影響前兩人；一方離開另一方收到 `left`；閒置關閉（以可注入時鐘）；`/rv/ice` 回傳不含房間 token 且無需 Authorization；**日誌測試**：spy `console.*`、`wslog`、KV 寫入，斷言新路由完全不呼叫；速率限制超過時回應與其他失敗相同。
- [ ] **Step 2:** `npm test` 確認失敗。 **Step 3:** 實作。 **Step 4:** `npm test` 全過（含既有 Worker 測試，不得退步）。
- [ ] **Step 5:** commit `feat(worker): anonymous rendezvous room and ICE route (inert until clients use it)`

### Task 3: 碰面代號、信令加密與簽章綁定（E3，純函式）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/Rendezvous/RendezvousToken.swift`、`RendezvousSignalingCrypto.swift`、`RendezvousProofOfWork.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/RendezvousTokenTests.swift`、`RendezvousSignalingCryptoTests.swift`、`RendezvousProofOfWorkTests.swift`

**Interfaces:**
- Produces:
  - `RendezvousToken.token(sharedSecret: SymmetricKey-or-Data, myKey: Data, peerKey: Data, day: Int) -> Data`（32 bytes）：`HKDF<SHA256>(secret, salt: "peerdrop-rv-v1", info: min(keyA,keyB) ‖ max(keyA,keyB) ‖ dayBE8)`；兩端輸入順序互換結果相同；`day` ＝ `floor(unixSeconds / 86400)`。`RendezvousToken.tokensToJoin(now:…) -> [(day: Int, token: Data)]`：平常 1 個；UTC 日界前後 10 分鐘為 2 個（前一天／後一天）。時鐘與 DH 皆可注入。
  - `RendezvousToken.encoded(_:) -> String`（base64url 無填充）。
  - `RendezvousSignalingCrypto`：`signalingKey(sharedSecret:…, day:)`（獨立 info `"peerdrop-rv-signal-v1"`，與代號、與 `PeerDrop-LocalE2E-v1` 皆不同）；`seal(plaintext, key, direction, counter, sessionID) -> Data`／`open(…)`：ChaCha20-Poly1305，nonce ＝ 4 bytes 方向前綴＋8 bytes 單調遞增計數器，AAD ＝ `"rv-sig-v1" ‖ day ‖ sessionID(16) ‖ direction`；`sessionID` 由雙方在**第一則訊框**各貢獻 8 random bytes 組成（較小公鑰者在前）；接收端拒絕計數器非遞增（重放）與 day／session 不符。
  - `RendezvousProofOfWork.solve(token:hour:difficulty:) -> nonce`／`verify`（與 Worker 的規則一致：`SHA256(token ‖ hourBE8 ‖ nonce)`）；提供與 Worker 共用的**測試向量**。

- [ ] **Step 1: 寫失敗測試**：兩端算出相同代號（互換順序）、不同日不同代號、金鑰變更後不同、與 `LocalSecureChannel` root 衍生輸出不相等（domain separation）、日界雙代號邏輯（邊界 ±10 分鐘，剛好 10 分鐘的邊界值）、signaling seal/open 往返、竄改任何位元組失敗、重放（相同計數器）失敗、跨 day／session 失敗、反向（自己的訊息回彈）失敗、PoW 向量與 Worker 一致（把向量寫成 JSON 檔供兩邊測試共用）。
- [ ] **Step 2–4:** 紅→綠→Kit 全部測試。 **Step 5:** commit `feat: rendezvous token derivation, signaling AEAD and PoW primitives`

### Task 4: `RendezvousManager`（連線狀態機與傳輸，E4a）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/Rendezvous/RendezvousManager.swift`、`RendezvousSession.swift`、`RendezvousSignalingClient.swift`
- Modify: `PeerDropKit/Sources/PeerDropCore/TrustedContact` 相關（`PeerDropSecurity/TrustedContact.swift` 加 `rendezvousEnabled: Bool?`，`decodeIfPresent`；`TrustedContactStore.setRendezvousEnabled(for:_:)`）
- Test: `PeerDropKit/Tests/PeerDropCoreTests/RendezvousSessionTests.swift`、`RendezvousManagerTests.swift`、`PeerDropKit/Tests/PeerDropSecurityTests/TrustedContactRendezvousTests.swift`

**Interfaces:**
- Produces:
  - `TrustedContact.rendezvousEnabled`（預設 nil＝關）；`setRendezvousEnabled` **只允許** `accountId != nil && pendingAccountBinding == nil` 的聯絡人，且啟用數不得超過 5（超過回傳錯誤，不靜默忽略）；金鑰變更（`updatePublicKey`）時**自動關閉並清除**。
  - `RendezvousSession`（純狀態機，值型別）：狀態 `idle / waiting / negotiating / connected / failed(reason) / closed`；事件 `appForeground(now) / appBackground / enabled / disabled / peerJoined / peerLeft / signal(Data) / dataChannelOpen / secureChannelResult(ok: Bool) / tick(now)`；動作 `joinRoom(token) / leaveRoom / sendSignal / startNegotiation(role) / installConnection / closeConnection / scheduleRetry`。**角色決定**：公鑰字典序較小者為 offer 端。**降級**：`disabled` 立刻 `leaveRoom` 且不送任何額外訊框（尤其不得送「拒絕」類訊息）。**逾時**：協商 30 秒、安全通道 5 秒、不退回明文；重連使用指數退避（上限 5 分鐘）與隨機延遲 0–30 秒（可注入）。
  - `RendezvousSignalingClient`：封裝 `/rv` WebSocket（第一訊框含代號與 PoW）、TURN 取得（`POST /rv/ice`）、所有訊框經 `RendezvousSignalingCrypto`；錯誤一律歸為單一內部 `unreachable`，不向 UI 區分原因。
  - `RendezvousManager`（@MainActor）：持有每位啟用聯絡人的 `RendezvousSession`；前景時為每位（≤5）建立 session，背景時關閉；日界雙代號；以注入的 `DirectConnectionChecker` 避免與直連並存（已有直連→不建立；直連之後成立→關閉跨網路）；以 `DataChannelClient`／`DataChannelTransport` 建立 WebRTC（`iceTransportPolicy = .all`）；連線成立時呼叫 `installer.install(transport:, contact:)`（由 Task 5 的 ConnectionManager 接縫實作）。
- 測試重點（注入假傳輸）：降級後無額外訊框；第三人加入不影響；日界雙代號；背景關閉；逾時；重放舊 offer 失敗；直連去重；啟用上限 5；未綁定聯絡人拒絕啟用；金鑰變更自動關閉。

- [ ] **Step 1: 寫失敗測試**（上列重點，狀態機以表格測試全覆蓋）。 **Step 2:** 紅。 **Step 3:** 實作。 **Step 4:** Kit 全部測試；iOS／Mac 建置。
- [ ] **Step 5:** commit `feat: rendezvous session state machine, signaling client and manager`

### Task 5: ConnectionManager 接縫、嚴格安全策略、在線整合（E4b）

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`、`PeerConnection.swift`（嚴格策略旗標）、`PeerPresence.swift`（`.connecting`）、`ThreadTransport.swift`（如需）、`PeerDropCore/FriendBinding.swift`（如需）；`PeerDrop/UI`（只改 `PeerPresence` 的 switch 與徽章／無障礙文字，其餘 UI 在 Task 6）
- Test: `PeerDropKit/Tests/PeerDropCoreTests/ConnectionManagerRendezvousTests.swift`、`PeerPresence` 既有測試擴充、`PeerDropTests/PeerAvatarTests`、`ThreadTransportTests`

**Interfaces:**
- Produces:
  - `ConnectionManager.installRendezvousConnection(transport:, contact: TrustedContact) -> PeerConnection?`：以 `contact.deviceId` 為鍵、預先帶入 `PeerIdentity`（`id` ＝ deviceId、`displayName` ＝ 聯絡人名稱、`identityPublicKey` ＝ 釘選公鑰）；`isRelayTransport = true`（讓專案 C 交換閘門自然拒絕）；**不**設 `isRelayPlaceholder`、**不**走 PIN／`RelayAuthenticator`、**不**呼叫 `forceTransitionToRequesting`、**不**設 `focusedPeerID`／`focusIfUnfocused`、**不**使用 `activeRelaySession`／`connectionGeneration`；跨網路連線不計入 `maxConnections`（新增獨立計數與上限 5）。
  - `PeerConnection` 嚴格策略 `requiresStrictSecureChannel`：安全通道握手 5 秒內未成功→直接斷線（不進 `.fallbackPlaintext`）；`secureChannelState == .secured` 且 `handshakePeerIdentityKey == contact.identityPublicKey`（釘選）且 `FriendBinding.verifiedAccount != nil` 才標記為 `verified`；HELLO 宣稱的公鑰與握手公鑰不同→斷線；`pinningVerdict` 為 `.mismatch` 或 TOFU/SAS 需使用者決定→**斷線並記錄原因，不彈對話框**。
  - `PeerPresence` 新增 `.connecting`：房間內等待對方、協商中；`PresenceSources` 新增 `connectingCrossNetwork`（或沿用 `connecting`）；`.online` 只在 `verified` 連線存在時；所有 switch、`PresenceBadge`（形狀＋VoiceOver 文字，不靠顏色）與 `ThreadTransport.decide`（`.connecting` 視為非 live：note 或 locked）同步更新；`sendTextMessage` 在 `.online` 時一定存在連線。
  - 直連與跨網路並存：以同鍵 `isPeerIDInUse` 前置檢查；`RendezvousManager` 的 `DirectConnectionChecker` 由 CM 提供。
  - 背景：`handleScenePhaseChange` 呼叫 `rendezvousManager.appBackground()`／`appForeground()`；`handleBackgroundExpiration` 既有行為維持；不新增背景模式。
  - 對話串鍵：收到／送出一律用 Task 1 的 `ChatStorageKey`（跨網路連線的 `pc.id` ＝ deviceId，已與送出鍵一致）。
  - Mac：同一套程式碼；Mac 不被暫停時可長時間維持（仍遵守 5 位上限）。

- [ ] **Step 1: 寫失敗測試**（一個真實 CM＋腳本化 `PeerConnection` 對端，範本 `ConnectionManagerSenderBindingTests` 的 `test_M3_…`）：安裝後不改 `focusedPeerID`／全域 `state`；握手公鑰≠釘選公鑰→斷線；HELLO 公鑰≠握手公鑰→斷線；5 秒未建立安全通道→斷線且從未進入明文；`.connecting` 不是 online 且 `ThreadTransport` 不選 live；`verified` 連線→online＋`sendTextMessage` 成功；已有直連→不安裝；直連後來成立→關閉跨網路；未綁定聯絡人→拒絕；專案 C 交換閘門拒絕此類連線；跨網路連線不影響 `maxConnections` 計數；背景→連線關閉。
- [ ] **Step 2–4:** 紅→綠→Kit 全部、iOS 全部單元、iOS／Mac 建置。 **Step 5:** commit `feat: rendezvous connections with strict secure-channel policy and connecting presence`

### Task 6: UI——逐人開關、綠點、說明（E5）

**Files:**
- Create: `PeerDrop/UI/Home/AlwaysConnectedToggle.swift`
- Modify: `PeerDrop/UI/Home/HomeTab.swift`／`FriendRow.swift`（朋友列的開關入口）、聊天標題旁資訊（可選）、`SettingsView`（說明文字）、`PeerDrop/App/Localizable.xcstrings`
- Test: `PeerDropTests/AlwaysConnectedToggleStateTests.swift`

**Interfaces:**
- Produces（純函式＋視圖）：
  - `AlwaysConnectedPresentation.state(contact:, enabledCount:, rendezvousState:) -> State`：`unavailableNotBound`（未綁定帳號：說明＋引導到交換紙條）、`off`、`on(waiting)`、`on(connecting)`、`on(online)`、`limitReached`（已達 5 位）。**不得**出現「對方已開啟／已降級」之類字樣或狀態；文案：「對方也開啟並在線時才會顯示綠點」。
  - 開關操作：開啟→`setRendezvousEnabled`；關閉→立即 `disabled`，**不跳出任何會暗示對方的確認文字**（可有自己的確認：「關閉後你在他那邊會顯示離線」）。
  - 朋友列：綠點／連線中徽章沿用 Task 5 的 `.online`／`.connecting`；VoiceOver 文字完整。
  - 說明頁（設定內）：三層模型簡述、5 位上限、降級不通知對方、App 沒開時退成紙條、營運者能看到什麼（誠實一句話）。
- 在地化五語系（文字插入）。

- [ ] **Step 1: 寫失敗測試**：`AlwaysConnectedPresentation` 每種輸入；上限；未綁定；文案中不含禁止字樣（掃描本地化字串）。 **Step 2–4:** 紅→綠→iOS 全部單元測試；iOS／Mac 建置；模擬器暫時 harness 截圖（淺色／夜間／最大字級）並明說未目視確認的部分。 **Step 5:** commit `feat: per-friend always-connected toggle, explainer and presence UI`

### Task 7: 陌生人匣與全域紙條通知（E6）

**Files:**
- Create: `PeerDrop/UI/Notes/StrangerBox.swift`（或併入 `NotesInboxView`）、`PeerDropKit/Sources/PeerDropNotes/NoteClassification.swift`；Worker：`cloudflare-worker/src/accountSettings.ts`、`cloudflare-worker/migrations/0004_account_settings.sql`（欄位或新表，**可重複套用**）
- Modify: `cloudflare-worker/src/notes.ts`（`fanOutNotePush` 前檢查收件人設定）、`cloudflare-worker/src/index.ts`（路由）、`PeerDropKit/Sources/PeerDropAccount/AccountClient.swift`（設定 API）、`SettingsView`
- Test: `PeerDropKit/Tests/PeerDropNotesTests/NoteClassificationTests.swift`、`cloudflare-worker/test/accountSettings.test.ts`、`PeerDropTests/StrangerBoxTests.swift`

**Interfaces:**
- Produces：
  - `NoteClassification.classify(note: NoteRecord, circle: CircleMembership) -> .circle | .stranger | .hiddenAnonymous`（純函式）：圈內＝已驗證綁定的朋友（`verifiedAccount`）＋同一本日記成員（`diaryStore` 成員的 accountId）＋自己寄過署名紙條的對象；匿名、未驗證、未綁定→陌生人匣；使用者開啟「不接收匿名紙條」→匿名紙條歸 `.hiddenAnonymous`（本機隱藏分區，不上傳任何旗標）。
  - 紙條分頁／信箱：新增「陌生人」分區與未讀提示，**不**影響專案 C 的已綁定朋友去重與徽章計算（陌生人未讀計入分頁徽章；不計入朋友列）。
  - Worker：`GET/PUT /v3/account/settings`（需帳號登入）→ `{"notePush": Bool}`，預設 true；`fanOutNotePush` 在 false 時**完全不推播**（不發視覺推播，也不改發靜默推播）；migration 可重複套用；不記錄設定變更歷史。
  - 設定頁：「紙條通知」開關（全域，說明：關閉後所有紙條不會推播，仍可在 App 內查看）；「不接收匿名紙條（僅在本機隱藏）」開關。
- 決策已定：不做逐陌生人抑制推播（需 Apple 通知過濾權限，列為後續）。

- [ ] **Step 1: 寫失敗測試**：分類純函式全表；Worker 設定 API 與推播抑制（有／無設定）；migration 重複套用；客戶端在 API 失敗時不更動本機狀態；信箱去重與徽章（陌生人未讀、朋友未讀、總數）。 **Step 2–4:** 紅→綠→Kit／Worker／iOS 單元測試；建置。 **Step 5:** commit `feat: stranger box, local anonymous-note handling and global note push setting`

### Task 8: 整合驗證、相容性、PR 說明（E7）

**Files:** 腳本與文件；除補缺的字串外不新增功能。

- [ ] **Step 1: Worker 本機整合**：以 `wrangler dev`（或 vitest 的 miniflare 整合）啟動 Worker，用兩個獨立程序的測試驅動（非無頭 CM 無法在同一程序，因此用 `interop-harness` 模式：兩個程序、各自 fake HOME 與 `--name`，參考專案 C Task 10 的做法與 `PeerDropKit/Sources/interop-harness`）驗證：雙方啟用→進同一代號房間→信令加密→資料通道→安全通道→傳訊；降級後另一端看不到差異；第三者無法進入；Worker 日誌無代號／IP（檢查 `wrangler dev` 輸出）。若真實 WebRTC 在本機環境跑不起來，明確標記並用已有的 `DataChannelTransport` 單元層測試補足，列為使用者實機驗證。
- [ ] **Step 2: 相容性**：舊版（v5.6.0，`.worktrees/interop-old`）與新版互連：新版不會對舊版建立 `/rv` 連線，舊版不受影響；HELLO 無新旗標。
- [ ] **Step 3: 在地化稽核**（唯讀 Python `-I`）：相對 Base 新增／變更的 key 五語系齊全、非繁中 `needs_review`、格式符號一致；掃描新程式碼中的硬編碼使用者文字；補缺（只文字插入）。
- [ ] **Step 4:** 跑全部：Kit、Worker、iOS 單元、iOS／Mac 建置、UI 測試 build-for-testing；確認 pbxproj 差異只新增。
- [ ] **Step 5: 草擬 PR 說明**（繁體中文）至 scratchpad `pr-notes-project-e.md`：摘要、架構、威脅模型（§6.1 誠實說明）、已審查關閉的攻擊類型、**所有 Rulings**、已知缺口與延後項、**部署說明**（Worker PR 合併即自動部署；先惰性；合併後以 `gh run list --workflow=worker-deploy.yml` 驗證）、使用者要實機驗證的項目（兩台不同網路真實連線、前景／背景切換、日界、網路切換重連、Mac 長時間、降級不可區分、TURN）、後續（假流量、逐陌生人不推播需 NSE 權限、只走 TURN 選項、前向保密）。不 push。
