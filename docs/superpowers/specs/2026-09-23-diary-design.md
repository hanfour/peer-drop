# 子專案 3：交換日記 — 設計規格

日期：2026-09-23
狀態：v3 定案（2026-09-23）— 第一輪（grok-review-1.md）與第二輪（grok-review-2.md，8 項）意見全部採納；第三輪 grok 確認因餘額用盡中斷，改由主廚逐條核對後定案
上位規格：`docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md` §4、§5.2、§5.3
前置：子專案 1（帳號，#147）、子專案 2（紙條，#148）已併入 main 並部署。本規格以其實際程式碼為準（`authorizeV3`、`AccountInbox`、`POST /v3/notes`、`NoteEnvelope`／`NoteCrypto`／`NotesStore`、`AccountClient.request`、`RelayPushKind`、D1 `reports`）。

---

## 0. 目標、範圍、定案

**目標**：多人共用一本端對端加密的交換日記：建立者邀請好友加入，成員依加入順序輪流書寫，寫完「傳給下一人」；所有成員可瀏覽歷史、留言、按讚；iOS 與 Mac 各自是完整客戶端。

**MVP 使用者故事**：
1. 建立／加入：建立日記本；以**邀請連結**（含金鑰）或**短邀請碼**加入。
2. 輪流書寫：只有持有者能寫與「傳給下一人」；建立者可對非自己的持有者執行「跳過」。一個回合可寫任意篇（含零篇即傳）。
3. 瀏覽歷史：時間軸（預設）與翻頁模式。
4. 留言與按讚：任一篇下留言、按讚（同人同篇一次）。

**產品定案（2026-09-23）**：邀請＝連結＋短碼；卡住輪次＝持有者傳遞＋建立者跳過（不看時間）；不可編輯刪除；推播四種（輪到我、新日記、新成員、留言與讚）。

**設計定案（2026-09-23，grok 第一輪）**：
- `diaryId` 由**客戶端**產生（ULID），金鑰先落盤再 `POST /v3/diaries`；建立冪等。
- `since` 不含該序號；`meta.seq` 從 0 起，第一筆事件 seq = 1；所有 `POST /events` 成功（新建 201／冪等 200）都回 `{seq, holderIndex}`。
- `POST /events` 只收 `entry|comment|like|pass|skip`；`join`／`leave` 走專用路由；`meta` 只在建立時寫入，無 `meta` 事件型別。
- 短碼金鑰補發由**成員端 sync 看到 `join` 事件**驅動（推播只是叫人 sync）；金鑰只有通過 `openMeta(metaCipher)` 才安裝。
- `request-key` 送**靜默** `diaryKeyRequest`，不是 `DIARY_JOIN`。
- 「iOS 與 Mac 同步」的意思是兩端都是完整客戶端；同一帳號第二台裝置不在 MVP（無金鑰備份，一裝置一帳號）。
- 新增 owner 專用 `close`（把既有 `state` 做成煞車）；不做踢人、不做金鑰輪換（`keyEpoch` 固定 1）。
- 拿掉：`lastPassAt`、`meta` 事件、`keyEpoch` 輪換分支、邀請 QR、事件日誌索引落盤、時間軸的 pass/skip/join/leave 專用版面、清單即時解析 20 個暱稱。

**上限**：每帳號參與 ≤ 20 本（create 與 join 都檢查，409 `diary_limit`）；每本成員 ≤ 12（409 `diary_full_members`）；日記 ≤ 5,000 Unicode scalars、留言 ≤ 500（客戶端限制，`DiaryCrypto.open` 超過即丟棄該筆）；`payloadCipher` 解碼後 ≤ 64 KB（raw body ≤ 96 KB）；每本 `bytesUsed` ≤ 64 MB（507 `diary_full`；冪等重送不計入、仍回 200）。

**非目標（後置）**：催稿、多媒體／心情天氣、時空膠囊、成員管理與封面、金鑰輪換、編輯／刪除（墓碑事件）、同帳號多裝置。

