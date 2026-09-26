# 產品轉向：傳紙條 ＋ 交換日記 — 整體架構設計

日期：2026-09-14
狀態：已核可（使用者 2026-09-14），作為四個子專案的上位規格
產品目標（本規格的上位決策準繩）：`docs/product/product-goals.md`
相關：`docs/plans/2026-08-11-mainactor-offload-design.md`、`docs/security/threat-model-relay.md`、`docs/plans/2026-07-05-remaining-work-roadmap.md`

---

## 0. 決策摘要

| 項目 | 決策 |
|---|---|
| 寵物養成（Neo-Egg / PeerDropPet） | **完全移除**：模組、UI、Widget、素材、Scripts、CI 徽章；首次啟動清本機與 iCloud KVS 殘留 |
| 新主體 | **傳紙條**（主分頁 1）＋ **交換日記**（主分頁 2） |
| 既有 P2P 功能（附近探索、傳檔、聊天、語音通話） | **保留為次要功能**，不移除、不封閉 |
| 身分模型 | **混合**：首次啟動自動建立伺服器端匿名帳號（免 Email），可選唯一暱稱供搜尋；Apple ID 綁定與換機還原留後續 |
| 內容加密 | **端對端**：伺服器只存密文，只看得到路由與事件型別 |
| 後端路線 | **A：帳號層 ＋ 伺服器密文日誌**（Cloudflare Worker + D1 + Durable Objects） |
| MVP 範圍 | 紙條核心四故事 ＋ 日記核心四故事；所有進階故事後置 |
| 平台 | **iOS 與 macOS 同步**推出 |
| CI | 補一個 xcodebuild 建置 job（納入子專案 0） |

### 0.1 使用者故事（MVP）

**傳紙條**
1. 發送：輸入文字並以 ID 或暱稱指定收件者。
2. 接收與查看：收件者收到新紙條通知，點開閱讀。
3. 匿名：發送時可選「匿名發送」，收件者看不到寄件者身分。
4. 刪除：收件者可刪除已讀或不需要的紙條。

**交換日記**
1. 建立／加入：建立日記本，透過邀請碼或連結邀請好友加入。
2. 輪流書寫：持有者完成並「傳給下一人」後，系統才開放下一人寫作權限並通知。
3. 瀏覽歷史：以時間軸或翻頁瀏覽所有成員寫過的內容。
4. 留言與回應：在任一篇日記下留言或按讚。

### 0.2 後置故事（不在 MVP，但設計預留落點）

紙條樣式自訂、多媒體附件、閱後即焚；日記催稿通知、多媒體與心情天氣、時空膠囊回顧、成員與封面管理。每項的預留落點在對應章節標註「（後置）」。

**例外**：黑名單與檢舉原列進階，但 App Store Guideline 1.2 對匿名 UGC 要求封鎖與檢舉機制，故改為子專案 2 的送審前必要條件（最小實作），見第 8 節。

---

## 1. 現況與可重用資產

探索結果（2026-09-14，三份唯讀審查）：

**可直接重用**
- App Attest → HMAC Bearer 裝置 token 管線（`cloudflare-worker/src/deviceToken.ts`、`appAttest.ts`、`/v2/device/{challenge,attest,assert}`）。`TokenPayload.scope` 欄位已存在，目前恆為 `"default"`。
- X3DH（`PeerDropSecurity/Protocol/X3DH.swift`）、pre-key 分發（`PreKeyStore` DO + `/v2/keys/*`）、`OutboundRetryQueue`。
- 「推播只帶通知、機密走驗證通道」模式（`/v2/invite`）、`selectApnsTopic` 每平台 topic。
- iOS `ContentView` TabView 插槽、Mac `MacSidebarSection` enum + `MacDetailRouter`、`ScreenshotModeProvider` 假資料注入、五語系 String Catalog。
- worker vitest + miniflare 測試框架；Swift `CryptoTestKit` 凍結向量；`FileStore.namespace` 隔離。

