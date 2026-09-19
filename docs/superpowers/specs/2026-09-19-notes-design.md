# 子專案 2：傳紙條 — 設計規格

日期：2026-09-19
狀態：已實作（PR 待合併）；2026-09-19 核可後依程式碼實況補充 §3.1 儲存佈局、§3.2 PoW 訊息形式、§4.1 純函式金鑰介面；Task 12（全套驗證與本機 E2E）已完成，見下方各段「（實作 2026-09-19 調整）」註記
上位規格：`docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md` §3（傳紙條）、§8（上架影響）
前置：子專案 1（帳號地基，PR #147）——本規格以其實際結果為準：帳號 token 與 Mac 金鑰通道、`GET /v3/directory/:handle?bundle=1`、`AccountManager`、`PeerDropAccount` 模組、`WorkerURL`。

---

## 0. 目標與範圍

**目標**：註冊用戶輸入文字並以 ID 或暱稱指定收件者送出虛擬紙條；收件者收到通知後點開閱讀；可匿名發送；可刪除紙條；可封鎖寄件者與檢舉。iOS 與 Mac 同步。

**MVP 使用者故事**（上位規格 §0.1 紙條四則）＋ §8 送審前必要條件：
1. 發送：輸入文字並以 ID 或暱稱指定收件者。
2. 接收與查看：收到新紙條通知，點開閱讀。
3. 匿名：發送時可選「匿名發送」。
4. 刪除：收件者可刪除紙條。
5. 封鎖與檢舉（使用者決策 2026-09-19：**伺服器執行封鎖＋檢舉存檔**）：收件者可封鎖某張紙條的寄件者（含匿名），之後該寄件帳號送來的紙條在伺服器端靜默丟棄；可檢舉紙條，存入 D1 供 operator 檢視。

**非目標（後置）**：樣式自訂、多媒體附件、閱後即焚、群組紙條、檢舉自動限流、`diaryKey` 種類的實際使用（欄位保留給子專案 3）。

---

## 1. 現況與可重用（子專案 1 之後）

| 需要 | 現有 | 處置 |
|---|---|---|
| 收件者公鑰與信箱 | `GET /v3/directory/:handle?bundle=1` 回 `{accountId, nickname, identityKey, signingKey, mailboxId, preKeyBundle}`，`preKeyBundle` 形狀＝`FetchedPreKeyBundle`（含 `oneTimePreKey?`、v5.4 SPK 時戳） | 直接用；只在按下送出時才 `bundle=1`（避免瀏覽耗 OPK） |
| 一次性 X3DH | `X3DH.initiatorKeyAgreement(...) -> KeyAgreementResult{rootKey, chainKey}`；`responderKeyAgreement`；`PreKeyStore.consumeOneTimePreKey(id:)`、`currentSignedPreKey`；SPK 時戳驗證 `verifyBundleFreshness` | 用 `rootKey` 經 HKDF 衍生紙條金鑰（§2.1） |
| 帳號驗證 | `authorizeV3`（Bearer，或 Mac 金鑰通道＋`X-Device-Id`） | 紙條、收件匣、封鎖、檢舉、PoW 路由全部經 `authorizeV3` 且**允許金鑰通道**（否則 Mac 無法使用主功能）；子專案 1 的規則不變：只有改暱稱與刪帳號維持 Bearer-only。 |
| 推播 | `sendAPNs(deviceToken, payload, config, options)`、`selectApnsTopic(platform, env)`、KV `device:<deviceId>` 存 `{pushToken, platform}`、D1 `account_devices` | 對收件帳號的每台裝置扇出 |
| 推播處理（客戶端） | `PushNotificationManager.handleRemoteNotification` 只認 `roomCode` | 增加 `type == "note"` 分支 |
| PoW | `ProofOfWork`（客戶端，難度 16，已可背景執行）；worker `verifyPoW` 接受客戶端自供 challenge（弱） | 紙條改用伺服器發放 challenge（§3.4） |
| 加密落盤 | `ChatDataEncryptor`（含 `init(testKey:)`）、`PeerDropPersistence.scopedKey` | `NotesStore` 每則一檔 |
| UI 插槽 | iOS `ContentView` 三分頁；Mac `MacSidebarSection` 三段；`AccountSectionView` 模式 | 加「紙條」分頁／側邊欄段 |

