# 專案 G1b：群組聊天室客戶端核心（`PeerDropGroups`）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出群組聊天室的客戶端核心（無介面）：加解密、HTTP 客戶端、金鑰生命週期（取回／補封裝／輪換）、同步與即時連線、推播接線，讓 G2 只需要蓋介面。

**Architecture:** 新增 SwiftPM 模組 `PeerDropGroups`（仿 `PeerDropDiary`：純函式 `GroupCrypto`、`actor GroupClient`、加密落盤的 `GroupSecretsStore`／`GroupEventLog`、`@MainActor GroupStore`）。即時層 `GroupSocket` 走票券 WebSocket，發言一律走 HTTP。`PeerDropCore` 持有 `GroupStore`，推播與深層連結只接線、不做畫面。另有一個小的 Worker 任務（群組限流 120/分鐘）。

**Tech Stack:** Swift 5.9、CryptoKit（X25519／HKDF／AES-GCM／Ed25519）、URLSession（HTTP＋`URLSessionWebSocketTask`）、`ChatDataEncryptor`、XCTest；Worker 端 TypeScript＋vitest。

**Spec:** `docs/superpowers/specs/2026-10-24-project-f-g-categories-group-rooms-design.md` §3、§3.8、§3.9；伺服器契約：`cloudflare-worker/GROUPS.md`「G1b／G2 客戶端必須實作的事項」；加密向量：`cloudflare-worker/test-vectors/group-crypto.json`（伺服器已部署，PR #195）。

## Global Constraints

- 一律繁體中文台灣用語（程式註解、commit 說明、字串）。commit 格式 `type: short description`，結尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`；**永遠不用 `git commit -a`**，只 `git add` 指定檔；本機未提交的 `.gitignore` 修改與未追蹤的 `docs/pet-design/` 不得提交；review 修正不 squash。
- worktree：`.worktrees/peer-drop-g1b`（分支 `feat/project-g1b-group-client`，base＝`origin/main` `a698abc`）。**不 push、不開 PR、不部署**，除非使用者明說。Worker 任務只在本機 vitest／miniflare；**絕不 `wrangler deploy`／`--remote`**。
- `PeerDropGroups` 不得 import UIKit／AppKit／SwiftUI；iOS 16.0＋、macOS 13＋ 都要編譯。落盤一律走 `ChatDataEncryptor`；任何 log 不得含 groupId、邀請碼、金鑰、簽章、密文，只能用固定字串。
- 加密格式**以 `group-crypto.json` 為準**：測試必須讀同一個檔案（路徑由 `#filePath` 往上推到 repo 根）。nonce(12)‖ciphertext‖tag(16)；wrap 92 B；`epoch` 一律 `UInt32` 大端；ids 為 26 字 Crockford ULID。
- 契約數字：訊息明文 ≤ 4,000 unicode scalars、`payloadCipher` ≤ 8 KB；metaCipher 解碼後 ≤ 400 KB；暱稱 ≤ 20 字；事件 `eventId` 去重；ws 心跳為每 30 秒一個**文字**訊框 `"ping"`；關閉碼 4000＝被取代（可重連）、4001＝2 小時到期（重連＋補抓）、4003＝已不是成員（**不重連**）。
- 每個群組路由都帶 `X-Group-Member-Id`；匿名身分只能走 Bearer。升級 WebSocket 時不帶 Authorization，只帶一次性票券。
- 驗證指令：`cd PeerDropKit && swift test --filter <Target>`；Worker：`cd cloudflare-worker && npx vitest run <file> && npx tsc --noEmit`。Kit 全套唯一允許的既有失敗：`IdentityKeyManagerTests.testKeyPersistsAcrossInstances`。App 層建置：`xcodegen generate` 後 `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`；Mac：`-scheme PeerDropMac`。外接碟可能中途斷線：`git status` 後重新驗證檔案再繼續。
- 新字串五語系（en、zh-Hant、zh-Hans、ja、ko）；ja／ko／zh-Hans 標 `needs_review`。

## Rulings（計畫階段的決定，執行者照辦；可被使用者推翻）

1. **限流**：把單一常數改成「類別→上限」，`groups`＝120/分鐘/IP，其餘維持 30（使用者 2026-10-25 同意）。每帳號限流不做。`index.ts` 不得新增非函式的具名 export（miniflare 會崩，見該檔註解）。
2. **49 人房推播子請求約 250 次**：付費方案單次 invocation 上限 1,000，足夠；本專案不改推播，**G2 送審前須確認 Workers 為付費方案**（寫進 PR 說明）。
3. `AccountClient.request` 新增 `headers: [String: String] = [:]`（只加不改，既有呼叫端不受影響），用來帶 `X-Group-Member-Id`。
4. `stale_epoch`／`members_changed` 回應裡的 `epoch`／`memberIds` **不解析**：`AccountClientError` 只保留錯誤碼；客戶端遇到就重打 `GET /v3/groups/:id` 取得現況再重試。
5. `GroupEventLog` 複製 `DiaryEventLog` 的分框方式（約 60 行），**不重構日記**去共用。
6. `category` 在 G1b 是不透明字串；列舉與顯示名稱由 G2 定義。照片、背景只定義資料欄位與大小檢查，縮圖在 G2。
7. 帳號成員的顯示名稱（暱稱）由 G2 經目錄查；G1b 只暴露 `accountId`。簽章驗證所需的簽章公鑰經 `GroupDirectory` 協定取得（正式版包 `AccountClient.lookup`＋快取）。
8. 房內暱稱：匿名成員加入後送第一則 `kind: "identity"` 的加密訊息（`nickname` ≤ 20 字）；帳號成員不送。讀端以「最後一則 identity」為準。
9. 金鑰只由**帳號成員**補封裝（使用者決定）；補封裝前必須驗被封裝者的 `pubKeySig`（帳號成員）；匿名成員的公鑰無法驗證，仍封裝，介面另行標示。
10. 被取代（HTTP 403 `not_member`，或 ws 4003）→ 狀態 `removed`，停止重連，**本機歷史保留唯讀**，由使用者決定刪除。
11. 舊 P2P 群組聊天（`GroupChatView` 等）的移除放在 G2（需要新介面接手），G1b 不碰。
12. 邀請連結：`peerdrop://group/<groupId>?code=<inviteCode>`，**不帶金鑰**。深層連結在 G1b 只解析並暫存為「待加入」，不開畫面。