**必須新建**
- 帳號層：伺服器零帳號、零暱稱、零目錄；`mailboxId` 是可輪換的隨機值；`TrustedContact.userId` 是從未寫入的佔位欄位。
- 持久收件匣：`DeviceInbox` DO 送達即刪、上限 20、無已讀狀態；`GET /v2/messages` 是破壞性讀取。
- 信箱推播：只有 `/v2/invite` 與 `/v2/call` 發 APNs；信箱靠前景 30 秒輪詢，背景停止。
- 密封寄件者：`RemoteMessageEnvelope` 的 `senderIdentityKey`、`senderMailboxId`、`senderDisplayName` 都是明文。
- 多人共寫儲存：無 D1、無 R2；`DeviceGroup` 只是本機 UserDefaults 標籤加即時扇出，無群組金鑰。

**順手修的既有漏洞**
- `isRequestAuthorized` 從不比對 token 的 `deviceId` 與路徑 `:deviceId`，任何有效 token 可開他人 inbox WebSocket。新路由全部做擁有權綁定，並回頭補 `/v2/inbox/:deviceId`。
- PoW 的 challenge 由客戶端自供、可無限重放（worker 端已有伺服器發放版本在 worktree 分支，尚未併入；本設計的新路由直接採伺服器發放 challenge）。
- `/v2/messages`、`/v2/keys/register` 無 body 大小上限。

---

## 2. 帳號與暱稱目錄

### 2.1 資料模型

```
Account
  accountId      TEXT PK   -- 伺服器核發，8 碼 Crockford base32，顯示為 XXXX-XXXX，不可輪換
  identityKey    BLOB UNIQUE -- Curve25519 KeyAgreement 公鑰（既有 IdentityKeyManager.publicKey）
  signingKey     BLOB UNIQUE -- Ed25519 簽章公鑰（既有 IdentityKeyManager.signingPublicKey）
  nickname       TEXT UNIQUE NULL COLLATE NOCASE -- 3–20 字，Unicode 字母數字與 _ ，不分大小寫
  mailboxId      TEXT      -- 目前 pre-key 信箱（可輪換，帳號不變）
  createdAt      INTEGER
  updatedAt      INTEGER

AccountDevice
  accountId      TEXT FK
  deviceId       TEXT      -- 既有 DeviceIdentity.deviceId（App Attest 綁定）
  platform       TEXT      -- ios | macos
  PRIMARY KEY (accountId, deviceId)
```

儲存於 Cloudflare **D1**（新 binding `ACCOUNTS_DB`）。暱稱唯一性由 UNIQUE 約束搶佔，改名時舊名立即釋放。

### 2.2 註冊與綁定

1. 客戶端已持有裝置 Bearer token（App Attest 流程不變）。
2. `POST /v3/account/challenge` → 伺服器發 32 位元組 nonce（KV，5 分鐘，單次使用）。
3. `POST /v3/account/register`，body：`{deviceId, platform, identityKey, signingKey, mailboxId, mailboxToken, nonce, signature}`（子專案 1 實作結果，2026-09-15 更新）；`mailboxToken` 證明信箱所有權；`signature` = 以身分簽章私鑰（`IdentityKeyManager.sign`）對 `"peerdrop-account-v2" ‖ nonce ‖ utf8(deviceId) ‖ sha256(identityKey ‖ utf8(mailboxId))` 的 Ed25519 簽章。Mac 走專用金鑰通道（見子專案 1 規格 §7 註記）。
   - `signingKey` 已存在 → 視為「新裝置加入既有帳號」，寫入 `AccountDevice`，回同一 `accountId`。這是多裝置與日後換機的基礎，但 MVP 客戶端無金鑰備份，因此實際上仍是單裝置。
   - 不存在 → 建新帳號。