---

## 1. 可重用與需改的既有介面

| 需要 | 現有 | 處置 |
|---|---|---|
| 帳號驗證 | `authorizeV3`（Bearer／Mac 金鑰通道） | 日記全部路由允許金鑰通道 |
| 推播扇出 | `fanOutNotePush(env, recipientAccountId, itemId, deps)`（`notes.ts:90`，payload 寫死） | 抽成 `fanOutPush(env, accountId, payload: PushPayload, deps)`；紙條呼叫端顯式傳原本的 alert 與 `{type:"note", inboxItemId}`；既有 `NOTE_RECEIVED` 測試不變 |
| 靜默推播 | `sendAPNs` 寫死 `apns-push-type: alert`、無 priority（`apns.ts:87-91`） | `APNsOptions` 加 `pushType: "alert"\|"background"`；background 分支 `contentAvailable`、無 alert／sound、`apns-priority: 5` |
| 金鑰補發信封 | `POST /v3/notes/:id`（無 `kind`，永遠 PoW）、`NoteCrypto.seal` 寫死 `.note`、`NotesClient.send` 無 `kind` | body 加 `kind?: "note"\|"diaryKey"`、`diaryId?`；`NoteCrypto.seal(kind:)`；`NotesClient.send(..., kind:, diaryId:)`；見 §3.3 |
| 收件匣分流 | `NotesStore.decode` 把所有明文當紙條 | `plaintext.kind == .diaryKey` → 注入的 `diaryKeyHandler` closure（Notes 不 import Diary）；游標規則見 §3.4 |
| 錯誤碼 | `AccountClientError.forbidden`／`.http(507)` 不帶 body 代碼（`AccountClient.swift:213-224`） | `.forbidden(String)`、507 → `.http(507)` 改為帶代碼的 `.insufficientStorage(String)`；`NotesStore.mapNetwork` 對應調整；`DiaryStore` 自己映射 |
| 推播分類 | `RelayPushKind` 只認 `note`／`roomCode` | 加 `.diary(kind:diaryId:seq:)` 與 `.diaryKey`；`handleRemoteNotification` 在 `roomCode` 之前分流 |
| 深連結 | iOS `PeerDropApp.swift` host switch、Mac `MacDeepLinkHandler.swift`（會把整個 URL 以 public 記 log） | 加 `host == "diary"` 分支；Mac 的 log 改記 scheme＋host，禁止記 query／fragment |
| HTTP 管線 | `AccountClient.request` | `DiaryClient` 包一個 `AccountClient` |
| 加密落盤 | `ChatDataEncryptor`；注意 `decrypt` 魔數不符會回傳原文 | 事件日誌用長度前綴框架，逐筆解密 |
| 檢舉 | D1 `reports`（`sender_hash`、`inbox_item_id` NOT NULL） | `0003_diary.sql` 重建 `reports`：兩欄改可空，加 `diary_id`、`diary_seq` |
| 暱稱 | `DirectoryCache`（目錄 30/min） | 清單只顯示帳號 ID；進入該本才查持有者暱稱，失敗顯示 ID |
| UI 插槽 | iOS 紙條 `tag(3)` 排第一、附近 0、已連線 1、圖書館 2；Mac `notes, nearby, trusted, relay` | 日記 `tag(4)` 插在紙條之後；Mac `diaries` 插在 `notes` 後；⌘⌥1–5 = Notes、Diaries、Nearby、Library、Relay |

---

## 2. 伺服器

### 2.1 `DiaryRoom` Durable Object

每本一個，名稱 = `diaryId`（客戶端 ULID）。key/value 儲存（同 `AccountInbox`）：

```
meta → { diaryId, ownerAccountId, members: [accountId] /* 有序＝輪流順序 */, holderIndex, seq, inviteCode, state: "open"|"closed", keyEpoch: 1, metaCipher, createdAt, bytesUsed }
ev:<seq 補零 12 碼> → { seq, eventId, type, authorAccountId, refSeq?, payloadCipher?, createdAt, skipped? }
like:<refSeq>:<accountId> → 1
eid:<eventId> → seq
```