---

## 2. 加密設計

### 2.1 NoteEnvelope（一次性 X3DH 信封）

```
NoteEnvelope (JSON；wire 上 base64)
  v               UInt8   = 1
  ephemeralKey    Data    -- 寄件者臨時 X25519 公鑰 EK_A（32 B；在 X3DH 中扮演身分金鑰，見下）
  ephemeralKey2   Data    -- 寄件者第二把臨時 X25519 公鑰 EK_A2（32 B；X3DH 的 ephemeral）
  spkId           UInt32  -- 收件者 signed pre-key id
  opkId           UInt32? -- 收件者 one-time pre-key id；缺 OPK 時依 SecurityPolicy.opkExhaustionBehavior 決定 fail-closed 或降級（沿用 X3DH 既有邏輯）
  nonce           Data    -- 12 B
  ciphertext      Data    -- AES-256-GCM(NotePlaintext JSON)，AAD = utf8(recipientAccountId) ‖ [v]
```

金鑰衍生：`X3DH.initiatorKeyAgreement(myIdentityKey: IK_A, myEphemeralKey: EK_A, theirIdentityKey, theirSignedPreKey, theirOneTimePreKey, peerVersion: .v54, policy:)` → `rootKey`；`noteKey = HKDF<SHA256>(ikm: rootKey, salt: 空, info: utf8("peerdrop-note-v1"), 32 B)`。`chainKey` 丟棄。收件端本應以 `responderKeyAgreement(myIdentityKey:mySignedPreKey:myOneTimePreKey:theirIdentityKey:theirEphemeralKey:)` 解開，但**匿名紙條收件端不知道寄件者的身分公鑰**。因此信封的 X3DH 改為「寄件端用臨時金鑰扮演身分金鑰」：`myIdentityKey = EK_A`（另一把臨時金鑰 EK_A2 當 ephemeral）。即寄件端產生兩把臨時 X25519 金鑰，信封放 `ephemeralKey`（= EK_A，當 IK 用）與 `ephemeralKey2`（= EK_A2）。收件端呼叫 `responderKeyAgreement(theirIdentityKey: ephemeralKey, theirEphemeralKey: ephemeralKey2, ...)`。這保留既有 X3DH 實作與 OPK 前向保密，並讓署名版與匿名版走同一條路徑；寄件者真實身分只出現在密文內層。

```
NotePlaintext (JSON)
  kind        "note" | "diaryKey" | "system"    -- MVP 只用 note；其餘保留
  text        String                            -- ≤ 2,000 Unicode scalars
  sentAt      Int (unix seconds)
  sender      { accountId, nickname?, signingKey (b64), signature (b64) }?   -- 匿名時省略
```

署名版：`signature = Ed25519(IdentityKeyManager.sign)` 對 `sha256(utf8("peerdrop-note-sender-v1") ‖ utf8(text) ‖ sentAt(8 B big-endian) ‖ utf8(recipientAccountId))`。收件端：以 `sender.accountId` 查目錄取得 `signingKey`，與內層 `signingKey` 相同且簽章驗證通過 → 顯示暱稱與 ID；不同或失敗 → 顯示「無法驗證的寄件者」並仍可閱讀。目錄結果快取 24 小時（`DirectoryCache`）。

匿名版：`sender` 省略。伺服器仍以帳號 token 知道寄件帳號 → `senderHash`（§3.1），永不回傳收件者。

### 2.2 為何不用 Double Ratchet
紙條彼此獨立、無會話狀態、收件端不需辨識寄件者即可解密（匿名必要）。每張紙條消耗一把 OPK（前向保密），OPK 耗盡時依既有政策。

---

## 3. 伺服器

### 3.1 資料模型

**Durable Object `AccountInbox`**（每帳號一個，名稱 = `accountId`；wrangler `[[migrations]] tag = "v4" new_sqlite_classes = ["AccountInbox"]`，binding `ACCOUNT_INBOX`）

儲存採 DO storage 的 key/value API（與既有 `PreKeyStore`／`DeviceInbox` 相同，不用 `storage.sql`），每則兩把 key，讓「列舉／分頁／上限檢查」只讀小的 meta，不載入信封：