4. 回應 `{accountId, nickname?, token}`，其中 `token` 是新的 Bearer，`scope = "account:<accountId>"`，15 分鐘 TTL，用既有 `/v2/device/assert` 續期時一併帶出 account scope。

### 2.3 授權規則

- 所有 `/v3/*` 路由要求 `scope == "account:<id>"`。
- 路徑中含 `:accountId` 者，必須等於 token 的帳號；不等即 403。
- `/v2/inbox/:deviceId` 補上 `token.deviceId == :deviceId` 檢查（既有漏洞）。

### 2.4 暱稱與目錄

| 路由 | 說明 |
|---|---|
| `PUT /v3/account/nickname` | 設定或清除暱稱；衝突回 409 `nickname_taken`。每帳號每日最多 5 次。 |
| `GET /v3/directory/:handle` | `handle` 為 accountId（含或不含連字號）或暱稱。回 `{accountId, nickname, identityKey, mailboxId, preKeyBundle}`。`preKeyBundle` 由既有 `PreKeyStore` DO 取出並消耗一把 OPK。每帳號每分鐘 30 次。 |

**隱私**：目錄查詢需要帳號 token，故不存在匿名列舉。不提供模糊搜尋，只有精確比對。

### 2.5 客戶端

- 新模組 `PeerDropAccount`：`AccountManager`（註冊、續期、暱稱）、`DirectoryClient`、`AccountStore`（accountId 與暱稱以既有 `ChatDataEncryptor` 落盤）。
- 引導流程新增一頁：自動建立帳號並顯示 ID，可選填暱稱。已裝機使用者於首次進入新版本時在背景註冊，失敗則於紙條／日記分頁顯示「帳號尚未就緒」而非隱藏（依 2.1(b) 拒審教訓）。
- `TrustedContact.userId` 改名為 `accountId` 並開始寫入；`petSnapshot` 欄位移除（`decodeIfPresent`，讀舊檔相容）。

### 2.6 非目標（MVP）

- 換機還原、Apple ID 綁定、金鑰備份。規格明寫：換機即新帳號，舊帳號的紙條與日記不可取回。此限制須在引導頁與設定頁揭露。

---

## 3. 傳紙條

### 3.1 加密：一次性 X3DH 信封（NoteEnvelope）

紙條彼此獨立，不建立 Double Ratchet session，避免收件者需要先辨識寄件者才能找 session（匿名時做不到）。

```
NoteEnvelope (JSON, base64 於 wire)
  v                 UInt8     = 1
  ephemeralKey      Data      -- 寄件者臨時 Curve25519 公鑰
  spkId             UInt32    -- 使用的 signed pre-key
  opkId             UInt32?   -- 使用的 one-time pre-key（缺 OPK 時依既有 SecurityPolicy 決定 fail-closed 或降級）
  ciphertext        Data      -- AES-256-GCM，nonce 12 B 前置

NotePlaintext (JSON)
  kind              "note" | "diaryKey" | "system"
  text              String                 -- ≤ 2,000 字
  sentAt            Int (unix seconds)
  sender            { accountId, nickname?, signingKey, signature }?  -- 匿名時省略
  style             (後置) { background, font, envelope }
  attachments       (後置) [ { type, blobId, key } ]
  burnAfterSeconds  (後置) Int?
```

- 金鑰衍生：`X3DH.initiatorKeyAgreement` 既有實作，info 字串改為 `"peerdrop-note-v1"` 以與 session 金鑰域分離。
- 署名版：`sender.signature` = 以寄件者身分私鑰對 `ciphertext` 前的 `sha256(text || sentAt || recipientAccountId)` 的簽章；收件者查目錄取得 `signingKey` 驗證後才顯示暱稱與 ID，驗證失敗顯示為「無法驗證的寄件者」。
- 匿名版：`sender` 整段省略。**伺服器仍知道寄件帳號**（送出需帳號 token），保存 `senderHash = HMAC(TOKEN_SECRET, senderAccountId)` 於收件匣項目，永不回傳給收件者。這是後置「黑名單／檢舉」的基礎。
- 收件匣不經過既有 `handleRemoteMessage` 的首次聯絡同意閘，紙條有自己的收件流程。