型別：`entry`、`comment`、`like`、`pass`、`skip`、`join`、`leave`。`authorAccountId` 一律取自 `authorizeV3`。

**建立**：`POST /v3/diaries {diaryId, metaCipher}`。`diaryId` 須為 26 碼 ULID。建立路由是唯一不先查 D1 就可 `idFromName` 的路由；先檢查 20 本上限（D1 COUNT），再在 DO 內**原子初始化**：meta 不存在 → 寫初值 `{ownerAccountId: caller, members: [caller], holderIndex: 0, seq: 0, state: "open", keyEpoch: 1, bytesUsed: 0, inviteCode: 伺服器只產生一次（8 碼、`ACCOUNT_ID_ALPHABET`）, metaCipher}`；已存在且 owner 是 caller → 不覆蓋 `metaCipher` 與 `inviteCode`（冪等）；已存在且 owner 不同 → 409 `diary_exists`。DO 成功後 D1 `INSERT OR IGNORE diary_members(caller, diaryId)` 與 `diary_invites(inviteCode, diaryId)`，**都成功才回** 201（新建）／200（冪等）`{diaryId, inviteCode}`；D1 失敗回 500，客戶端用同一個 `diaryId` 重送。其他所有路由在 `idFromName` 之前先確認 D1 `diary_invites`／`diary_members` 有該 `diary_id`，否則 404 `not_found`（避免任意 id 建出空 DO）。

**`POST /events` 檢查表**（其餘型別 400 `bad_type`）：

| type | payloadCipher | refSeq | 誰 |
|---|---|---|---|
| entry | 必填，解碼後 ≤ 64 KB | 禁止 | 持有者 |
| comment | 必填，≤ 64 KB | 必填，指向既有 entry | 任何成員 |
| like | 禁止 | 必填，指向既有 entry | 任何成員；同人同篇第二次回既有 seq |
| pass | 禁止 | 禁止 | 持有者 |
| skip | 禁止 | 禁止 | owner，且 `members.length ≥ 2`，且 `members[holderIndex] != owner`（否則 403 `skip_self`）；`skipped` 由伺服器寫入當下持有者 |

- 違規：403 `not_member`／`not_holder`／`not_owner`／`skip_self`／`diary_closed`；400 `bad_ref`／`bad_type`／`bad_payload`；413 `too_large`；507 `diary_full`。
- `pass`／`skip` 成功：`holderIndex = (holderIndex + 1) % members.length`。
- 冪等：`eid:<eventId>` 存在 → 回 200 `{seq, holderIndex}`，不再前進索引、不計 `bytesUsed`。
- `bytesUsed` 只在新 seq 成立時加上 `payloadCipher` 解碼長度；達 64 MB 拒收新事件 507，冪等重送仍 200。

**join**：兩條入口，行為相同：`POST /v3/diaries/:id/join {inviteCode}`（連結）與 `POST /v3/diaries/join {inviteCode}`（只憑短碼；以 D1 `diary_invites` 找 `diaryId`，找不到 → 403 `bad_code`）。碼先 `normalizeAccountId`；錯碼以帳號級 `diary-join-fail:<accountId>:<yyyyMMddHH>` 每小時 ≤ 10 次（超過 429）。`state == "closed"` → 403 `diary_closed`；成員 ≥ 12 → 409 `diary_full_members`；呼叫者參與 ≥ 20 本 → 409 `diary_limit`。新成員：append、寫 `join` 事件（無 payload）；**已是成員仍執行** D1 `INSERT OR IGNORE`（修補上次 D1 失敗），成功才回 200／201。回應 `{diaryId, members, holderIndex, ownerAccountId, state, seq, metaCipher}`。推播 `diaryJoin` 只在本次真正新增成員時送給其他成員。