```
meta:<ulid>  → { id, kind: "note"|"diaryKey"|"system", senderHash, createdAt, readAt: null|Int, expiresAt }   -- 約 150 B
item:<ulid>  → envelope（base64 字串，≤ 16 KB）
```
- `id` 為 ULID（時間有序，26 字元 Crockford base32），`meta:` 依 key 升冪列舉即依時間排序；分頁用 `list({ prefix: "meta:", startAfter: "meta:" + after, limit })`。
- `senderHash = hex(HMAC-SHA256(TOKEN_SECRET, "note-sender:" + senderAccountId))`。
- 保留上限每帳號 1,000 則：超過時刪最舊的已讀項目（meta+item 兩把 key），若無已讀則拒收（`inbox_full` 507）。
- `expiresAt = createdAt + 90 天`；第一次 PUT 時若無 alarm 則 `setAlarm(下一個 03:00 UTC)`；`alarm()` 刪 `expiresAt < now` 的項目並重排下一天。

**D1（`ACCOUNTS_DB`，migration `0002_notes.sql`）**
```sql
CREATE TABLE IF NOT EXISTS blocks (
  account_id   TEXT NOT NULL,     -- 封鎖者
  sender_hash  TEXT NOT NULL,     -- 被封鎖的寄件帳號雜湊
  created_at   INTEGER NOT NULL,
  PRIMARY KEY (account_id, sender_hash)
);
CREATE TABLE IF NOT EXISTS reports (
  id                  TEXT PRIMARY KEY,  -- ULID
  reporter_account_id TEXT NOT NULL,
  sender_hash         TEXT NOT NULL,
  inbox_item_id       TEXT NOT NULL,
  reason              TEXT NOT NULL,     -- spam | harassment | other
  excerpt             TEXT NULL,         -- 檢舉者同意附上的解密內容，≤ 1,000 字
  created_at          INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS reports_sender ON reports(sender_hash, created_at);
```
`senderHash` 不可逆（HMAC 以 `TOKEN_SECRET` 為鍵），operator 要對應回帳號需另以 D1 對 `accounts` 逐一計算——刻意不建反查表。

### 3.2 路由（全部 `authorizeV3`；金鑰通道允許）

| 路由 | 說明 |
|---|---|
| `GET /v3/pow/challenge` | 回 `{challenge}`（32 B，base64）；KV `pow:<accountId>:<challenge>` TTL 300 秒、單次。每帳號每分鐘 60 次（KV `pow-quota:<accountId>:<minute>`）。 |
| `POST /v3/notes/:recipientAccountId` | body `{envelope, pow: {challenge, nonce}}`；`envelope` = NoteEnvelope JSON 的 base64；驗 challenge 存在→刪（單次）；PoW 訊息 `M = utf8(challenge ‖ "|" ‖ recipientAccountId ‖ "|" ‖ hex(sha256(envelopeBytes)))`，驗 `sha256(M ‖ nonce(8 B big-endian))` 前 16 bit 為零（伺服器沿用既有 `verifyPoW(M, nonce, 16)`，客戶端沿用 `ProofOfWork.generate(challenge: M)`）；`recipientAccountId` 正規化後須存在；`envelope` 解碼 ≤ 16 KB 且能解析為 `{v:1, ephemeralKey, ephemeralKey2, spkId, opkId?, nonce, ciphertext}`（四個 Data 欄位為 base64，長度 32/32/12/≥16）；配額：先扣每寄件者每日 200 則（KV `note-quota:s:<accountId>:<day>`）→ 429 `rate_limited`；**封鎖檢查**：`blocks(recipientAccountId, senderHash)` 存在 → 回 `201 {id: <新 ULID>}` 靜默丟棄（不扣收件者配額）；否則再扣每收件者每日 500 則（KV `note-quota:r:<accountId>:<day>`）→ 429 `rate_limited`；然後 DO PUT；成功後推播（§3.3，失敗只記 log）。回 `201 {id}`。錯誤：404 `recipient_not_found`、400 `bad_pow`／`invalid_envelope`／`missing_fields`、413 `too_large`、507 `inbox_full`。（實作 2026-09-19 調整：封鎖檢查原本排在兩個配額扣除之後，改為排在收件者配額之前——寄件者配額仍先扣（作為濫發成本），但一則會被封鎖靜默丟棄的紙條不該再消耗收件者的每日配額。） |
| `GET /v3/inbox?after=<id>&limit=50` | 依 `id` 升冪回 `{items:[{id, kind, envelope, createdAt, readAt}], nextAfter?}`；不含 `sender_hash`。`after` 格式錯誤 → 400 `invalid_cursor`；AccountInbox DO 呼叫失敗（非 2xx）→ 502 `inbox_error`（實作 2026-09-19 調整：規格原未列，補上避免呑掉 DO 層錯誤）。 |
| `POST /v3/inbox/:id/read` | 標記已讀；冪等。 |
| `DELETE /v3/inbox/:id` | 刪除；冪等（不存在也 204）。 |
| `POST /v3/inbox/:id/block` | 讀取該項目的 `sender_hash` → `INSERT OR IGNORE blocks`；回 `{blocked: sender_hash}`；項目本身不刪（由客戶端決定）。 |
| `GET /v3/blocks` | `[{senderHash, createdAt}]`。 |
| `DELETE /v3/blocks/:senderHash` | 解除封鎖。 |
| `POST /v3/inbox/:id/report` | body `{reason, excerpt?}`；`reason ∈ spam|harassment|other`；`excerpt` ≤ 1,000 字（客戶端在對話框讓使用者選擇是否附上解密內容）；寫 `reports`；回 `201 {id}`。每帳號每日 20 次。 |
| `GET /v3/admin/reports?since=<ts>&limit=100` | `ANALYTICS_KEY`（既有 `requireKey`）；在主 fetch 進入一般 `/v3/` 帳號驗證之前攔截；operator 檢視。 |