### 3.2 伺服器：`AccountInbox` Durable Object

每帳號一個，DO 名稱 = `accountId`，使用 SQLite storage。

```
InboxItem
  id           TEXT PK  -- ULID，時間有序
  kind         TEXT     -- note | diaryKey | system
  envelope     BLOB     -- NoteEnvelope（≤ 16 KB）
  senderHash   TEXT     -- 見 3.1；署名版也存，方便同一邏輯
  createdAt    INTEGER
  readAt       INTEGER NULL
  expiresAt    INTEGER  -- 預設 90 天；（後置）閱後即焚由客戶端讀後呼叫 DELETE
```

保留上限每帳號 1,000 則，超過刪最舊已讀項目；DO alarm 每日清 `expiresAt` 過期項目。

| 路由 | 授權 | 說明 |
|---|---|---|
| `POST /v3/notes/:recipientAccountId` | 帳號 token ＋ 伺服器發放 PoW challenge | body `{envelope}`；每寄件者每日 200 則、每收件者每日 500 則；body ≤ 16 KB。成功後對收件者所有 `AccountDevice` 發 APNs alert：`{title: "PeerDrop", body: "你收到一張紙條"}`（在地化由 `loc-key` 處理），custom `{type: "note", inboxItemId}`，**不帶內容**。 |
| `GET /v3/inbox?after=<id>&limit=50` | 帳號 token | 非破壞性、游標分頁、依 `id` 升冪。 |
| `POST /v3/inbox/:id/read` | 帳號 token | 標記已讀。 |
| `DELETE /v3/inbox/:id` | 帳號 token | 逐則刪除。 |
| `GET /v3/pow/challenge` | 帳號 token | 發放 32 位元組 challenge，5 分鐘單次使用；PoW = `sha256(challenge || recipientAccountId || sha256(envelope))` 前 16 bit 為零。 |

### 3.3 客戶端

- 新模組 `PeerDropNotes`：`NoteEnvelope` 編解碼與加解密（純函式、`Sendable`，跑背景）、`NotesClient`（HTTP）、`NotesStore`（`@MainActor`，收件匣快取以每則一檔 `Documents/Notes/inbox/<id>.enc` 落盤，避免整檔重寫）、`NotesPushHandler`。
- 推播到達：alert 顯示，點擊或前景進入分頁時呼叫 `GET /v3/inbox?after=`。Mac 亦同（`MacAppDelegate` 轉發）。
- 寫紙條：收件者欄位輸入 ID 或暱稱 → 目錄查詢 → 顯示對方暱稱與 ID 供確認 → 送出。匿名開關在送出列。
- 寄件備份：本機保存已送出紙條（明文以 `ChatDataEncryptor` 落盤），不上傳。

---

## 4. 交換日記

### 4.1 伺服器：`DiaryRoom` Durable Object

每本日記一個，DO 名稱 = `diaryId`（ULID）。伺服器仲裁「誰、何時、哪種事件」，內容一律密文。

```
DiaryMeta
  diaryId        TEXT
  ownerAccountId TEXT
  metaCipher     BLOB      -- 名稱、封面（以 diaryKey 加密）
  members        [accountId]   -- 有序，即輪流順序
  holderIndex    INTEGER   -- 目前持有者在 members 的索引
  seq            INTEGER   -- 最後事件序號
  inviteCode     TEXT      -- 8 碼，可由 owner 重設
  state          "open" | "closed"
  keyEpoch       INTEGER   -- （後置）成員移除時輪換

DiaryEvent (append-only)
  seq            INTEGER PK    -- 伺服器指派
  eventId        TEXT UNIQUE   -- 客戶端產生的 ULID，作為冪等鍵與 AAD
  type           entry | comment | like | pass | join | meta
  authorAccountId TEXT
  refSeq         INTEGER NULL  -- comment/like 指向的 entry seq
  payloadCipher  BLOB NULL     -- entry/comment/meta 的內容密文（≤ 64 KB）；like/pass/join 為 NULL
  createdAt      INTEGER
```