**leave**：`POST /v3/diaries/:id/leave`，closed 之後仍可呼叫。呼叫者是成員時：設 `idx` 為其索引，先移除；空了 → 只設 `state = "closed"`、寫 `leave` 事件，**不讀 `members[0]`**；否則：`idx == holderIndex` → `holderIndex = idx % members.length`；`idx < holderIndex` → `holderIndex -= 1`；離開者是 owner → `ownerAccountId = members[0]`（轉移在移除之後）；寫 `leave` 事件。呼叫者已不是成員時不改 DO。兩種情況都執行 D1 delete，成功後回 204。

**close**：`POST /v3/diaries/:id/close`，owner 專用；`state = "closed"` 後**只**拒絕 join 與 `POST /events`（403 `diary_closed`）；成員仍可讀、可 leave。

### 2.2 D1（migration `0003_diary.sql`）

```sql
CREATE TABLE IF NOT EXISTS diary_members (
  account_id TEXT NOT NULL,
  diary_id   TEXT NOT NULL,
  joined_at  INTEGER NOT NULL,
  PRIMARY KEY (account_id, diary_id)
);
CREATE INDEX IF NOT EXISTS diary_members_diary ON diary_members(diary_id);
CREATE TABLE IF NOT EXISTS diary_invites (
  invite_code TEXT PRIMARY KEY,
  diary_id    TEXT NOT NULL
);
-- reports: sender_hash / inbox_item_id 改為可空，加 diary_id / diary_seq（SQLite 需重建）
CREATE TABLE reports_new (
  id TEXT PRIMARY KEY,
  reporter_account_id TEXT NOT NULL,
  sender_hash TEXT NULL,
  inbox_item_id TEXT NULL,
  diary_id TEXT NULL,
  diary_seq INTEGER NULL,
  reason TEXT NOT NULL,
  excerpt TEXT NULL,
  created_at INTEGER NOT NULL
);
INSERT INTO reports_new (id, reporter_account_id, sender_hash, inbox_item_id, reason, excerpt, created_at)
  SELECT id, reporter_account_id, sender_hash, inbox_item_id, reason, excerpt, created_at FROM reports;
DROP TABLE reports;
ALTER TABLE reports_new RENAME TO reports;
CREATE INDEX IF NOT EXISTS reports_sender ON reports(sender_hash, created_at);
```
（只用整行 `--` 註解、字面值內無分號，遷就 `__tests__/d1.ts` 的拆句器。）`diary_members` 是清單索引、`diary_invites` 是短碼 → 日記的索引（建立與 reset 在回 2xx 前寫入，reset 先刪舊碼再寫新碼），成員與邀請碼的真相在 DO；所有寫入 DO 後的 D1 寫入**必須成功才回 2xx**，失敗回 500 讓客戶端重試（DO 端操作皆冪等）。

### 2.3 路由（全部 `authorizeV3`，金鑰通道允許；在 `handleV3` 的 404 前呼叫 `handleDiaryRoute`，不屬於自己回 `null`）