寄件者的 `senderHash` 由 `authorizeV3` 的 `accountId` 計算，與內層署名無關（匿名也能封）。

### 3.3 推播扇出
`POST /v3/notes` 成功後：查 D1 `account_devices WHERE account_id = recipient` → 對每台裝置讀 KV `device:<deviceId>` → 有 `pushToken` 者 `sendAPNs(token, {alert: {"loc-key": "NOTE_RECEIVED"}, sound: "default", customData: {type: "note", inboxItemId: id}}, config, {topicOverride: selectApnsTopic(platform, env)})`。失敗只記 log，不影響回應。無任何裝置有 token 或 `APNS_KEY_P8` 未設 → 只入匣（下次前景拉取）。扇出邏輯抽成 `fanOutNotePush(env, recipientAccountId, itemId, deps: { send, topicFor })`，測試以假的 `send` 斷言每台裝置各一次、topic 依平台；回應不透露收件者裝置數。客戶端字串目錄提供 `NOTE_RECEIVED` 五語（「你收到一張紙條」等）。（實作 2026-09-19 調整：`fanOutNotePush` 整個函式包一層 `try/catch`，D1／KV 查詢本身失敗也只記 log 並回傳 `{attempted: 0}`，絕不拋出——規格原僅說「單台裝置推播失敗只記 log」，實作把「查詢裝置清單」這一步也納入同樣的容錯範圍，因為紙條已寫入收件匣，扇出整體失敗不該讓寄件者收到錯誤。）

### 3.4 PoW
沿用客戶端 `ProofOfWork`（難度 16，已在背景執行），但 challenge 由伺服器發放（§3.2）。舊的 `/v2/messages` PoW 不動。

### 3.5 測試
- DO 層：PUT/GET 分頁/read/delete/上限 1,000 與 507/alarm 過期清理。
- 路由：PoW 正確與錯誤、單次 challenge、封鎖靜默丟棄（回 201 但 GET inbox 看不到）、配額 429、`too_large`、`recipient_not_found`、金鑰通道可送可收、report 寫入與 admin 讀取、blocks 列表與解除。
- 推播：`sendAPNs` 以 `vi.mock` 替換，斷言對每台已註冊 push token 的裝置各呼叫一次、topic 依平台。

---

## 4. 客戶端

### 4.1 模組 `PeerDropKit/Sources/PeerDropNotes`（依賴 Account、Security、Transport、Platform）