**仲裁規則（伺服器強制）**
- `entry`、`pass`：只有 `members[holderIndex]` 可發。`pass` 後 `holderIndex = (holderIndex + 1) % members.count`，對新持有者推播 `{type: "diaryTurn", diaryId}`。
- `comment`、`like`：任何成員。`like` 同一人同一 `refSeq` 只計一次（DO 內去重）。
- `join`：憑 `inviteCode` 進入；加入者附加到 `members` 末端，事件記錄後對所有成員推播 `{type: "diaryJoin", diaryId, accountId}`。
- `meta`：只有 owner。（後置）成員管理與關閉亦在此。
- 每本日記成員上限 12 人；事件保存無上限，但 `payloadCipher` 總量每本 64 MB。

| 路由 | 說明 |
|---|---|
| `POST /v3/diaries` | 建立；body `{metaCipher}`；回 `{diaryId, inviteCode}`。 |
| `POST /v3/diaries/:id/join` | body `{inviteCode}`。 |
| `GET /v3/diaries/:id` | meta（需成員）。 |
| `GET /v3/diaries/:id/events?since=<seq>&limit=100` | 分頁拉取。 |
| `POST /v3/diaries/:id/events` | body `{eventId, type, refSeq?, payloadCipher?}`；依規則 403；重複 `eventId` 回既有 `seq`（冪等，供重送）。 |
| `GET /v3/diaries` | 我參與的日記清單（D1 索引表 `DiaryMembership(accountId, diaryId)`）。 |

### 4.2 金鑰分發

- `diaryKey`：創建者產生的 32 位元組對稱金鑰，所有 `payloadCipher` 與 `metaCipher` 以 AES-256-GCM 加密，AAD = `diaryId || authorAccountId || eventId`（`eventId` 由客戶端在加密前產生，伺服器指派 `seq` 時不影響 AAD；meta 用 `diaryId || "meta" || keyEpoch`）。
- **邀請連結**：`peerdrop://diary/<diaryId>?code=<inviteCode>#k=<base64url diaryKey>`。fragment 不會送到伺服器；客戶端解析後直接持有金鑰。
- **短邀請碼**：加入者只憑碼 join，此時尚無金鑰。伺服器推播 `diaryJoin` 給現有成員；任一在線成員客戶端自動以 3.1 的信封（`kind = "diaryKey"`）把金鑰寄進加入者的 `AccountInbox`。重複寄送無害（加入者取第一份）。加入者在拿到金鑰前，日記顯示「等待成員授予金鑰」狀態。
- 金鑰以 `ChatDataEncryptor` 落盤於 `Documents/Diary/<diaryId>/key.enc`。

### 4.3 客戶端

- 新模組 `PeerDropDiary`：`DiaryCrypto`（純函式）、`DiaryClient`、`DiaryStore`（`@MainActor`）、`DiaryEventLog`（每本日記一個只增寫的加密檔 `Documents/Diary/<diaryId>/events.log`，每筆事件獨立加密框架，讀取時依 `seq` 建索引；不採整檔重寫）。
- 同步：進入日記時 `since = 本機最大 seq`；推播 `diaryTurn`／`diaryJoin` 觸發拉取。
- UI：日記清單 → 日記本（時間軸為預設，翻頁模式為切換）→ 篇目下方留言與按讚 → 持有者看到「書寫」與「傳給下一人」。非持有者看到「目前由 <暱稱> 持有」。
- （後置）催稿＝一個 `system` 紙條；時空膠囊＝客戶端依本機事件日誌計算；成員管理＝`meta` 事件加 `keyEpoch` 輪換。

---