## Review Focus

1. 事件（ws 或補抓）比它的 `epoch` 金鑰先到 → 保留密文、標「等待金鑰」，金鑰裝好後補解；絕不丟棄。
2. 同一筆事件經 ws 與補抓各來一次、或發言逾時後重送 → 只出現一則（`eventId` 去重）；重送沿用同一個 `eventId`。
3. 偽造／損毀：作者不在成員表、AAD 對不上、明文不是合法 JSON、超過 4,000 字 → 安靜略過、不 crash、不擋後面的事件。
4. App 在建立／加入途中被殺 → 本機身分（`memberId`＋房內私鑰）必須在**第一個網路請求之前**落盤；重送 create／join 是冪等的，不會產生第二個 `memberId`。
5. 429／5xx／逾時是暫時性錯誤（退避重試，不報給使用者為「失敗」）；403 `not_member` 與 ws 4003 才是「被移出」，且不重連。

---

### Task 1: Worker 群組限流 120/分鐘

**Files:**
- Modify: `cloudflare-worker/src/index.ts:98-170`（`RATE_LIMIT_MAX_REQUESTS`、`isRateLimited`）
- Modify: `cloudflare-worker/src/__tests__/rate-limit.spec.ts`

**Interfaces:**
- Produces: `export function rateLimitMax(routeClass: string): number`（`groups`→120，其餘→30）；`isRateLimited` 改用它。

- [ ] **Step 1: 寫失敗測試**（`rate-limit.spec.ts` 新增）：`rateLimitMax("groups") === 120`、`rateLimitMax("v3") === 30`、`rateLimitMax("unknown-class") === 30`；整合：同一 IP 對 `/v3/groups`（無憑證即可被限流器先攔，沿用該檔既有的打法）連打 120 次不被 429、第 121 次 429；同一 IP 對 `/v3/diaries` 第 31 次仍是 429（別的類別沒被放寬）。
- [ ] **Step 2:** `npx vitest run src/__tests__/rate-limit.spec.ts` → 新測試失敗。
- [ ] **Step 3:** 實作 `rateLimitMax`（模組內部 `const RATE_LIMITS` 為**非 export**），`isRateLimited` 用 `rateLimitMax(routeClass)`；更新 `rate-limit.spec.ts` 檔頭註解與其自帶的 30 副本（沿用 30 給非 groups 測試）。
- [ ] **Step 4:** `npx vitest run && npx tsc --noEmit` 全綠（含 466 個既有測試）。
- [ ] **Step 5: Commit**
```bash
git add cloudflare-worker/src/index.ts cloudflare-worker/src/__tests__/rate-limit.spec.ts
git commit -m "feat: 群組路由限流放寬為每 IP 每分鐘 120 次"
```

---

### Task 2: 模組骨架＋`GroupCrypto`（讀共用向量）