```
NoteEnvelope.swift     struct NoteEnvelope: Codable { v, ephemeralKey, ephemeralKey2, spkId, opkId?, nonce, ciphertext }
NotePlaintext.swift    struct NotePlaintext: Codable { kind, text, sentAt, sender: NoteSender? }; struct NoteSender { accountId, nickname?, signingKey, signature }
NoteCrypto.swift       enum NoteCrypto {   // 純函式，不碰 keychain／單例，跑背景；金鑰全部由呼叫端傳入，讓 swift test 不需 keychain
                         static func seal(text:, recipient: DirectoryEntry /* 須含 preKeyBundle */, signer: NoteSigner?, policy: SecurityPolicy, now: Date) throws -> NoteEnvelope
                         static func open(_ env: NoteEnvelope, recipientAccountId:, keys: NoteRecipientKeys) throws -> NotePlaintext }
                       struct NoteSigner { accountId: AccountID; nickname: String?; signingPublicKey: Data; sign: (Data) throws -> Data }
                       struct NoteRecipientKeys { identityKey: Curve25519.KeyAgreement.PrivateKey; signedPreKey: (UInt32) throws -> SignedPreKey?; oneTimePreKey: (UInt32) throws -> OneTimePreKey? }
                       // seal 先驗 SPK 簽章（recipient.signingKey）與 X3DH.verifyBundleFreshness；ciphertext 欄位 = AES-GCM ciphertext ‖ tag（nonce 另存）
NoteProofOfWork.swift  static func message(challenge: Data, recipientAccountId: String, envelopeBytes: Data) -> String; static func solve(...) async -> UInt64?   // 用既有 ProofOfWork.generate(challenge:) async 版本，訊息形式見 §3.2
NotesClient.swift      actor NotesClient {   // 包一個 AccountClient，重用其 request 管線（401 重試、錯誤映射）；AccountClient.request 由 private 改 public powChallenge(); send(to:, envelope:, pow:) -> String; inbox(after:, limit:) -> [InboxItemDTO]; markRead(id:); delete(id:); block(itemId:) -> String; blocks(); unblock(senderHash:); report(itemId:, reason:, excerpt:) }
                       // 與 AccountClient 同模式（authProvider / tokenInvalidator / 401 重試 / 錯誤映射）
NoteRecord.swift       struct NoteRecord: Codable { id: String; direction: .inbound|.outbound; text: String? /* nil = 無法解密 */; sentAt; sender: NoteSenderState (.anonymous | .verified(accountId, nickname) | .unverified(accountId)); recipientAccountId?; readAt?; receivedAt }
NotesStore.swift       @MainActor final class NotesStore: ObservableObject {
                         @Published inbox: [NoteRecord]; @Published sent: [NoteRecord]; @Published unreadCount; @Published lastError
                         init(client:, accountManager:, crypto: NotesCryptoContext /* identityKey / signedPreKey / oneTimePreKey / signer；正式版包 IdentityKeyManager.shared + ConnectionManager.preKeyStore */, storage: NotesStorage)
                         func sync() async          // GET inbox?after=最大 id → 逐則 open → 驗簽（目錄快取）→ 落盤 → 發布
                         func send(text:, to handle: String, anonymous: Bool) async throws -> NoteRecord   // 目錄 bundle=1 → seal → pow → send → sent 落盤
                         func markRead(_:) async; func delete(_:) async; func block(_:) async throws; func report(_:, reason:, includeText:) async throws }
                       // （實作 2026-09-19 調整）sync() 的游標處理比規格描述更保守：`after` 送給伺服器分頁用的是本次迴圈當下的 `nextAfter`（可能跨好幾頁），但存進 `NotesStorage` 的「已同步到哪」游標（`lastPersistedId`）只在該筆記錄實際成功落盤後才前進；某一頁中途落盤失敗（例如毒檔或磁碟錯誤）不會讓游標跳過那筆——下次 sync() 還會重新拉到它。
                       // （實作 2026-09-19 調整）report(_:reason:includeText:) 在呼叫 NotesClient 之前，於用戶端把 `record.text` 截到 `maxExcerptScalars`（1,000 Unicode scalars，對齊伺服器 `NOTE_LIMITS.excerptMaxChars`），而不是整段原文送給伺服器再由伺服器截——避免明知超長仍把多餘明文送出網路。
NotesStorage.swift     每則一檔 Documents/Notes/inbox/<id>.enc、Documents/Notes/sent/<id>.enc（ChatDataEncryptor，可注入 testKey）；索引由目錄列舉＋檔內 sentAt 排序；毒檔記錄 lastError 並略過
DirectoryCache.swift   accountId → (signingKey, nickname, fetchedAt)，24 h TTL，經 AccountManager.lookup
```