## 5. 客戶端整體架構

### 5.1 模組

```
PeerDropKit/Sources/
  PeerDropAccount/   AccountManager, DirectoryClient, AccountStore
  PeerDropNotes/     NoteEnvelope, NotesClient, NotesStore, NotesPushHandler
  PeerDropDiary/     DiaryCrypto, DiaryClient, DiaryStore, DiaryEventLog
```

- 三者只依賴 `PeerDropSecurity`、`PeerDropTransport`、`PeerDropPlatform`；`PeerDropCore` 依賴三者（供 `ConnectionManager` 觸發推播處理與 `ScreenshotModeProvider` 假資料）。
- 加解密、編解碼、檔案 IO 一律 `nonisolated`／背景執行，Store 只持有 `@Published` 狀態（沿用 MainActor 卸載設計）。
- 錯誤路徑不得 `try?` 靜默吞：持久化失敗要浮現到 Store 的 `lastError` 並在 UI 顯示。

### 5.2 UI 骨架

- iOS `ContentView` TabView：**紙條、日記、附近、已連線、圖書館**（五個，不觸發「更多」）。寵物 tab 移除。
- Mac `MacSidebarSection`：`notes, diaries, nearby, trusted, relay`；`PeerDropCommands` 快捷鍵 ⌘⌥1–5。
- 共用視圖：`PeerDrop/UI/Notes/*`、`PeerDrop/UI/Diary/*`，不得引入 UIKit／AppKit（`lint-imports` 會擋）；平台差異走 `PlatformColors`、`Image(platformImage:)`。
- 設定頁：新增「帳號」段（ID、暱稱、複製 ID）。
- 引導：現有 5 頁改寫為以紙條與日記為主的 4 頁，加帳號頁。
- 五語系字串以手動方式加入 `Localizable.xcstrings`；`ScreenshotModeProvider` 新增 `mockNotes`、`mockDiaries`。

### 5.3 資料落盤

```
Documents/
  Account/account.enc
  Notes/inbox/<ulid>.enc      Notes/sent/<ulid>.enc
  Diary/<diaryId>/key.enc     Diary/<diaryId>/events.log   Diary/<diaryId>/meta.enc
```

全部經 `ChatDataEncryptor`（沿用 ThisDeviceOnly 限制，見 2.6）。

---

## 6. 子專案拆解與順序

| # | 子專案 | 產出 | 依賴 |
|---|---|---|---|
| 0 | 寵物移除 | 刪 `PeerDropPet` 模組與測試、`PeerDrop/Pet/UI`、`PetSectionView`、`PeerDropWidget` target 整個移除（含 entitlements、profile、`NSSupportsLiveActivities`、app group）、14 支 Scripts、`asset-coverage-badge.yml` 與 `badges` 分支、README 徽章、10 個字串、`ScreenshotModeProvider.mockPetState`、`ChatManager`/`ConnectionManager` 三個 pet callback、`TrustedContact.petSnapshot`、ZIPFoundation 相依；首次啟動清 `Documents/PetData`、app group 檔案、iCloud KVS `pet_id/pet_level/pet_exp`、ubiquity container `PetData`、5 個 UserDefaults key；`ci.yml` 的 `lint-imports` 路徑修正；**新增 CI xcodebuild job**（iOS + Mac 建置）；fastlane Snapfile 拿掉 pet 測試；`docs/pet-design/`（177 MB）移出 repo。 | 無 |
| 1 | 帳號地基 | worker：D1 schema 與 migration、`/v3/account/*`、`/v3/directory/*`、`/v3/pow/challenge`、account scope 與擁有權綁定（含 `/v2/inbox` 修補）；client：`PeerDropAccount`、引導帳號頁、設定帳號段、`TrustedContact.accountId`。 | 0（建置乾淨） |
| 2 | 紙條 | worker：`AccountInbox` DO、`/v3/notes`、`/v3/inbox/*`、APNs 扇出；client：`PeerDropNotes`、紙條分頁（iOS + Mac）、推播處理。 | 1 |
| 3 | 日記 | worker：`DiaryRoom` DO、`/v3/diaries/*`、`DiaryMembership`；client：`PeerDropDiary`、日記分頁（iOS + Mac）、金鑰分發。 | 2（`diaryKey` 走紙條信封與收件匣） |