| 路由 | 說明 |
|---|---|
| `POST /v3/diaries` | `{diaryId, metaCipher}` → 201／200 `{diaryId, inviteCode}` |
| `GET /v3/diaries` | D1 → `[{diaryId, joinedAt}]` |
| `GET /v3/diaries/:id` | 現任成員限定 → `{diaryId, ownerAccountId, members, holderIndex, seq, state, keyEpoch, metaCipher, inviteCode?}`（`inviteCode` 只給 owner）——**輪次真相來源** |
| `POST /v3/diaries/:id/join`、`POST /v3/diaries/join` | 見 §2.1（第二條只憑短碼） |
| `POST /v3/diaries/:id/leave` | 204 |
| `POST /v3/diaries/:id/close` | owner → 204 |
| `POST /v3/diaries/:id/invite/reset` | owner → `{inviteCode}`；D1 先刪舊碼再寫新碼 |
| `GET /v3/diaries/:id/events?since=&limit=100` | 現任成員限定（否則 403 `not_member`）；`{events, nextSince?}`；`list({prefix:"ev:", startAfter:"ev:"+pad12(since), limit})` |
| `POST /v3/diaries/:id/events` | `{eventId, type, refSeq?, payloadCipher?}` → 201／200 `{seq, holderIndex}`；成功後推播 §4 |
| `POST /v3/diaries/:id/request-key` | 現任成員限定（非成員 403 且不推播）；`diary-keyreq:<accountId>:<diaryId>:<yyyyMMddHH>` ≤ 6；對其他成員送靜默 `diaryKeyRequest` |
| `POST /v3/diaries/:id/events/:seq/report` | 現任成員限定；`{reason, excerpt?}`；寫 `reports(diary_id, diary_seq, sender_hash = senderHash(作者))`；配額鍵與紙條共用 `report-quota:<accountId>:<day>`（20/日） |
| `GET /v3/admin/reports` | 既有；SELECT 帶出 `diary_id`、`diary_seq` |

Wrangler：`[[durable_objects.bindings]] name = "DIARY_ROOM" class_name = "DiaryRoom"`、`[[migrations]] tag = "v5" new_sqlite_classes = ["DiaryRoom"]`；`Env.DIARY_ROOM`；`index.ts` 末尾 `export { DiaryRoom }`；`__tests__/env.d.ts` 加 binding。

---

## 3. 金鑰與加密

### 3.1 內容加密
- `diaryKey`：32 B，建立者 `SymmetricKey(size: .bits256)`；`keyEpoch` 固定 1。
- 明文 JSON `DiaryPayload {kind: "entry"|"comment", text}`；meta 明文 `{name}`。
- AES-256-GCM；AAD = `utf8(diaryId) ‖ utf8(authorAccountId) ‖ utf8(eventId)`；meta 的 AAD = `utf8(diaryId) ‖ utf8("meta") ‖ keyEpoch(UInt32 BE)`。`payloadCipher` = nonce(12) ‖ ciphertext ‖ tag(16)，base64。
- `eventId` = 客戶端 ULID（`notes.ts` 字母表），加密前產生，重送不變。
- `DiaryCrypto.open` 對超過 5,000（entry）／500（comment）scalars 的明文丟棄該筆（`.oversized`），UI 顯示「內容無法顯示」。

### 3.2 邀請連結
`peerdrop://diary/<diaryId>?code=<inviteCode>#k=<base64url diaryKey>`。`host == "diary"`、id 在 path、code 在 query、k 在 fragment；fragment 不進伺服器。App：先 join（回應含 `metaCipher`、成員名單、`holderIndex`、`seq`），**先把 meta 與名單落盤**，再以該金鑰 `openMeta(metaCipher)`，成功才寫 `key.enc`；失敗留在「等待金鑰」狀態並可接受之後的合法補發。UI 提示「連結含金鑰，只傳給要邀請的人」。**任何 log 不得含 query／fragment。**