**Files:**
- Modify: `PeerDropKit/Package.swift`（library＋target `PeerDropGroups`，deps `PeerDropPlatform, PeerDropSecurity, PeerDropTransport, PeerDropAccount, PeerDropNotes`；testTarget `PeerDropGroupsTests`，deps 同 Diary 測試；`PeerDropCore` 的 deps 加 `"PeerDropGroups"`）
- Modify: `project.yml`（app 與 Mac 兩處 `product: PeerDropDiary` 旁邊加 `PeerDropGroups`），之後 `xcodegen generate`
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupCrypto.swift`、`GroupPayloads.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupCryptoVectorTests.swift`、`GroupCryptoTests.swift`

**Interfaces:**
- Produces（`GroupPayloads.swift`）：
  - `public struct GroupMessagePayload: Codable, Equatable { public enum Kind: String, Codable { case text, identity }; public var kind: Kind; public var text: String?; public var nickname: String? }`
  - `public struct GroupMetaPlaintext: Codable, Equatable { name: String; description: String?; category: String?; photo: Data?; background: GroupBackground? }`、`public enum GroupBackground: Codable, Equatable { case preset(String); case custom(Data) }`；欄位除 `name` 外皆可缺（向量樣本 `{"name":"週末爬山","category":"興趣"}` 必須能解）。限制常數 `GroupLimits.nameScalars=30, descriptionScalars=200, nicknameScalars=20, messageScalars=4000, photoBytes=128*1024, customBackgroundBytes=256*1024, metaBytes=400*1024`。
- Produces（`GroupCrypto.swift`，全為 `public enum GroupCrypto` 的 static 純函式）：
  - `memberKeyMessage(groupId:memberId:accountId:pubKey: Data) -> Data`、`wrapMessage(groupId:epoch: UInt32, target:wrapper:wrapped: Data) -> Data`
  - `wrap(roomKey: SymmetricKey, groupId:epoch:recipientMemberId:recipientPublicKey: Curve25519.KeyAgreement.PublicKey, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: AES.GCM.Nonce = .init()) throws -> Data`（92 B）
  - `unwrap(_ wrapped: Data, groupId:epoch:memberId:privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> SymmetricKey`
  - `sealMessage(_:key:groupId:memberId:eventId:epoch:nonce: AES.GCM.Nonce = .init()) throws -> Data`、`openMessage(_ data: Data, key:groupId:memberId:eventId:epoch:) throws -> GroupMessagePayload`
  - `sealMeta(_:key:groupId:epoch:nonce:)`、`openMeta(_:key:groupId:epoch:) throws -> GroupMetaPlaintext`
  - `verify(signature: Data, message: Data, signingPublicKey: Data) -> Bool`、`sign(_ message: Data, with: Curve25519.Signing.PrivateKey) -> Data`（測試／補封裝簽章用的薄包裝；正式簽章由呼叫端注入）
  - `enum GroupCryptoError: Error, Equatable { case badLength, decryptionFailed, malformedPlaintext, oversized }`；text 超過 4,000 scalars 在 seal 時丟 `.oversized`，open 時同樣檢查。

- [ ] **Step 1: 寫失敗測試**（`GroupCryptoVectorTests`，載入向量 JSON）：
  - `memberKeyMessage(...)` 的 hex ＝ `memberKeySig.messageHex`；用 `signing.publicKeyHex` 驗 `signatureHex` 為真；改任一 byte 驗為假。
  - 用 `wrap` 向量的固定 ephemeral 私鑰與 nonce 呼叫 `wrap(...)` ＝ `wrappedHex`（逐位元組）；`unwrap(wrappedHex, ..., recipientPrivateKeyHex)` ＝ `roomKeyHex`；`wrapMessage` ＝ `wrapSig.messageHex` 且簽章可驗。
  - `sealMessage` 以固定 nonce ＝ `payloadCipherB64`；`openMessage` 還原 plaintext（JSON 外殼見下一步斷言：解出的 `GroupMessagePayload.text == "哈囉，群組！Hello group 👋"`，向量裡的 plaintext 是純字串，所以此測試用 `sealRaw`/`openRaw` 內部函式比對位元組，再另測 JSON 往返）。
  - `sealMeta` 以固定 nonce ＝ `metaCipherB64`；`openMeta` 解出 `name == "週末爬山"`、`category == "興趣"`。
- [ ] **Step 2:** `swift test --filter GroupCryptoVectorTests` → 編譯失敗（型別不存在）。
- [ ] **Step 3:** 建模組骨架與 `GroupCrypto`。HKDF salt＝`ephemeralPub‖recipientPub`、info＝`peerdrop-group-wrap-v1`；AAD 組法照 `GROUPS.md`；內部 `sealRaw/openRaw(plaintext:key:aad:nonce:)` 供向量比對。
- [ ] **Step 4:** 補 `GroupCryptoTests`：往返；換 groupId／memberId／eventId／epoch 任一個 open 失敗（`.decryptionFailed`）；92 B 以外的 wrapped 丟 `.badLength`；4,001 scalars 的文字 `.oversized`；暱稱 21 字被拒。
- [ ] **Step 5:** `swift test --filter PeerDropGroupsTests` 全綠；`xcodegen generate` 後 `swift build` 成功。
- [ ] **Step 6: Commit**
```bash
git add PeerDropKit/Package.swift project.yml PeerDropKit/Sources/PeerDropGroups PeerDropKit/Tests/PeerDropGroupsTests
git commit -m "feat: PeerDropGroups 模組與 GroupCrypto（共用向量）"
```

---

### Task 3: `AccountClient` 標頭參數＋`GroupClient`

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropAccount/AccountClient.swift:191`（`request`／`send` 加 `headers`）
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupClient.swift`、`GroupWire.swift`、`GroupError.swift`
- Test: `PeerDropKit/Tests/PeerDropAccountTests/AccountClientHeadersTests.swift`、`PeerDropKit/Tests/PeerDropGroupsTests/GroupClientTests.swift`（沿用 `TestURLProtocol` 的做法，從 Diary 測試複製一份到 Groups 測試目錄）

**Interfaces:**
- Consumes: `AccountClient.request<B,R>(_ method:_ path:body:headers:)`。
- Produces（`GroupWire.swift`，`Codable`）：`GroupView { groupId, ownerMemberId?, members: [WireMember], joinPolicy, state, epoch, seq, firstSeq, metaVersion, rotationDue, inviteCode? }`；`WireMember { memberId, kind, accountId?, joinedAt, pubKey, pubKeySig?, hasKey }`；`WireEvent { seq, eventId, type: msg|join|leave|kick|meta, authorMemberId, epoch, payloadCipher?, targetMemberId?, ownerMemberId?, metaVersion?, rotated?, createdAt }`；`EventsPage { events, firstSeq, nextSince? }`；`WireWrap { epoch, wrapped, wrappedBy, sig }`；`WrapIn { memberId, wrapped, sig }`。
- Produces（`GroupError.swift`）：`enum GroupError: Error, Equatable { notMember, awaitingKey, staleEpoch, membersChanged, notOwner, closed, banned, badCode, accountRequired, bearerRequired, membersFull, groupLimit, exists, tooLarge, badSignature, notFound, badId, transient(String), network(String) }` 與 `static func from(_ error: Error) -> GroupError`（429、5xx、URLError → `.transient`；對照表照 `group.ts` 的 `DO_ERROR_STATUS`）。
- Produces（`actor GroupClient`，`init(account: AccountClient = AccountClient())`；每個需要成員身分的方法都收 `memberId: String`，並驗 groupId 為 26 字 ULID，否則 `.badId` 且不發請求）：
  `create(groupId:memberId:pubKey:pubKeySig:ownerWrap: (wrapped:sig:), metaCipher:joinPolicy:) -> (groupId, inviteCode)`；`list() -> [GroupListRow]`；`view(id:memberId:) -> GroupView`；`join(id:memberId:pubKey:pubKeySig:as:inviteCode:) -> JoinResult`；`joinByCode(memberId:pubKey:pubKeySig:as:inviteCode:)`；`leave`、`close`、`kick(id:memberId:target:)`、`resetInvite -> String`；`events(id:memberId:since:limit:) -> EventsPage`；`postMessage(id:memberId:eventId:epoch:payloadCipher:) -> Int`；`metaCipher(id:memberId:) -> (metaCipher: String, metaVersion: Int)`；`putMeta(id:memberId:eventId:metaCipher:joinPolicy:removeAnonymous:) -> (seq, metaVersion)`；`rotate(id:memberId:eventId:epoch:metaCipher:wraps:) -> (seq, epoch)`；`myKeys(id:memberId:) -> [WireWrap]`；`putKeys(id:memberId:epoch:wraps:) -> (written, skipped)`；`requestKey`；`wsTicket(id:memberId:) -> String`；`report(id:memberId:seq:reason: ReportReason, excerpt:) -> String`。

- [ ] **Step 1: 寫失敗測試（Account）**：`request(..., headers: ["X-Group-Member-Id": "X"])` 的 `URLRequest` 帶該標頭；不傳 `headers` 時行為不變（既有 `PeerDropAccountTests` 全綠）。
- [ ] **Step 2: 失敗測試（Groups）**：每個方法的 method／path／body 形狀（以 `TestURLProtocol` 斷言：`POST /v3/groups`、`GET /v3/groups/:id/events?since=&limit=`、`PUT /v3/groups/:id/keys` …）、所有成員路由都帶 `X-Group-Member-Id`、base64 欄位保持字串（不被 `dataEncodingStrategy` 二次編碼）；錯誤對照：403 `awaiting_key`→`.awaitingKey`、403 `not_member`→`.notMember`、409 `stale_epoch`→`.staleEpoch`、409 `members_changed`→`.membersChanged`、409 `group_full_members`→`.membersFull`、409 `group_limit`→`.groupLimit`、400 `bad_sig`→`.badSignature`、413→`.tooLarge`、429→`.transient`、503→`.transient`、404→`.notFound`；`id` 含 `/` 或 `..` → `.badId` 且 `TestURLProtocol` 收到 0 個請求。
- [ ] **Step 3:** 實作（`headers` 預設空字典、在 `authProvider` 之前設定；`GroupClient` 全部走 `account.request`）。
- [ ] **Step 4:** `swift test --filter PeerDropAccountTests` 與 `--filter GroupClientTests` 全綠。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropAccount/AccountClient.swift PeerDropKit/Sources/PeerDropGroups PeerDropKit/Tests/PeerDropAccountTests PeerDropKit/Tests/PeerDropGroupsTests
git commit -m "feat: GroupClient 與 AccountClient 自訂標頭"
```

---

### Task 4: `GroupSecretsStore`（本機身分與各世代房間金鑰）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupSecretsStore.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupSecretsStoreTests.swift`

**Interfaces:**
- Produces: `public struct GroupIdentity: Codable, Equatable { memberId: String; kind: Kind(.account/.anon); roomPrivateKey: Data(32); createdAt: Date; isOwner: Bool }`；`public final class GroupSecretsStore`（`init(directory: URL? = nil, encryptor: ChatDataEncryptor = .shared)`，預設 `Documents/Groups`，每群組一個資料夾）：
  `identity(for:) -> GroupIdentity?`、`saveIdentity(_:for:) throws`、`roomKey(for:epoch:) -> SymmetricKey?`、`saveRoomKey(_:for:epoch:) throws`、`epochs(for:) -> [UInt32]`（升冪）、`latestEpoch(for:) -> UInt32?`、`remove(group:) throws`、`allGroupIds() -> [String]`。檔案：`identity.enc`、`keys.enc`（`[epoch: base64 key]`）。長度不是 32 B 的資料視為不存在。

- [ ] **Step 1: 寫失敗測試**：身分往返；金鑰往返且多世代並存、`latestEpoch` 正確；寫入損毀（非 32 B）→ 讀回 nil；`remove` 後全部讀不到；寫入的檔案不含明文金鑰位元組（grep 檔案內容找不到 `roomKey` 的原始 32 B）。
- [ ] **Step 2:** 失敗。 **Step 3:** 實作（原子寫入，沿用 `DiaryKeyStore` 的作法）。 **Step 4:** 通過。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropGroups/GroupSecretsStore.swift PeerDropKit/Tests/PeerDropGroupsTests/GroupSecretsStoreTests.swift
git commit -m "feat: GroupSecretsStore 本機身分與世代金鑰"
```

---

### Task 5: `GroupEventLog`（加密落盤、去重、補洞）

**Files:**
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupEventLog.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupEventLogTests.swift`

**Interfaces:**
- Consumes: `WireEvent`（Task 3）。
- Produces: `public final class GroupEventLog: @unchecked Sendable`（`init(url: URL, encryptor: ChatDataEncryptor = .shared)`）：`append(_ event: WireEvent) throws`（同 `eventId` 已存在則不重複寫）、`load() -> LoadResult { events: [WireEvent]（seq 升冪、eventId 唯一）, droppedTailBytes: Int }`、`lastSeq: Int`（由 `load` 結果推得，空為 0）。分框格式與損毀尾巴截斷行為與 `DiaryEventLog` 相同（Ruling 5）。

- [ ] **Step 1: 失敗測試**：往返；同 `eventId` 附加兩次只留一筆；亂序附加後 `load` 依 seq 排序；中間一個 frame 位元組損毀 → 略過該筆、其餘照讀；尾巴被截斷（模擬 crash）→ 檔案截到最後完整 frame 並回報 `droppedTailBytes > 0`；檔案內容為密文（找不到 `eventId` 明文）。
- [ ] **Step 2–4:** 失敗 → 實作 → 通過。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropGroups/GroupEventLog.swift PeerDropKit/Tests/PeerDropGroupsTests/GroupEventLogTests.swift
git commit -m "feat: GroupEventLog 事件日誌（去重、損毀修復）"
```

---

### Task 6: `GroupStore` 核心——建立、加入、離開、清單

**Files:**
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupStore.swift`、`GroupModels.swift`、`GroupInviteLink.swift`、`GroupDirectory.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupStoreLifecycleTests.swift`、`GroupInviteLinkTests.swift`、`GroupTestFixtures.swift`（以 `TestURLProtocol` 模擬伺服器的小型 fake：記錄請求、依路由回罐頭回應）

**Interfaces:**
- Consumes: Task 2–5 全部。
- Produces（`GroupDirectory.swift`）：`public protocol GroupDirectory: Sendable { func signingKey(accountId: String) async -> Data? }`；正式實作 `LiveGroupDirectory(account: AccountClient)`（`lookup(handle:includeBundle:false)`＋記憶體快取，失敗回 nil）。
- Produces（`GroupInviteLink.swift`）：`enum GroupInviteLink { static func parse(_ url: URL) -> (groupId: String, code: String)?; static func make(groupId:code:) -> URL; static func logSafeDescription(_ url: URL) -> String }`（Ruling 12）。
- Produces（`GroupModels.swift`）：`GroupSummary: Identifiable { groupId, name: String?, memberCount, unread: Int, lastActivity: Date?, state: open/closed/removed, awaitingKey: Bool }`；`GroupMember { memberId, kind, accountId?, nickname?（來自 identity 訊息）, hasKey, isOwner, pubKeyVerified: Bool }`；`GroupMessage { eventId, seq, authorMemberId, text, createdAt, isMine }`；`GroupState { groupId, meta: GroupMetaPlaintext?, members, messages, pendingDecryptCount, isOwner, myMemberId, identityKind, joinPolicy, state, epoch, rotationDue, hasGap: Bool, supersededElsewhere: Bool }`。
- Produces（`@MainActor public final class GroupStore: ObservableObject`）：`@Published private(set) var groups: [GroupSummary]`、`states: [String: GroupState]`、`lastError: String?`；`init(client: GroupClient, directory: GroupDirectory, secrets: GroupSecretsStore, rootDirectory: URL, localAccount: @escaping () -> LocalAccount?, newId: @escaping () -> String, now: @escaping () -> Date = Date.init)`，其中 `LocalAccount { accountId: String; signingPublicKey: Data; sign: (Data) throws -> Data }`；`init(mock:)` 供 G2 預覽用。方法：`load()`（讀本機資料夾還原清單）、`syncList() async`（`GET /v3/groups` 只用來發現「伺服器說我在、本機沒有」→ 不自動加入，記入 `unknownGroupIds`，Spec §0.3 第二台裝置不顯示）、`create(name:description:category:joinPolicy:) async throws -> String`、`join(link: URL, as: IdentityKind, nickname: String?) async throws -> String`、`join(code: String, as:nickname:)`、`leave(_ id: String) async throws`、`inviteLink(for:) -> URL?`、`remove(localGroup:)`。

建立流程（Review Focus 4）：產生 `groupId`／`memberId`（`newId()`）與 X25519 房內金鑰對 → **先存 `GroupIdentity`** → 產生 32 B roomKey 存為 epoch 1 → `sealMeta` → `wrap`（自己，epoch 1）→ 簽 `memberKeyMessage`、`wrapMessage` → `client.create`。加入流程同理（身分先落盤；帳號成員簽 `memberKeyMessage`；匿名不簽）；匿名加入成功後立刻送一則 `identity` 訊息（Ruling 8）。`join` 回 403 `not_member`／409 `exists` 等失敗時，**僅在伺服器明確拒絕時**才刪除剛建的本機身分；暫時性錯誤保留以便重試。

- [ ] **Step 1: 失敗測試**（fake 伺服器）：
  - `testCreateWritesIdentityBeforeFirstRequest`：fake 在收到 `POST /v3/groups` 時檢查 `secrets.identity(for:)` 已存在；
  - `testCreateSignaturesVerifyAgainstVectorsStyleChecks`：送出的 `pubKeySig`、`ownerWrap.sig` 以測試簽章金鑰驗證為真，`ownerWrap.wrapped` 能用房內私鑰 `unwrap` 回 roomKey；
  - `testCreateResendIsIdempotent`：第一次請求逾時（URLError）→ 重送沿用同一 `groupId`／`memberId`，不產生第二組身分；
  - `testJoinAnonymousSendsIdentityMessageAfterJoin`、`testJoinAccountRequiresAccount`（`localAccount()==nil` → `GroupError.accountRequired` 且 0 請求）、`testJoinWrongCodeKeepsNoLocalState`（403 `bad_code` → 本機身分被清掉）、`testJoinTransientErrorKeepsIdentity`；
  - `testLeaveRemovesLocalKeysButKeepsNothingSecret`；`testInviteLinkRoundTrip`、`GroupInviteLinkTests`（錯 host、缺 code、`logSafeDescription` 不含 query）。
- [ ] **Step 2–4:** 失敗 → 實作 → `swift test --filter PeerDropGroupsTests` 全綠。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropGroups PeerDropKit/Tests/PeerDropGroupsTests
git commit -m "feat: GroupStore 建立／加入／離開與邀請連結"
```

---

### Task 7: 同步、解密、發言、未讀、本機封鎖

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropGroups/GroupStore.swift`（或拆出 `GroupStore+Sync.swift`）
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupBlockList.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupStoreSyncTests.swift`

**Interfaces:**
- Consumes: `GroupClient.view/events/postMessage`、`GroupEventLog`、`GroupSecretsStore`。
- Produces（`GroupStore`）：`sync(_ id: String) async`（同一群組同時只跑一個，後來的合併成「跑完再跑一次」）、`ingest(_ events: [WireEvent], into id: String)`（ws 與補抓共用）、`send(_ id: String, text: String) async throws`、`markRead(_ id: String)`、`block(memberId:in:)`／`unblock`／`isBlocked`（`GroupBlockList`：加密落盤，每群組一份 memberId 集合）。

同步規則：`view` → 更新成員／狀態／`epoch`／`rotationDue`；403 `not_member` → `removed`＋`supersededElsewhere` 判斷（Ruling 10）；`events(since: lastSeq)` 分頁取完；`since < firstSeq-1` → `hasGap = true`；事件先寫入 `GroupEventLog`（去重）再解密；缺金鑰的 `msg` 計入 `pendingDecryptCount` 並保留；`join/leave/kick/meta` 事件更新成員表與 `metaVersion`（`meta` 事件有 `metaVersion` 較新時重抓 `metaCipher`）；`identity` 訊息更新該 `memberId` 的暱稱（只認作者本人的 identity，且 ≤ 20 字）；被封鎖 `memberId` 的訊息不進 `messages` 也不計未讀；作者不在成員表（且不是已知的過往成員）的 `msg` 略過。`send`：`awaiting_key`／無金鑰 → 丟 `.awaitingKey` 不送；用最新世代金鑰；逾時重送沿用同一 `eventId`；`stale_epoch` → 先 `sync` 再以新世代重送一次；文字空白或 > 4,000 scalars → 本地拒絕。

- [ ] **Step 1: 失敗測試**（Review Focus 1–3、5）：
  - `testBackfillDecryptsAndOrdersBySeq`、`testSameEventFromSocketAndBackfillAppearsOnce`、`testSendRetryReusesEventId`（第一次逾時、第二次 200 → 兩次請求 `eventId` 相同、畫面只有一則）；
  - `testEventBeforeKeyIsKeptThenDecryptsWhenKeyArrives`：先收到 epoch 2 的 msg（只有 epoch 1 金鑰）→ `pendingDecryptCount == 1`、`messages` 無；`saveRoomKey(epoch 2)` 後再 `sync` → 出現；
  - `testForgedAndGarbledEventsAreSkipped`：四種（作者不在成員表、AAD 錯、明文非 JSON、4,001 字）各一筆夾在兩筆正常訊息中間 → 正常訊息全出現、無 crash；
  - `testGapSetsHasGap`、`testNotMemberMarksRemovedAndKeepsHistory`、`testTransientErrorDoesNotMarkRemoved`（503／429／URLError）；
  - `testBlockedMemberHiddenAndNotUnread`、`testUnreadCountsOnlyOthersMessagesAfterMarkRead`；`testSendRejectsEmptyAndOversizedWithoutRequest`、`testSendWhenAwaitingKeyThrowsAndSendsNothing`；`testStaleEpochResyncsOnceThenResends`。
- [ ] **Step 2–4:** 失敗 → 實作 → 通過。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropGroups PeerDropKit/Tests/PeerDropGroupsTests
git commit -m "feat: GroupStore 同步、解密、發言與本機封鎖"
```

---

### Task 8: 金鑰生命週期——取回、補封裝、輪換

**Files:**
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupStore+Keys.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupStoreKeyTests.swift`

**Interfaces:**
- Consumes: `GroupClient.myKeys/putKeys/rotate/requestKey/view`、`GroupDirectory`、`GroupCrypto.wrap/unwrap/verify`。
- Produces（`GroupStore`）：`installKeys(for id: String) async`（`GET /keys` → 對每個 wrap：以 `wrappedBy` 成員的帳號簽章公鑰驗 `wrapMessage` 簽章，驗過才 `unwrap` 並存；驗不過略過）、`relayKeys(for id: String, force: Bool = false) async`（本機有現行世代金鑰、且是帳號成員時：對 `hasKey == false` 的成員補封裝——帳號成員先驗其 `pubKeySig`，驗不過跳過；簽 `wrapMessage` 後 `putKeys`；每次最多處理 50 位）、`requestKey(_ id: String) async throws`、`rotateIfNeeded(_ id: String) async`（僅房主，且 `rotationDue == true`：產生新 roomKey、`epoch+1`、為**所有現任成員**封裝、`sealMeta` 以新世代重加密現有 meta、`client.rotate`；409 `members_changed`／`stale_epoch` → 重抓 `view` 後重試，最多 3 次）、`handlePush(kind: String, groupId: String) async`（`groupMessage` → `sync`；`groupKeyRequest` → `relayKeys(force: true)`；本機沒有該群組 → 視為同步清單，不報錯）。`sync` 結尾自動依序呼叫 `installKeys`（缺金鑰時）、`relayKeys`、`rotateIfNeeded`。

- [ ] **Step 1: 失敗測試**：
  - `testInstallKeysVerifiesWrapperSignature`：簽章正確 → 裝入；簽章被改一個 bit → 不裝入、不 crash；`wrappedBy` 的簽章公鑰查不到（directory 回 nil）→ 不裝入；
  - `testRelayWrapsOnlyForMembersWithoutKeyAndVerifiesPubKeySig`：三位成員（已有金鑰／帳號且簽章正確／帳號但 `pubKeySig` 被竄改）→ 只送出第二位的 wrap；匿名成員會被封裝；`wrapped` 能被對方私鑰 `unwrap`、簽章可驗；
  - `testRelayOnlyByAccountMember`（匿名身分呼叫 `relayKeys` 不發請求）；
  - `testRotateWrapsEveryCurrentMemberAndReencryptsMeta`：新 `epoch == 舊+1`、wraps 數 ＝ 現任成員數、`metaCipher` 能用新金鑰開、舊訊息仍可用舊金鑰解；
  - `testRotateRetriesOnMembersChanged`（第一次 409 → 重抓 view → 第二次成功）、`testRotateOnlyForOwner`、`testNoRotationWhenNotDue`；
  - `testPushKeyRequestTriggersRelay`、`testPushForUnknownGroupDoesNotThrow`。
- [ ] **Step 2–4:** 失敗 → 實作 → 通過。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropGroups PeerDropKit/Tests/PeerDropGroupsTests
git commit -m "feat: 群組金鑰取回、補封裝與輪換"
```

---

### Task 9: 管理與檢舉

**Files:**
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupStore+Admin.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupStoreAdminTests.swift`

**Interfaces:**
- Produces（`GroupStore`）：`kick(_ id: String, memberId: String) async throws`（僅房主；成功後 `sync` 並觸發 `rotateIfNeeded`）、`close(_ id: String) async throws`、`resetInvite(_ id: String) async throws -> String`（更新 `inviteLink`）、`updateMeta(_ id: String, _ meta: GroupMetaPlaintext, joinPolicy: JoinPolicy? = nil, removeAnonymous: Bool? = nil) async throws`（僅房主；名稱必填 ≤ 30、說明 ≤ 200、照片 ≤ 128 KB、自訂背景 ≤ 256 KB、整體 ≤ 400 KB，超過本地拒絕；`sealMeta` 用現行世代）、`report(_ id: String, seq: Int, reason: ReportReason, includeText: Bool) async throws`（`includeText` 時附上本機已解密的文字、截 1,000 字；只能檢舉 `msg` 事件）。

- [ ] **Step 1: 失敗測試**：非房主呼叫 kick／close／resetInvite／updateMeta → `.notOwner` 且 0 請求；`updateMeta` 各項超限本地拒絕（0 請求）；`kick` 成功後房主 `rotationDue` 被處理（出現 `POST /rotate`）；`report` 的 body 形狀與 1,000 字截斷、`includeText:false` 時 `excerpt` 缺省、對 `join` 事件檢舉 → 本地拒絕；`resetInvite` 後 `inviteLink` 的 code 更新；`close` 後狀態 `closed` 且 `send` 被本地拒絕但歷史仍可讀。
- [ ] **Step 2–4:** 失敗 → 實作 → 通過。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropGroups PeerDropKit/Tests/PeerDropGroupsTests
git commit -m "feat: 群組管理（踢人、關閉、改設定）與檢舉"
```

---

### Task 10: `GroupSocket` 即時連線

**Files:**
- Create: `PeerDropKit/Sources/PeerDropGroups/GroupSocket.swift`、`GroupStore+Live.swift`
- Test: `PeerDropKit/Tests/PeerDropGroupsTests/GroupSocketTests.swift`

**Interfaces:**
- Produces: `protocol GroupWebSocket: AnyObject, Sendable { func send(text: String) async throws; func receive() async throws -> String; func close() }`；`protocol GroupWebSocketFactory: Sendable { func make(url: URL) -> GroupWebSocket }`（正式版包 `URLSessionWebSocketTask`，URL 由 `baseURL` 轉 `wss://…/v3/groups/<id>/ws?ticket=<ticket>`，**不帶 Authorization**）；`actor GroupSocket`（`init(groupId:, ticket: @Sendable () async throws -> String, factory:, onEvent: @Sendable (WireEvent) -> Void, onClosed: @Sendable (CloseReason) -> Void, clock: …)`）：`start()`／`stop()`；每 30 秒送文字 `"ping"`；只處理 `{"t":"ev","e":…}`，其他框忽略；關閉碼 4000／4001／網路中斷 → 取新票券重連（指數退避 1→2→4→…最多 30 秒，重連成功後通知 store 補抓）、4003 → `onClosed(.removed)` 且**不重連**；連續重連失敗不無限緊迫迴圈（退避上限＋隨機抖動）。
- Produces（`GroupStore`）：`connect(_ id: String)`／`disconnect(_ id: String)`；收到事件走 `ingest`；`.removed` → 狀態 `removed`；前景／被選中的群組才連線（呼叫端決定）。

- [ ] **Step 1: 失敗測試**（假 `GroupWebSocket`＋可控時鐘）：30 秒送一次 `"ping"`（文字框、內容恰為 `ping`）；收到 `{"t":"ev",…}` 呼叫 `onEvent` 一次；收到 `"pong"` 與未知框不報錯；關閉碼 4001 → 以**新票券**重連並觸發補抓回呼；4000 同上；4003 → `onClosed(.removed)`、之後 10 分鐘（模擬）內 0 次重連；連線失敗退避序列為 1,2,4,8,16,30,30 秒（容許抖動 ±25%）；票券請求失敗（`.transient`）也退避重試、`.notMember` 則視同被移出；`stop()` 後不再重連。
- [ ] **Step 2–4:** 失敗 → 實作 → 通過。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropGroups PeerDropKit/Tests/PeerDropGroupsTests
git commit -m "feat: GroupSocket 票券 WebSocket 與重連"
```

---

### Task 11: App 接線——`GroupStore`、推播、深層連結、`GROUP_MESSAGE`

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（持有 `groupStore`，仿 `diaryStore` 的建立與 `LiveNotesCryptoContext`／帳號簽章接法）
- Modify: `PeerDropKit/Sources/PeerDropCore/PushNotificationManager.swift`（`groupMessage`、`groupKeyRequest` 兩種 type 路由到 `GroupStore.handlePush`；`groupKeyRequest` 為靜默推播）
- Modify: `PeerDrop/App/AppDelegate.swift`（遠端推播 `didReceiveRemoteNotification` 內等待 `groupStore` 同步，沿用 diary 的逾時作法）
- Modify: `PeerDrop/App/PeerDropApp.swift`、Mac 的 `MacDeepLinkHandler.swift`（`GroupInviteLink.parse` → 暫存到 `groupStore.pendingInvite`，不開畫面）
- Modify: `PeerDrop/App/Localizable.xcstrings`（新增 key `GROUP_MESSAGE`，五語系：en「New message」、zh-Hant「有新訊息」、zh-Hans「有新消息」、ja「新着メッセージがあります」、ko「새 메시지가 있습니다」；ja／ko／zh-Hans 標 `needs_review`）
- Test: `PeerDropKit/Tests/PeerDropCoreTests/GroupPushRoutingTests.swift`、`PeerDropTests/GroupWiringTests.swift`

**Interfaces:**
- Consumes: `GroupStore.handlePush(kind:groupId:)`、`GroupInviteLink.parse`。
- Produces: `ConnectionManager.groupStore: GroupStore`、`GroupStore.pendingInvite: (groupId: String, code: String)?`（`@Published`）。

- [ ] **Step 1: 失敗測試**：推播 userInfo `{type:"groupMessage", groupId}` 與 `{type:"groupKeyRequest", groupId}` 被分派到 `GroupStore.handlePush`（以注入的 spy 驗證）；缺 groupId／型別未知 → 忽略不 crash；`peerdrop://group/<id>?code=<c>` 設定 `pendingInvite`，`peerdrop://diary/…` 不受影響；`xcstrings` 內 `GROUP_MESSAGE` 五語系皆有值且無重複 symbol（跑既有的 Localizable 檢查測試，若有）。
- [ ] **Step 2–4:** 失敗 → 實作 → 通過；`xcodegen generate`，iOS 全套 `xcodebuild test -scheme PeerDrop …` 全綠；Mac `xcodebuild build -scheme PeerDropMac …` 成功。
- [ ] **Step 5: Commit**
```bash
git add PeerDropKit/Sources/PeerDropCore PeerDrop/App PeerDropMac PeerDropKit/Tests/PeerDropCoreTests PeerDropTests project.yml
git commit -m "feat: 群組推播、深層連結與 GROUP_MESSAGE 字串接線"
```

---

### Task 12: 本機端對端驗證（控制者執行，不進 CI）

**Files:**
- Create: `PeerDropKit/Tests/PeerDropGroupsTests/GroupE2ETests.swift`（用環境變數 `GROUP_E2E_BASE_URL` 閘控，未設定即 `XCTSkip`）
- Create: `scripts/group-e2e.sh`（啟動 `wrangler dev --local`、套本機 D1 migrations、執行該測試、清理；環境細節參考 `.superpowers/sdd/2026-09-23-diary/task-7-env-notes.md`）

**Interfaces:**
- Consumes: 全部前述任務。

- [ ] **Step 1:** 寫測試情境（三個獨立 `GroupStore`，各自獨立 `rootDirectory`／身分／假裝置權杖）：A 建立 → B（帳號）以邀請碼加入並取得金鑰 → C（匿名，房設 `anonymousAllowed`）加入並送 identity → 三方互發訊息皆可解 → B 離線時 A 發言，B 補抓後可解 → A 踢 C 並輪換，C 解不開新訊息、B 可 → C 以被踢的裝置重加被拒（`.banned`）→ A 關房，B 仍可讀歷史。
- [ ] **Step 2:** 跑 `scripts/group-e2e.sh`，全過；失敗時回報並修（若暴露的是伺服器問題，開新的 Worker 修正任務，不在此任務順手改）。
- [ ] **Step 3: Commit**
```bash
git add PeerDropKit/Tests/PeerDropGroupsTests/GroupE2ETests.swift scripts/group-e2e.sh
git commit -m "test: 群組本機端對端驗證腳本"
```

---

## 完成條件與交接

- 12 個任務各有獨立審查，最後一次整條分支審查（最強模型）。Kit 全套僅允許既有失敗；iOS 全套綠；Mac 建置成功；Worker 466＋新測試綠、`tsc` 0 錯。
- 交接給使用者的實機驗證項目：兩台真機＋一台匿名裝置的真實加入／互發／踢人輪換、背景推播（`GROUP_MESSAGE` 文案）、第二台裝置接手（Ruling 12 於伺服器）後舊裝置看到的狀態。
- 之後：**G2**（介面）——主頁「群組」清單、聊天室畫面、設定頁、建立精靈、成員／檢舉／封鎖畫面、匿名選項、移除舊 P2P 群組聊天、隱私說明與年齡分級問卷更新、確認 Workers 付費方案。