- 正式版 `NotesCryptoContext` 取 SPK/OPK 私鑰：`PreKeyStore.signedPreKey(for:)`、`PreKeyStore.consumeOneTimePreKey(id:)`（消耗後不可再解同一信封——這是設計，重複拉取的信封以本機快取為準）；SPK 以 `spkId` 取（`PreKeyStore` 保留最近 3 把輪換前的 SPK）。
- 解密失敗（OPK 已消耗、SPK 不存在）：`NoteRecord.text = nil`，UI 顯示「無法解密」，可刪除。

### 4.2 推播
- Worker payload `{type:"note", inboxItemId}`；`PushNotificationManager.handleRemoteNotification` 新增分支：`userInfo["type"] as? String == "note"` → `NotificationCenter.post(.didReceiveNotePush)`；`ConnectionManager` 持有 `notesStore`（lazy）並在收到通知或 `.active` 時 `Task { await notesStore.sync() }`。
- iOS：`UNUserNotificationCenter` 點擊 → 切到紙條分頁並開啟該 id（`ContentView` 讀 `pendingNoteID`）。Mac：`MacAppDelegate` 同樣轉發，`.macSidebarJump(.notes)`。

### 4.3 UI（共用 `PeerDrop/UI/Notes/`，無 UIKit）
- **分頁**：iOS `ContentView` → 紙條（`envelope.fill`，宣告在第一個位置、`tag(3)`，既有 0/1/2 不動；預設選取 3）、附近、已連線、圖書館；Mac `MacSidebarSection.notes` 置頂，⌘⌥1 → 紙條、2 附近、3 圖書館、4 Relay。
- `NotesInboxView`：清單（未讀點、寄件者列＝暱稱＋ID／「匿名」／「無法驗證」、首行預覽、相對時間），下拉重新整理，空狀態「還沒有紙條。把你的 ID 給朋友吧」＋複製 ID；帳號 `state != .ready` 時顯示 `AccountSectionView` 的狀態卡（不隱藏分頁）。
- `NoteDetailView`：全文、寄件者、時間；工具列：刪除、封鎖寄件者（確認對話框；匿名也可）、檢舉（reason 選單＋「附上紙條內容給審核」開關）。
- `ComposeNoteView`：收件者欄位（輸入 ID 或暱稱）、文字區（2,000 字計數）、「匿名發送」開關（預設關，開啟時提示「對方不會看到你的 ID」）、送出（PoW 在背景，顯示進度）。（實作 2026-09-19 調整：沒有做即時目錄查詢與確認 chip——`canSend` 只檢查兩個欄位非空與字數 ≤ 上限；實際的目錄查詢／找不到收件者發生在按下送出之後，經 `store.send()` 內部呼叫 `AccountManager.lookup`，失敗時顯示 `NotesStoreError` 對應的行內錯誤文字（例如「找不到這個 ID 或暱稱」），而不是打字時就顯示確認 chip。送出中的按鈕文字沿用既有 `Sending...`／`Send`，不是逐步 PoW 進度。）
- `SentNotesView`：寄件備份清單（本機）。
- 設定頁：「封鎖清單」（`GET /v3/blocks`，可解除；只顯示雜湊前 8 碼與封鎖時間，因為伺服器不回傳身分）。

### 4.4 字串
約 30 個鍵五語（分頁名「紙條」、空狀態、匿名、封鎖、檢舉理由、錯誤文案、`NOTE_RECEIVED`）。（實作 2026-09-19 調整：送出中的按鈕文字沿用既有鍵 `"Sending..."`（聊天附件上傳已在用），沒有新增 `ComposeNoteSending` 之類的重複鍵——符合 Global Constraints「新增前先檢查鍵是否已存在」。）

---