### 3.3 短碼與金鑰補發
1. 新成員以碼 join；伺服器推播 `diaryJoin` 給其他成員（可見通知）。
2. 成員端 `DiaryStore.sync(diaryId)` 看到尚未補發的 `join` 事件，且本機持有能解開 `metaCipher` 的金鑰 → `DiaryKeyRelay`：目錄 `bundle=1` 取新成員金鑰 → `NoteCrypto.seal(kind: .diaryKey, text: JSON {diaryId, keyEpoch: 1, key(b64)}, signer: 必須署名)` → PoW → `POST /v3/notes/<newMember> {envelope, pow, kind: "diaryKey", diaryId}`。
3. 伺服器對 `kind == "diaryKey"`：`diaryId` 必填；查該 DO，**寄件者與收件者都必須是成員**否則 403 `not_member`（真實回應，不走封鎖假 201）；`AccountInbox` 項目 `kind = "diaryKey"`；推播改靜默 `{type:"diaryKey"}`（background、priority 5）。
4. 去重鍵 `(diaryId, newMember)` 只在 POST 真正 201 後寫入，24 小時內不再寄；失敗下次 sync 再試。**由 `diaryKeyRequest` 推播觸發的補發忽略去重**（對方明確再要一次）。
5. 新成員端收到靜默推播 → `NotesStore.sync()`（不是 `DiaryStore.sync`）→ `decode` 看到 `plaintext.kind == .diaryKey`：該本日記尚未在本機（meta／名單未落盤）→ 視為暫態，見 §3.4；匿名信封直接丟；`verifySender`（目錄簽章公鑰）且 `sender.accountId ∈ 本機已落盤的該本成員名單`；`openMeta(本機 metaCipher)` 成功才寫 `key.enc`（atomic），失敗丟棄該封、等下一封。
6. 每份補發消耗新成員一把 OPK；去重後每個有金鑰的裝置對每個新成員每天最多一把。

### 3.4 `NotesStore` 對 `diaryKey` 項目的游標規則
- 匿名、驗章失敗、`openMeta` 失敗、或**名單已落盤且** sender 不在其中：`DELETE /v3/inbox/:id`，推進游標，不安裝。
- 暫態失敗（該本日記尚未在本機、名單未知、磁碟、`DiaryStore` 尚未就緒）：不刪項目、不推進游標，並**中止這一輪** inbox 同步（游標是單一高水位，不能讓後面的紙條先落盤而跳過這封）。
- 成功：先寫 `key.enc`，再 `DELETE /v3/inbox/:id`，再推進游標。不建立 `NoteRecord`。

### 3.5 落盤
`Documents/Diary/<diaryId>/{key.enc, meta.enc, events.log, pending.enc}`、清單 `Documents/Diary/index.enc`，全部 `ChatDataEncryptor`。`events.log` 框架 = `UInt32 BE 長度 ‖ ChatDataEncryptor.encrypt(單筆 JSON)`；載入時逐框架解密建 seq→event 索引（記憶體，同 seq 以檔案後者為準），解密失敗或解出非 JSON 則跳過該長度；長度不合法或超出剩餘檔案時**把檔案截斷到最後一個完整框架**（伺服器是真相來源、尾端無法復原；實作 2026-09-23 調整，原文為保留尾端）並回報；IO 在 `nonisolated` 執行、日誌型別為 `Sendable`（載入結果以回傳值帶出，不用可變屬性）。

---

## 4. 推播

由 DO 回傳的成員清單決定收件者，worker 以 `fanOutPush` 對每位收件者每台裝置送：

| 觸發 | 收件者 | payload | 形式 |
|---|---|---|---|
| `pass`／`skip` | 新持有者 | `{type:"diaryTurn", diaryId}` | alert `DIARY_TURN` |
| `entry` | 其他成員 | `{type:"diaryEntry", diaryId, seq}` | alert `DIARY_ENTRY` |
| `join`（非冪等） | 其他成員 | `{type:"diaryJoin", diaryId, accountId}` | alert `DIARY_JOIN` |
| `comment`／`like` | 該篇 entry 作者（非自己） | `{type:"diaryReaction", diaryId, seq: entry 的 refSeq}` | alert `DIARY_REACTION` |
| `request-key` | 其他成員 | `{type:"diaryKeyRequest", diaryId, accountId}` | 靜默 |
| `diaryKey` 紙條 | 新成員 | `{type:"diaryKey"}` | 靜默 |

客戶端：`RelayPushKind.classify` 加 `.diary(kind, diaryId, seq?)`、`.diaryKey`；`handleRemoteNotification` 在 `roomCode` 判斷前分流：diary → `DiaryStore.sync(diaryId)`（`diaryKeyRequest` 額外觸發 `DiaryKeyRelay`）；`diaryKey` → `NotesStore.sync()`；iOS `fetchCompletionHandler` 等 sync 結束再呼叫。點擊通知 → `selectedTab = 4`／Mac `.diaries` 並開該本，有 `seq` 則捲到該篇。