每個子專案：獨立規格（0 可直接進計畫）、獨立實作計畫、獨立 PR、可獨立上線。版本號：子專案 0 完成即 iOS 6.0.0／Mac 6.1.0（寵物移除是使用者可見的破壞性變更）；1–3 依序 6.1／6.2／6.3。

---

## 7. 測試策略

- **worker**：每條 `/v3` 路由一組 vitest（授權、擁有權綁定、配額、大小上限）；`AccountInbox` 與 `DiaryRoom` 的仲裁規則各自有 DO 層測試（持有者限制、like 去重、join 附加順序、alarm 清理）。沿用 `scripts/run-tests.sh` 的路徑含空白 workaround。
- **加密**：`NoteEnvelope` 與 `DiaryCrypto` 在 `CryptoTestKit` 加凍結向量（署名／匿名各一組、AAD 錯誤必須失敗），並納入既有 fuzz nightly。
- **Store**：以 `FileStore.namespace` 隔離，覆蓋毒檔、部分寫入、重啟後索引重建。
- **UI**：`ScreenshotModeProvider` 假資料驅動 fastlane 截圖（iOS 與 Mac 各 5 語系）；既有 UI 測試改為紙條／日記畫面。
- **端到端**：兩台實機（或 iPhone + Mac）走一次「查目錄 → 寄紙條 → 推播 → 讀 → 刪」與「建日記 → 連結加入 → 碼加入取金鑰 → 寫 → 傳 → 留言」。
- **CI**：子專案 0 新增 `xcodebuild build` job（iOS Simulator + macOS），阻擋「出貨物 ≠ repo」類回歸。

---

## 8. 上架與合規影響

- App 隱私標籤：從「不收集資料」改為收集「使用者 ID」與「使用者名稱」（暱稱），連結到使用者身分，用途為 App 功能。iOS 與 Mac 兩個 ASC 記錄都要更新，Privacy Manifest 同步。
- 匿名紙條屬使用者生成內容：Guideline 1.2 要求有封鎖與檢舉機制。MVP 未含，但伺服器端已保存 `senderHash`，子專案 2 送審前至少要提供「檢舉」入口（可為送出到 `/debug/report` 類的最小實作）與「封鎖」（客戶端過濾＋伺服器拒收）。**此項列為子專案 2 的送審前必要條件，而非後置。**
- 年齡分級：訊息與 UGC 已勾選，維持 4+ 需保留檢舉封鎖。
- 商店文案與截圖全面改寫；`release_notes.txt` 目前內容全是寵物在地化，須重寫。

---

## 9. 風險與未決事項

| 風險 | 處置 |
|---|---|
| 換機即失去帳號（ThisDeviceOnly 金鑰） | MVP 明示揭露；下一階段做 Apple ID 綁定＋金鑰備份。 |
| 短邀請碼加入後無成員在線，金鑰遲遲不到 | UI 顯示等待狀態並可重送 join 推播；建議 UI 主推連結分享。 |
| D1 是新 binding，worker 部署為 push-to-main 自動部署 | migration 走 `wrangler d1 migrations`，先在 PR 的 preview 環境驗證；`/v3` 路由對舊客戶端不可見，不影響線上。 |
| 帳號 token 與裝置 token 並存增加授權面 | 統一在 `isRequestAuthorized` 擴充，並以 `auth.spec.ts` 契約測試鎖定。 |
| 寵物移除是破壞性變更 | 版本號主版跳升；商店文案說明；首次啟動一次性清理並記 UserDefaults flag 避免重複。 |