## 5. 測試
- **worker**：§3.5。
- **NoteCrypto**：seal→open 往返（署名／匿名）、AAD 錯誤（收件者不符）失敗、OPK 缺席依政策、竄改密文失敗、簽章驗證（正確／金鑰不符／訊息竄改）；金鑰全由測試建構注入（不碰 keychain）。凍結向量加入 `CryptoTestKit` 延後到 PR 合併後、送審前。
- **NotesClient**：`TestURLProtocol` 路徑與錯誤映射。
- **NotesStore**：以 `ChatDataEncryptor(testKey:)` 落盤往返、毒檔略過、sync 去重（相同 id 不重複）、send 全流程（目錄→seal→pow→send→sent）。
- **UI**：截圖模式 `mockNotes`（三則：署名、匿名、無法驗證），fastlane 截圖加 `NotesInbox`、`ComposeNote` 兩畫面（iOS 與 Mac）—— fastlane 截圖本身列在 Task 12 範圍外（見計畫「後續」段），screenshot-mode 煙霧測試已於 Task 12 用 `-SCREENSHOT_MODE` 手動驗證通過（見下）。
- **CI**（實作 2026-09-19 調整）：`RelayPushKindTests`（`PeerDropCoreTests`）納入 `.github/workflows/ci.yml` 與 Task 12 驗證矩陣的 `swift test --filter` 清單，與 `PeerDropAccountTests|PeerDropTransportTests|PeerDropNotesTests` 並列，確保 note push 分類邏輯持續被 CI 覆蓋。
- **E2E**：Task 12（2026-09-19）以 `wrangler dev`（本機 D1/KV/DO）+ Mac dev build（Apple Development 簽章）跑完整自寄流程並全部通過：署名紙條送達＋未讀點亮＋開啟後清除、匿名紙條寄件者顯示「匿名」、封鎖寄件者後再自寄靜默丟棄（伺服器回 201 但收件匣不出現）、解除封鎖後恢復送達、檢舉一則並附上內容後 `GET /v3/admin/reports` 可見明文 excerpt。過程中發現並修正一個 Mac 端 UI 缺陷（`MacSettingsView` 的 Settings 視窗固定高度 420pt，未隨 Task 11 新增的「封鎖清單」區塊調整，導致該區塊完全不可見/不可互動；修成 620pt）。screenshot-mode 煙霧測試（三則 mock 紙條 + 一則已寄出＋⌘⌥1–4 切換）另行驗證通過。兩台裝置（iPhone ↔ Mac）互寄仍如原規劃，留待合併後、送審前用實體 iPhone 補做。

---

## 6. 上架與合規
- Guideline 1.2（UGC）：封鎖、檢舉、以及 operator 檢視管道皆具備；檢舉附上內容需使用者主動勾選（E2E 內容否則伺服器不可見）。
- 隱私標籤：紙條內容伺服器不可讀（E2E）。「Messages」是否列為「收集」依 Apple 定義：資料經伺服器但開發者無法讀取 → 可列為未收集；`senderHash`、封鎖與檢舉記錄連結到帳號 ID（已在子專案 1 宣告「使用者 ID」）。Operator 送審前確認。
- 商店文案與截圖：紙條成為主打，更新五語描述與 What's New。

---

## 7. 風險
| 風險 | 處置 |
|---|---|
| OPK 池被目錄 `bundle=1` 抽乾（每帳號 30/min） | 客戶端 `uploadPreKeysIfNeeded` 已在 25 把以下補充；`bundle=1` 只在送出時呼叫；後續可加每收件者每日上限 |
| 信封一次性：重複拉取同一 id 無法二次解密 | 本機快取為準；`sync` 以 id 去重 |
| 推播 `loc-key` 需要 App 端字串 | 五語加入 `NOTE_RECEIVED`；缺時 iOS 顯示 key 本身（可接受） |
| 金鑰通道（Mac）可代任何裝置送紙條 | 配額以帳號計；封鎖以 senderHash；與子專案 1 記錄的已知弱點相同，DeviceCheck 後續 |
| `X3DH` 用臨時金鑰當 IK（§2.1） | 與既有實作相容；安全性等同於「匿名 X3DH」（無寄件者身分認證，身分改由內層簽章提供） |
| 封鎖清單回傳穩定的 senderHash，收件者可把署名紙條的雜湊對照到匿名紙條而推斷寄件者 | MVP 接受，後續可改為伺服器只回傳不透明 block id |