---

## 5. 客戶端

### 5.1 模組 `PeerDropKit/Sources/PeerDropDiary`（依賴 Security、Transport、Account、Notes；`PeerDropCore` 依賴 Diary）

```
DiaryModels.swift    DiaryMeta, DiaryEvent{seq,eventId,type,authorAccountId,refSeq?,payload: DiaryPayload?,createdAt,skipped?}, DiaryPayload{kind,text}, DiaryEventType, DiarySummary, DiaryError
DiaryCrypto.swift    seal(payload:key:diaryId:authorAccountId:eventId:) -> Data; open(_:key:diaryId:authorAccountId:eventId:) throws -> DiaryPayload; sealMeta/openMeta(…keyEpoch:)   // 純函式
DiaryClient.swift    actor DiaryClient(account: AccountClient) { create(diaryId:metaCipher:), list(), get(id), join(id:code:), leave(id), close(id), resetInvite(id), events(id:since:limit:), postEvent(id:eventId:type:refSeq:payloadCipher:) -> (seq, holderIndex), requestKey(id), report(id:seq:reason:excerpt:) }
DiaryKeyStore.swift  key.enc 讀寫（atomic）
DiaryEventLog.swift  append(event)/all()/maxSeq；框架格式見 §3.5
DiaryKeyRelay.swift  由 join 事件驅動；去重 24h（只在 201 後）
DiaryStore.swift     @MainActor：diaries; open(id) -> DiaryState{meta, events, isHolder, isOwner, hasKey, pendingKey}; sync(id); create(name:); join(url:|code:diaryId:); leave; close; writeEntry(text:); pass(); skip(); comment(seq:text:); like(seq:); acceptRelayedKey(diaryId:key:sender:); report(seq:reason:includeText:)
```
- 輪次真相：每次 `sync(id)` 先 `GET /v3/diaries/:id`，以其 `members`、`holderIndex`、`ownerAccountId`、`state`、`seq` 覆蓋本機 meta；事件只補內容並以 seq upsert，**不從事件重放輪次**。
- 送事件：先寫 `pending.enc`（eventId 固定），POST 成功後**向伺服器拉該 seq** 建立本機事件（不用請求內容自造）。只有網路失敗、5xx、429 才重送；403／400 清掉 pending 並把錯誤交給 UI。冪等 200 的 `holderIndex` 是當下 meta；若本機 seq 已超過該筆，不用該回應改輪次。
- `DiaryStore` 自己把 `AccountClientError` 映射成 `DiaryError`（`notHolder`、`notMember`、`notOwner`、`closed`、`full`、`limit`、`badCode`…）。

### 5.2 UI（`PeerDrop/UI/Diary/`，無 UIKit/AppKit）
- `DiaryListView`：名稱、成員數、持有者（帳號 ID）、輪到我徽章；建立、加入（貼連結或輸入短碼）。
- `DiaryView`：時間軸（只畫 `entry`，讚數與留言數由 `refSeq` 聚合）／翻頁；持有者列（進入時查一次暱稱，失敗顯示 ID）；持有者見「書寫」「傳給下一人」；owner 於非自己持有時見「跳過」；無金鑰時等待卡＋「重新請求」；closed 顯示唯讀。
- `DiaryEntryComposer`（5,000 字計數）、`DiaryCommentsSheet`（留言 500 字、按讚）、`DiaryInviteSheet`（複製／系統分享連結、短碼、owner 重設、關閉日記本；含金鑰提示）、`DiaryJoinSheet`。
- 分頁 iOS `book.closed` `tag(4)`；Mac `MacSidebarSection.diaries` 第二段；⌘⌥1–5；`MacDetailRouter` 補 case 與 `.none` 文案。
- 字串約 45 鍵五語（含 `DIARY_TURN`、`DIARY_ENTRY`、`DIARY_JOIN`、`DIARY_REACTION`）。
- `ScreenshotModeProvider.mockDiaries`（`isActive` 時走假資料）。

---

## 6. 合規與風險
- UGC：每篇可檢舉、可離開、owner 可關閉；不做踢人。**離開者仍持有舊金鑰**是 MVP 已知限制，寫在「離開」與「邀請」文案。
- 邀請連結含金鑰：轉傳即洩露；重設邀請碼只讓舊碼失效，金鑰不變；owner 可 `close` 止血。
- 短碼補發依賴至少一名成員裝置在線 sync；`request-key` 限 6/小時；封鎖造成的假 201 不會出現（`diaryKey` 走真實 403）。
- 一本可被單一成員寫滿（無每人上限）；滿後冪等重送仍 200。
- 離開者不再能拉事件、檢舉、要金鑰（全部要求現任成員）；但已同步到本機的內容仍在其裝置上。
- 檢舉 `excerpt` 是伺服器唯一保存的明文，選用、預設不勾、不進 log。
- `owner` 轉移給移除後的 `members[0]`。

## 7. 測試
- worker：建立原子初始化與冪等（同 id 重送不換 inviteCode、D1 補列）、`diary_exists`、join 冪等仍寫 D1、join-by-code 與 `diary_invites`、reset 換碼、最後一人 leave 不讀空陣列、close 後仍可 leave、非成員讀 events／report／request-key 403 且不推播、20 本（create 與 join）、非持有者 403、skip 謂詞四情境、leave 的四種索引（持有者在中間／末尾、持有者之前的人離開、owner 兼持有者離開）、close、like 冪等、`bad_ref`、`POST /events` 拒 `join`、64 KB／64 MB 與滿後冪等 200、D1 失敗回 500、`diaryKey` 非成員 403 與 background push 標頭、四種推播收件者集合、`request-key` 不產生 `DIARY_JOIN`、join 錯碼限流與正規化、reports 重建後紙條與日記檢舉皆可寫且 admin 查得到。
- Kit：`DiaryCrypto` 往返／AAD／竄改／超長；`DiaryEventLog` 追加、重啟重建、毒框架、截斷尾端；`DiaryClient` 200 與 201 皆解出 `holderIndex`；`NotesStore` 分流三種游標規則；`DiaryStore` 建立順序（先金鑰後 POST、同 id 重送）、連結 join（先落盤 meta 再驗金鑰）、sync 以 GET meta 為輪次真相、pending 只重送暫態錯誤、`acceptRelayedKey` 拒垃圾金鑰、`DiaryKeyRelay` 由 join 事件驅動且失敗不去重；`RelayPushKind` 與 URL 解析（log 字串不含 fragment）。
- E2E（wrangler dev）：worker 端用兩個測試帳號走建立→連結 join→寫→pass→留言／讚→skip→leave；短碼補發用會跑 `DiaryKeyRelay` 的客戶端（Mac dev build 或測試 harness）對真實路由送信封，斷言收件匣 `kind`、`openMeta` 通過；UI 在模擬器逐步點過四則故事。

## 8. 實作拆分（grok 建議，採用）
1. Worker 仲裁與 schema（DO、0003、wrangler v5、路由，不含推播）。
2. 推播與 `kind=diaryKey`（`fanOutPush`、background push、成員檢查）。
3. Kit 純函式與 HTTP（`DiaryCrypto`、`DiaryEventLog`、`DiaryKeyStore`、`DiaryClient`）。
4. 紙條接縫（`NoteCrypto.seal(kind:)`、`NotesClient.send(kind:)`、`NotesStore` handler 與游標、錯誤碼）。
5. `DiaryStore` 與補發（`DiaryKeyRelay`、pending、`acceptRelayedKey`）。
6. 推播進 App、深連結、兩端 UI、字串、`mockDiaries`。
7. 本機 E2E 與文件收尾。
