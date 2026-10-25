# 專案 G1a：群組聊天室伺服器（`GroupRoom`＋D1 0005＋路由）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Cloudflare Worker 上新增邀請制、端對端加密的群組聊天室後端：`GroupRoom` Durable Object（成員 ≤ 50、密文轉送、WebSocket 廣播、保留 5,000 筆／90 天、金鑰世代輪換、帳號與匿名成員）、D1 `0005_groups.sql`（群組索引表＋`reports` 重建）、`/v3/groups*` 路由、推播與檢舉，以及給 G1b 用的共用加密測試向量。

**Architecture:** 一個群組＝一個以客戶端 ULID 命名的 `GroupRoom` DO（key/value 儲存，仿 `DiaryRoom`），它是成員、邀請碼、金鑰封裝、事件日誌的唯一真相；D1 只做「這個帳號在哪些群組」與「邀請碼指向哪個群組」的索引，並在喚醒 DO 前擋掉不存在的 id。Worker 路由（新檔 `group.ts`）負責驗證呼叫者（帳號 Bearer／金鑰通道或匿名裝置 Bearer）、驗章、配額、D1 索引與推播；DO 負責成員授權與所有狀態轉移。即時性靠 DO 的 Hibernation WebSocket（只下行廣播），上行一律走 HTTP（冪等 `eventId`）。

**Tech Stack:** TypeScript、Cloudflare Workers＋Durable Objects（SQLite-backed class，KV API）、D1、KV、WebCrypto（Ed25519、X25519、HKDF、AES-GCM）、vitest 4＋`@cloudflare/vitest-pool-workers` 0.16（miniflare）。

**Spec:** `docs/superpowers/specs/2026-10-24-project-f-g-categories-group-rooms-design.md`（§0.3、§0.4 已核可決定、§3 全部、§4 的 G1a 段為準；本計畫的「Rulings」補足規格未定之處）。規格檔位於 `.worktrees/peer-drop-fg-docs/`，執行前先複製或以絕對路徑讀取：`/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop/.worktrees/peer-drop-fg-docs/docs/superpowers/specs/2026-10-24-project-f-g-categories-group-rooms-design.md`。

**Base：** worktree `/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop/.worktrees/peer-drop-g1a`，分支 `feat/project-g1a-group-room`，base＝`origin/main` `821aa15`。行號以 `821aa15` 為準，動手前重新 grep。

## Global Constraints

- 繁體中文台灣用語；commit 格式 `type: short description`，結尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`；**永遠 `git add <指定檔>`，不得 `git commit -a`**；不得碰 `.gitignore` 與 `docs/pet-design/`；**不得 push、不得開 PR**（由使用者決定）。
- **執行者不得呼叫任何 `wrangler` 指令**（不 deploy、不 `d1 migrations apply`、不連正式環境）。所有驗證都用 vitest＋miniflare。
- **合併到 `main` 即自動部署**（`.github/workflows/worker-deploy.yml`：push 到 main 且動到 `cloudflare-worker/**` → 先 `wrangler d1 migrations apply ACCOUNTS_DB --remote`，再 `wrangler deploy`）。因此：所有伺服器變更必須**惰性**（沒有客戶端呼叫 `/v3/groups*` 時零影響）；`0005` 會在舊程式碼仍在線上的幾秒內先套用，必須與舊程式碼相容（舊的 notes／diary 檢舉 INSERT 皆列明欄位，不受影響）。
- 測試指令（外接碟路徑有空白，`scripts/run-tests.sh` 會自動在 `/tmp/peerdrop-cf-<hash>` 建影子樹）：`cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop/.worktrees/peer-drop-g1a/cloudflare-worker" && npm test -- src/__tests__/<file>.spec.ts`；全套 `npm test`；型別 `npx tsc --noEmit`（CI 會跑，必須 0 錯）。影子樹 node_modules 壞掉時 `rm -rf /tmp/peerdrop-cf-*/node_modules` 後重跑。
- 規格數值（逐字）：成員 **≤ 50**；每帳號參與 **≤ 20** 個；保留**最近 5,000 筆或 90 天（先到者）**；`msg` 的 `payloadCipher` **≤ 8 KB**；`metaCipher` 一次更新 **≤ 400 KB，超過回 413**；補抓 `limit` 預設 **100**；錯碼每小時 **10** 次；推播同一房間 **60 秒**內合併；alert 固定「有新訊息」、不含群名與發話者；WebSocket 心跳、2 小時硬上限沿用專案 E；`discoverability` 固定 `private`；`anonymousAllowed` 預設**關閉**；DO migration `tag = "v7"`、`new_sqlite_classes = ["GroupRoom"]`。
- **隱私（硬性，§3.2）**：伺服器只可能看到明文清單所列欄位。不得 `console.*` 任何 `payloadCipher`、`metaCipher`、封裝金鑰、公鑰、簽章、邀請碼、裝置 ID、帳號 ID、檢舉摘要；`console.error` 只能帶固定字串＋`String(e)`（仿 `diary.ts`）。不得寫 `wslog:`。匿名成員**不寫 D1 任何表**，其 `deviceId` 只存在該 DO 內；帳號成員的裝置清單與推播 token 只在推播當下由路由從 D1／KV 讀出、**不寫進 DO**；**任何回給客戶端的回應或 WebSocket 訊框都不得含 `deviceId` 或推播 token**。
- 儲存相容：不改任何既有 DO 類別、既有 KV 鍵格式、既有路由行為；`fanOutPush` 外部行為不變。
- 每個 SQL migration 只用整行 `--` 註解、字串內不得有分號（`src/__tests__/d1.ts:42` 的切句器限制）。
- Worker 對 DO 的呼叫一律用**新建**的 `Request`（`https://group/<path>`），**絕不**把客戶端原始 `request` 轉給 DO（避免客戶端偽造內部欄位或標頭）。

## Rulings（規格未定、由本計畫決定；可推翻）

1. **上行走 HTTP、WebSocket 只下行**。發言＝`POST /v3/groups/:id/events`（冪等 `eventId`、大小與世代檢查、推播在路由內可注入測試），DO 寫入後廣播給已連線成員。WebSocket 收到的非 `ping` 訊框一律忽略（不解析、不記錄）。
2. **WebSocket 用一次性票券**：`POST /v3/groups/:id/ws-ticket`（標頭帶 Bearer）換 60 秒、單次有效的票券，`GET /v3/groups/:id/ws?ticket=` 升級。原因：`URLSession` 的 WebSocket 升級不可靠地帶自訂標頭（`index.ts:251-256` 的既有註解），而長效 Bearer 不得放網址；票券由 DO 自己核銷，連線可 hibernate。
3. **`memberId` 由客戶端產生**（26 字元 Crockford base32 隨機值，同 ULID 字母表），隨 join 送出；伺服器檢查格式與房內唯一（409 `member_id_taken`）。原因：帳號成員的公鑰簽章與所有 AAD 都要綁定 `memberId`，必須在加入前就知道。
4. **每個成員請求帶 `X-Group-Member-Id` 標頭**，路由把「已驗證的呼叫者（accountId／deviceId）＋宣稱的 memberId」交給 DO 比對：帳號成員比 `accountId`、匿名成員比 `deviceId`。同一裝置可同時以帳號與匿名身分在同一房，不會混淆。
5. **匿名身分一律要求 Bearer 通道**（`authorizeDevice` 的 Bearer；金鑰通道 `X-API-Key`＋自報 `X-Device-Id` 對匿名一律 401 `bearer_required`）。原因：金鑰通道的裝置 ID 是自報的，等於讓持有 Mac 金鑰的人冒充任何匿名成員、也讓「踢出黑名單」失效。帳號成員沿用日記：兩種通道皆可。
6. **伺服器也驗章**：帳號成員的 `pubKeySig`、每筆封裝的 `sig` 由路由用 D1 `accounts.signing_key`（Ed25519）驗證（400 `bad_sig`）；客戶端仍須自行驗（§0.4 #1）。這擋住金鑰通道冒充者替別人的帳號塞公鑰。簽章訊息格式定義在 Task 8 的測試向量。
7. **只有帳號成員可以補封裝（relay）金鑰**；匿名成員不能上傳封裝（403 `account_required`）。原因：匿名封裝無法驗章，惡意匿名成員可給新成員一把假的 `roomKey` 讀他的訊息。非建立者的封裝**先寫先贏**，建立者可覆寫。與規格 §3.4「任何持有現行金鑰的成員」不同，**使用者已核可（2026-10-25）**。
8. **伺服器強制「等待金鑰不能發言」**：發言者必須持有現行 `epoch` 的封裝（否則 403 `awaiting_key`），且 `epoch` 必須等於現行世代（否則 409 `stale_epoch`）。
9. **輪換是單一原子請求** `POST /v3/groups/:id/rotate {eventId, epoch: 現行+1, wraps, metaCipher}`：封裝必須**恰好**涵蓋所有現有成員（多或少都回 409 `members_changed` 並附現行 `memberIds`），成功後 `epoch++`、`rotationDue=false`、寫一筆 `meta` 事件。
10. **離開／踢出後 `rotationDue = true`**（`GET` 回傳），建立者客戶端上線時據此補輪換（§3.4 的延遲風險不變）。被移除者的所有封裝立即刪除、WebSocket 立即關閉、票券作廢。
11. **建立者轉移與解散**：建立者離開 → 轉給**最早加入的剩餘帳號成員**（匿名不能當建立者）；沒有帳號成員剩下 → `state = "closed"`、`ownerMemberId = null`（匿名成員仍可讀、可離開）。最後一個成員離開 → DO `deleteAll()`＋刪鬧鐘，D1 刪除邀請列，之後該 id 一律 404。建立者不能踢自己（400 `kick_self`）。第一版**不做**手動轉移。
12. **一個帳號在一個房間只有一個 `memberId`、一組房內金鑰對、一份封裝**（不在同帳號的裝置之間共用或同步私鑰）。同帳號的第二台裝置以邀請碼重新加入（§0.3）時，會帶自己新產生的 `memberId`＋公鑰，DO 原子地以新成員**取代**舊成員：寫 `leave`(舊)＋`join`(新)，刪掉舊 `memberId` 的所有封裝、關掉舊的 socket；若舊的是建立者則新的接任；**不**設 `rotationDue`（同一人，舊裝置本來就有那些金鑰）。新成員一開始處於等待金鑰，由其他帳號成員補封裝（Ruling 7）。結果：**同一時間只有最後加入的那台裝置能在房內發言與解新訊息**；舊裝置下次呼叫會收到 403 `not_member`（G1b 據此把該房標成「已在其他裝置使用」並停用）。相同 `memberId` 重送＝冪等 200。匿名身分以 `deviceId` 判定同一身分，規則相同。
13. **踢出即封鎖**：帳號成員以 `sha256("acct:"+accountId)`、匿名以 `sha256("dev:"+deviceId)` 存 `ban:` 於 DO 內，無法再加入同一房（403 `banned`）。帳號成員也封鎖是本計畫的擴充（規格只寫匿名），**使用者已核可（2026-10-25）**；第一版沒有解除封鎖。
14. **推播對象（使用者 2026-10-25 決定）**：帳號成員 → 送到**該帳號所有裝置**，在送出當下由路由呼叫既有的 `fanOutPush(env, accountId, …)`（`push.ts:29-60`：查 D1 `account_devices`，再讀 KV `V2_STORE device:<deviceId>` 的 `pushToken`/`platform`）解析，**DO 不保存帳號成員的任何 deviceId**（`GroupMember.deviceId` 只有匿名成員有）；匿名成員 → 只送 DO 內保存的那一個 `deviceId`（新 `pushToDevice`）。DO 回給路由的只有 `recipients: ({kind:"account", accountId} | {kind:"device", deviceId})[]`，路由解析成 token 後送出，**裝置清單與 token 從不進入任何回應、WebSocket 訊框、DO 儲存或日誌**。為此 `fanOutPush` 的錯誤日誌 `console.error("push failed", d.device_id, …)`（`push.ts:54`）改成不帶 `device_id`（固定字串＋`String(e)`）——這是對既有 notes／diary 推播唯一的行為變更（只影響日誌內容）。已知副作用：帳號的其他裝置即使沒有加入該房（Ruling 12）也會收到內容空白的「有新訊息」，點開後找不到對應的房間，G1b 需把這種推播當成「同步一下」處理。
15. **`metaCipher` 存成獨立鍵** `metacipher`（不放在 `meta` 物件內），`meta` 只帶 `metaVersion`；`GET /v3/groups/:id` 不回 `metaCipher`，另有 `GET /v3/groups/:id/meta`。原因：每次發言都要改寫 `meta`，400 KB 一起搬太浪費。這是對規格 §3.3 key/value 列表的實作調整。
16. **限流**：`/v3/groups*` 有自己的 IP 限流桶 `groups`（`rateLimitClass`，仍是 30／分），避免聊天吃光其他 `/v3` 預算；每成員發言 30 則／分（DO 記憶體計數，429）；建立每帳號每日 20（同日記）；匿名加入每裝置每日 20（KV，鍵用裝置 ID 雜湊）；錯碼每小時 10（帳號用 accountId、匿名用裝置雜湊）；`request-key` 每成員每小時 6；檢舉每日 20。**不用 PoW**（日記建立也沒用；匿名加入的成本由 App Attest 的 Bearer 承擔）。匿名參與數量**沒有總上限**（不能寫 D1，DO 之間無法加總），只有每日加入額度——**使用者已接受（2026-10-25），須誠實寫進隱私說明與 PR 說明**（見文末「隱私與已知缺口說明」）。
17. **保留與裁剪**：每次寫入事件後若筆數 > 5,000 即刪最舊；每日鬧鐘刪 90 天前的事件、過期票券、舊世代且已無事件的封裝。`GET events` 回 `firstSeq`，`since < firstSeq-1` 時客戶端知道有缺口。
18. **檢舉**：`msg` 與 `meta` 事件可檢舉，`join/leave/kick` 回 400 `not_reportable`。`reports.sender_hash`：作者是帳號成員＝`senderHash(TOKEN_SECRET, accountId)`；匿名成員＝`senderHash(TOKEN_SECRET, "anon:"+deviceId)`（讓營運者能跨房關聯同一個濫用裝置——**使用者已接受（2026-10-25），須寫進隱私說明與 PR 說明**）。檢舉人：帳號身分寫 `reporter_account_id`，匿名身分寫 `reporter_device_id`（§0.4 #3）。
19. **Mac 金鑰通道（已知缺口，使用者決定沿用日記）**：帳號身分的所有群組路由——包含建立者限定的 `kick`／`close`／`invite/reset`／`meta`／`rotate`——都接受 `X-API-Key`（Mac client key）＋自報 `X-Device-Id`，與 `diary.ts` 相同。風險：取得 Mac 金鑰且知道某帳號任一 `deviceId` 的人可代該帳號執行這些操作。Ruling 6 的伺服器驗章擋住其中「塞公鑰／封裝」的部分（需要帳號簽章私鑰），但擋不住踢人、關房、重設邀請碼、改 `joinPolicy`。寫進 PR 說明的已知缺口；Mac 改用 Bearer 後再收緊。

## Review Focus

1. **輪換與加入競態**：建立者讀成員表後、送出輪換前有人加入或離開 → 必須 409 `members_changed`，絕不能讓新成員拿不到新金鑰或讓被踢者拿到（Task 4 測試 `rotate rejects a wrap set that no longer matches members`）。
2. **匿名成員走金鑰通道**：`X-API-Key`＋自報 `X-Device-Id` 想以匿名加入、發言或冒充既有匿名成員 → 401 `bearer_required`（Task 6 測試 `anonymous actions refuse the key lane`）。
3. **補抓跨過已裁剪範圍**：`since` 早於 `firstSeq` → 從 `firstSeq` 開始回、帶 `firstSeq`，不得 500 或回空（Task 3 測試 `events since a pruned range start at firstSeq`）。
4. **最後一人離開時仍有連線與未用票券** → DO 清空、所有 socket 關閉、舊票券升級失敗、之後所有路由 404（Task 4 測試 `last leave wipes the room including sockets and tickets`）。
5. **400 KB 邊界與大回應**：`metaCipher` 解碼後剛好 400 KB 通過、多 1 byte 回 413；`GET /v3/groups/:id` 永遠不含 `metaCipher`（Task 4 `meta size boundary`、Task 6 `group view never carries metaCipher or deviceId`）。

---

## File Structure

| 檔案 | 動作 | 責任 |
|---|---|---|
| `cloudflare-worker/migrations/0005_groups.sql` | 新增 | `group_members`、`group_invites`、`reports` 重建 |
| `cloudflare-worker/src/groupRoom.ts` | 新增 | `GroupRoom` DO：型別、成員、事件、保留、WebSocket、金鑰、推播對象 |
| `cloudflare-worker/src/groupSig.ts` | 新增 | 純函式：ID 格式、簽章訊息組裝、Ed25519 驗章、base64 長度 |
| `cloudflare-worker/src/group.ts` | 新增 | `/v3/groups*` 路由、D1 索引、配額、推播、檢舉 |
| `cloudflare-worker/src/push.ts` | 修改 | 抽出 `pushToDevice`、錯誤日誌拿掉 device_id |
| `cloudflare-worker/src/groupPush.ts` | 新增 | `deliverGroupPush`：帳號成員→所有裝置、匿名→單一裝置 |
| `cloudflare-worker/src/index.ts` | 修改 | `Env`、`rateLimitClass`、`/v3/groups` 分派、`authorizeGroupCaller`、admin reports 欄位、`export { GroupRoom }` |
| `cloudflare-worker/wrangler.toml` | 修改 | `GROUP_ROOM` 綁定、`v7` migration |
| `cloudflare-worker/worker-configuration.d.ts`、`src/__tests__/env.d.ts` | 修改 | `GROUP_ROOM` 型別 |
| `cloudflare-worker/src/__tests__/d1.ts` | 修改 | `applyMigrationsThrough` |
| `cloudflare-worker/src/__tests__/groupHelpers.ts` | 新增 | 測試用帳號（保留簽章私鑰）、匿名裝置、群組 HTTP 包裝、假封裝 |
| `cloudflare-worker/scripts/gen-group-vectors.mjs`、`test-vectors/group-crypto.json` | 新增 | 共用向量（Task 8） |
| 測試 `src/__tests__/group-*.spec.ts` | 新增 | 見各 task |

---

### Task 1: D1 `0005_groups.sql` 與 `reports` 重建

**Files:**
- Create: `cloudflare-worker/migrations/0005_groups.sql`
- Modify: `cloudflare-worker/src/__tests__/d1.ts:64-75`（新增 `applyMigrationsThrough`）
- Modify: `cloudflare-worker/src/index.ts:1459-1468`（`GET /v3/admin/reports` 加欄位、`reporter_account_id` 型別改可空）
- Test: `cloudflare-worker/src/__tests__/group-d1.spec.ts`

**Interfaces:**
- Produces（D1 schema，後續 task 依賴）：
  - `group_members(account_id TEXT NOT NULL, group_id TEXT NOT NULL, joined_at INTEGER NOT NULL, PRIMARY KEY(account_id, group_id))`＋索引 `group_members_group ON group_members(group_id)`
  - `group_invites(invite_code TEXT PRIMARY KEY, group_id TEXT NOT NULL)`＋索引 `group_invites_group ON group_invites(group_id)`
  - `reports`：`id, reporter_account_id TEXT NULL, reporter_device_id TEXT NULL, sender_hash TEXT NULL, inbox_item_id TEXT NULL, diary_id TEXT NULL, diary_seq INTEGER NULL, group_id TEXT NULL, group_seq INTEGER NULL, reason TEXT NOT NULL, excerpt TEXT NULL, created_at INTEGER NOT NULL, CHECK (reporter_account_id IS NOT NULL OR reporter_device_id IS NOT NULL)`；重建後補回 `reports_sender ON reports(sender_hash, created_at)`，新增 `reports_group ON reports(group_id, created_at)`。
  - `applyMigrationsThrough(db: D1Database, lastFileInclusive: string): Promise<void>`（依檔名排序套用到該檔為止）。
  - admin 回應每筆多 `reporterDeviceId`、`groupId`、`groupSeq`。

現行 `reports` 的真實 schema（0002 建立、0003 重建後）：`id, reporter_account_id NOT NULL, sender_hash NULL, inbox_item_id NULL, diary_id NULL, diary_seq NULL, reason NOT NULL, excerpt NULL, created_at NOT NULL`。0005 仿 `0003_diary.sql:15-31` 的重建流程，但在最前面加 `DROP TABLE IF EXISTS reports_new`（中斷後重跑不卡住）。**注意：重建是單次性的**（重跑會用舊欄位清單複製、丟掉新欄位資料）；正式環境靠 wrangler 的 `d1_migrations` 記錄只套一次，檔頭註解寫明。`group_members`／`group_invites` 用 `IF NOT EXISTS`。

- [ ] **Step 1: 寫失敗測試** `group-d1.spec.ts`（`beforeAll` 只套到 `0004_account_settings.sql`，先塞舊資料再於測試內套 0005；各 spec 檔的 D1 是獨立的——證據：每個 spec 的 `beforeAll` 都跑非冪等的 0003，若共用早就失敗）

```ts
it("0005 preserves every existing notes and diary report row", async () => {
  // 插入一筆 notes 檢舉（diary 欄位 NULL）與一筆 diary 檢舉，套 0005
  // 斷言兩筆所有舊欄位逐一相等，且 reporter_device_id/group_id/group_seq 為 NULL
});
it("reports accept a device-only reporter with group_id/group_seq", async () => {
  // INSERT reporter_account_id NULL, reporter_device_id 'dev-x', group_id, group_seq → 成功
});
it("reports reject a row with neither reporter", async () => {
  await expect(insert({ reporter_account_id: null, reporter_device_id: null })).rejects.toThrow();
});
it("group_members/group_invites exist with their keys", async () => {
  // 重複 (account_id, group_id) 拒絕；重複 invite_code 拒絕；PRAGMA index_list 含 group_members_group、group_invites_group、reports_sender、reports_group
});
it("admin reports exposes reporterDeviceId/groupId/groupSeq", async () => {
  // SELF.fetch /v3/admin/reports，標頭 X-API-Key: test-analytics-key-67890（index.ts:1857 requireKey("ANALYTICS_KEY")）
  // 斷言 device-only 那筆 reporterAccountId === null、reporterDeviceId === "dev-x"
});
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-d1.spec.ts` → FAIL（`applyMigrationsThrough` 不存在／`no such migration: 0005_groups.sql`）。
- [ ] **Step 3: 實作** `0005_groups.sql`、`applyMigrationsThrough`、admin reports 的 SELECT 與 map（`index.ts:1465-1467`）。
- [ ] **Step 4: 跑測試確認通過**，再跑 `npm test -- src/__tests__/diary-routes.spec.ts src/__tests__/notes-inbox.spec.ts`（既有檢舉流程不變）與 `npx tsc --noEmit`。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/migrations/0005_groups.sql cloudflare-worker/src/__tests__/d1.ts cloudflare-worker/src/__tests__/group-d1.spec.ts cloudflare-worker/src/index.ts
git commit -m "feat: add 0005_groups migration and widen reports for group reports" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `GroupRoom` 骨架、成員與邀請（DO 層）

**Files:**
- Create: `cloudflare-worker/src/groupRoom.ts`
- Create: `cloudflare-worker/src/groupSig.ts`（本 task 只放 ID 與 base64 工具）
- Modify: `cloudflare-worker/wrangler.toml:59-60` 之後加綁定、`:83-84` 之後加 `v7`
- Modify: `cloudflare-worker/src/index.ts:29-40`（`Env.GROUP_ROOM`）、`:2142-2144`（`export { GroupRoom } from "./groupRoom";`）
- Modify: `cloudflare-worker/worker-configuration.d.ts:7,16`（`durableNamespaces` 加 `"GroupRoom"`、`GROUP_ROOM: DurableObjectNamespace; // untyped on purpose`）、`src/__tests__/env.d.ts`
- Test: `cloudflare-worker/src/__tests__/group-room.spec.ts`

**Interfaces:**
- Produces（`groupSig.ts`）：
  - `GROUP_ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/`；`isValidGroupId(s)`、`isValidMemberId(s)`、`isValidEventId(s)`（三者同一字母表 26 字元）
  - `decodedByteLength(b64: string): number | null`（同 `diaryRoom.ts:56-62`）
  - `sha256Hex(s: string): Promise<string>`
- Produces（`groupRoom.ts`）：

```ts
export type GroupMemberKind = "account" | "anon";
export type JoinPolicy = "accountOnly" | "anonymousAllowed";
// account 成員：有 accountId、沒有 deviceId；anon 成員：有 deviceId、沒有 accountId（Ruling 14）
export interface GroupMember { memberId: string; kind: GroupMemberKind; accountId?: string; deviceId?: string; joinedAt: number; joinedEpoch: number; pubKey: string; pubKeySig?: string }
export type PushRecipient = { kind: "account"; accountId: string } | { kind: "device"; deviceId: string };
export interface GroupMeta { groupId: string; ownerMemberId: string | null; members: GroupMember[]; joinPolicy: JoinPolicy; discoverability: "private"; state: "open" | "closed"; epoch: number; seq: number; firstSeq: number; inviteCode: string; metaVersion: number; rotationDue: boolean; createdAt: number }
export type GroupEventType = "msg" | "join" | "leave" | "kick" | "meta";
export interface GroupEvent { seq: number; eventId: string; type: GroupEventType; authorMemberId: string; epoch: number; payloadCipher?: string; targetMemberId?: string; ownerMemberId?: string; createdAt: number }
export interface WrapRecord { wrapped: string; wrappedBy: string; sig: string; createdAt: number }
export interface Caller { memberId: string; accountId: string | null; deviceId: string; lane: "bearer" | "key" }
export interface PublicMember { memberId: string; kind: GroupMemberKind; accountId?: string; joinedAt: number; pubKey: string; pubKeySig?: string; hasKey: boolean }
export const GROUP_LIMITS = { maxMembers: 50, maxEvents: 5000, retentionMs: 90 * 86_400_000, maxPayloadBytes: 8 * 1024, maxMetaBytes: 400 * 1024, wrappedBytes: 92, sigBytes: 64, pubKeyBytes: 32, ticketTtlMs: 60_000, socketsPerMember: 2, staleMs: 90_000, hardCapMs: 2 * 3600_000, pushThrottleMs: 60_000, eventsDefaultLimit: 100, eventsMaxLimit: 500, msgsPerMinutePerMember: 30 } as const;
export class GroupRoom { ctx: DurableObjectState; now: () => number; constructor(ctx: DurableObjectState, env: unknown); fetch(req: Request): Promise<Response>; alarm(): Promise<void> }
```

- 儲存鍵：`meta`、`metacipher`（字串）、`ev:<seq 補零 12>`、`eid:<eventId>`、`key:<epoch 補零 10>:<memberId>`、`ban:<sha256hex>`、`tkt:<sha256hex(ticket)>`、`push:<memberId>`。
- DO 內部端點（本 task；全部 `POST` JSON，`caller: Caller`；**沒有 `meta` 時一律 404 且不寫任何儲存**）：
  - `/init {groupId, owner: {memberId, accountId, pubKey, pubKeySig}, ownerWrap: {wrapped, sig}, metaCipher, joinPolicy, inviteCode}` → 201 `GroupMeta`；同 `owner.accountId` 重送 200（不覆寫）；不同帳號 409 `group_exists`。`epoch=1`、`seq=0`、`firstSeq=1`、`metaVersion=1`、`rotationDue=false`；寫 `key:0000000001:<owner>`；鬧鐘設 `now+24h`。
  - `/view {caller}` → `{ groupId, ownerMemberId, members: PublicMember[], joinPolicy, discoverability, state, epoch, seq, firstSeq, metaVersion, rotationDue, inviteCode? }`（`inviteCode` 只給建立者；**永不含 `deviceId`、`metaCipher`**）。
  - `/join {inviteCode, member: Omit<GroupMember,"joinedAt"|"joinedEpoch">, dryRun?: boolean}` → 檢查順序：同身分已在（帳號比 accountId、匿名比 deviceId）且同 memberId → 200 `{added:false}`；`ban:` 命中 → 403 `banned`；邀請碼不符 → 403 `bad_code`；`closed` → 403 `group_closed`；匿名且 `accountOnly` → 403 `account_required`；滿 50 → 409 `group_full_members`；memberId 被別人用 → 409 `member_id_taken`；同身分不同 memberId → Ruling 12 取代；否則加入並寫 `join` 事件（`eventId = "srv:join:<memberId>:<seq>"`）→ 201 `{added:true}`。`dryRun` 只回判定、不寫入。`kind:"account"` 的 `member` 若帶 `deviceId` → 400 `bad_request`（DO 不收帳號成員的裝置 ID）；`kind:"anon"` 必須帶 `deviceId`、不得帶 `accountId`。
  - `/close {caller}`（建立者）、`/invite/reset {caller}`（建立者）→ `{inviteCode, previousCode}`（`generateAccountId()`，同 `diaryRoom.ts:185-194`）。
  - 內部共用：`authorize(meta, caller): GroupMember | Response`（403 `not_member`；成員是匿名而 `caller.lane === "key"` → 401 `bearer_required`，**在任何寫入之前**判定，Ruling 5）、`appendEvent(meta, ev, extraWrites)`（Task 3 補裁剪與廣播）。

- [ ] **Step 1: 寫失敗測試** `group-room.spec.ts`（直接打 DO stub，仿 `diary-room.spec.ts:13-27`）

```ts
it("init creates epoch 1 with the owner keyed, idempotent for the same owner", ...);   // 201 → 200，inviteCode/metaVersion 不變
it("init by a different account is 409 group_exists", ...);
it("every non-init endpoint on an uninitialised id is 404 and leaves storage empty", async () => {
  // /view /join /close /invite/reset → 404；runInDurableObject: (await state.storage.list()).size === 0
});
it("view never carries deviceId or metaCipher and gives inviteCode only to the owner", ...);
it("join enforces code, closed, ban, full(50), member_id_taken in that order", ...);   // 第 51 人 409 group_full_members
it("anonymous join into accountOnly is 403 account_required", ...);
it("rejoin with the same memberId is 200 added:false and writes no event", ...);
it("same account rejoining with a new memberId replaces the old member and keeps ownership", async () => {
  // 建立者在另一台裝置重新加入：舊 memberId 消失、新 memberId 為 ownerMemberId、事件依序 leave(舊)、join(新)、rotationDue 仍 false
});
it("dryRun reports the verdict without writing", ...);
it("close and invite/reset are owner-only (403 not_owner)", ...);
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-room.spec.ts` → FAIL（`env.GROUP_ROOM` undefined）。
- [ ] **Step 3: 實作** 綁定、migration、型別、`groupSig.ts` 工具、`GroupRoom` 上述端點。`wrangler.toml` 新增（接在 `v6` 之後，**不改 v1–v6**）：

```toml
[[durable_objects.bindings]]
name = "GROUP_ROOM"
class_name = "GroupRoom"

[[migrations]]
tag = "v7"
new_sqlite_classes = ["GroupRoom"]
```

- [ ] **Step 4: 跑測試確認通過**＋`npx tsc --noEmit`＋`npm test -- src/__tests__/diary-room.spec.ts src/__tests__/rendezvous.spec.ts`（綁定變更未破壞既有 DO）。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/src/groupRoom.ts cloudflare-worker/src/groupSig.ts cloudflare-worker/wrangler.toml cloudflare-worker/src/index.ts cloudflare-worker/worker-configuration.d.ts cloudflare-worker/src/__tests__/env.d.ts cloudflare-worker/src/__tests__/group-room.spec.ts
git commit -m "feat: add GroupRoom durable object with membership and invites" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 事件、保留裁剪與 WebSocket 廣播（DO 層）

**Files:**
- Modify: `cloudflare-worker/src/groupRoom.ts`
- Test: `cloudflare-worker/src/__tests__/group-room-events.spec.ts`

**Interfaces:**
- Consumes: Task 2 的 `GroupMeta`、`authorize`、`appendEvent`、`GROUP_LIMITS`。
- Produces（DO 端點）：
  - `/events/list {caller, since?: number, limit?: number}` → `{ events: GroupEvent[], firstSeq: number, nextSince?: number }`（`since` 預設 0；limit 夾在 1…500、預設 100；從 `max(since, firstSeq-1)` 之後開始；同 `diaryRoom.ts:197-207` 的分頁）。
  - `/events/msg {caller, eventId, epoch, payloadCipher}` → 201 `{ seq, event, recipients: PushRecipient[] }`；同 `eventId` 重送 200 原結果且 `recipients: []`。檢查：成員、`open`（403 `group_closed`）、`isValidEventId`（400 `bad_event_id`）、`epoch === meta.epoch`（409 `stale_epoch`，body 帶 `epoch`）、有 `key:<epoch>:<caller>`（403 `awaiting_key`）、base64 合法且非空（400 `bad_payload`）、解碼 ≤ 8,192（413 `too_large`）、每成員每分 30 則（429 `rate_limited`，記憶體 `Map`）。本 task 的 `recipients` 固定 `[]`（Task 5 填入）。
  - `/ws-ticket {caller}` → `{ ticket, expiresAt }`（32 位元組隨機 base64url；存 `tkt:<sha256hex>` → `{memberId, exp}`）。
  - `GET /ws?ticket=`（`Upgrade: websocket`）→ 核銷票券（刪除）；無效／過期／成員已不在 → 403 `{"error":"denied"}`；同成員已有 2 條開著的 → 關最舊（4000 `replaced`）；`ctx.acceptWebSocket(server, [memberId])`，attachment `{ memberId, connectedAt, last }`；把鬧鐘提前到不晚於 `connectedAt + 2h`。
  - 內部：`broadcast(ev: GroupEvent)` 對所有開著的 socket 送 `JSON.stringify({ t: "ev", e: ev })`，超過 2h 的改為關閉（4001 `expired`）；`isConnected(memberId): boolean`＝有開著、未超 2h、且 `now - max(last, autoResponseTs, connectedAt) <= 90s` 的 socket。
  - `appendEvent` 寫入後：若 `seq - firstSeq + 1 > 5000` → 刪最舊的溢出筆（連同其 `eid:`），`firstSeq` 前移；然後 `broadcast`。
  - `alarm()`：刪 `createdAt < now - 90d` 的事件（從 `firstSeq` 起，每次最多 1,000 筆，還有就 1 分鐘後再排）、刪過期 `tkt:`、關超過 2h 的 socket、刪 `epoch < 最舊留存事件的 epoch` 且 `< meta.epoch` 的 `key:`；下次＝`min(now+24h, 最早 socket 的 2h 到期)`。
  - 建構子：`ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))`（同 `rendezvousRoom.ts:51`）；`webSocketMessage` 只更新 attachment 的 `last`，**不解析、不 `console.*`**；`webSocketClose/Error` 只 `close`。
  - 客戶端合約（寫進檔頭註解，給 G1b）：每 30 秒送文字訊框 `"ping"`；2 小時硬上限後重新取票券；收到 4003 代表已被移除、4001 代表到期。

- [ ] **Step 1: 寫失敗測試** `group-room-events.spec.ts`（非建立者成員要發言時，因 `/keys/put` 在 Task 4 才有，先用 `runInDurableObject` 直接寫 `key:0000000001:<memberId>`；用 `runInDurableObject` 改 `inst.now`，仿 `rendezvous.spec.ts:299-320`；WebSocket 用 `stub.fetch("https://group/ws?ticket=…", { headers: { Upgrade: "websocket" } })` 取 `resp.webSocket` 再 `accept()`，`TestSocket` 仿 `rendezvous.spec.ts:73-96`）

```ts
it("msg is idempotent by eventId and appends one event", ...);
it("msg with a stale epoch is 409 stale_epoch carrying the current epoch", ...);
it("a member without a current-epoch wrap is 403 awaiting_key", ...);   // 剛加入、尚未被封裝的成員
it("payload of exactly 8192 bytes passes and 8193 is 413", ...);
it("31st msg within a minute from one member is 429", ...);
it("closed room refuses msg but still lists events", ...);
it("events since a pruned range start at firstSeq", async () => {
  // 塞 5,003 筆（用 runInDurableObject 直接寫儲存＋設定 meta.seq/firstSeq 以免跑 5,000 次 HTTP）再發 1 則
  // firstSeq === 5,004-5,000+1；ev:0000000001 與其 eid: 都不存在；/events/list since=0 第一筆 seq === firstSeq
});
it("alarm prunes events older than 90 days and expired tickets", ...);
it("ws ticket is single-use and expires after 60s", ...);              // 第二次 403；inst.now 推 61s 後 403
it("a broadcast reaches every connected member and carries no deviceId", async () => {
  // 兩名成員連線；A 發 msg；B 收到 {t:"ev", e:{seq, type:"msg", authorMemberId, epoch, payloadCipher}}；JSON 不含 deviceId 字串
});
it("third socket for one member replaces the oldest", ...);
it("sockets past 2h are closed 4001 on the next broadcast", ...);
it("isConnected is false once a socket has been silent for more than 90s", ...);
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-room-events.spec.ts` → FAIL（404 on `/events/msg`）。
- [ ] **Step 3: 實作** 上述端點、`appendEvent` 裁剪、`broadcast`、`isConnected`、`alarm`。
- [ ] **Step 4: 跑測試確認通過**＋`npx tsc --noEmit`。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/src/groupRoom.ts cloudflare-worker/src/__tests__/group-room-events.spec.ts
git commit -m "feat: add group events, retention pruning and hibernating websocket fan-out" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 金鑰封裝、輪換、設定更新與成員移除（DO 層）

**Files:**
- Modify: `cloudflare-worker/src/groupRoom.ts`
- Test: `cloudflare-worker/src/__tests__/group-room-keys.spec.ts`

**Interfaces:**
- Consumes: Task 2–3。
- Produces（DO 端點；封裝格式只檢查長度，簽章由路由在 Task 7 驗）：
  - `/keys/mine {caller}` → `{ wraps: { epoch, wrapped, wrappedBy, sig }[] }`（只有呼叫者自己的，依 epoch 升冪）。
  - `/keys/put {caller, epoch, wraps: {memberId, wrapped, sig}[]}` → `{ written: string[], skipped: string[] }`。規則：呼叫者須為帳號成員（403 `account_required`）且持有現行封裝（403 `not_keyed`）；`epoch === meta.epoch`（409 `stale_epoch`）；目標必須是現有成員（400 `unknown_member`）；`wrapped` 解碼 92 B、`sig` 64 B（400 `bad_wrap`）；目標已有封裝 → 非建立者 `skipped`、建立者覆寫。
  - `/rotate {caller, eventId, epoch, wraps, metaCipher}` → 201 `{ seq, epoch }`；建立者限定；`open`；`epoch === meta.epoch + 1`（409 `stale_epoch`）；`wraps` 的 memberId 集合必須**恰等於**現有成員（409 `members_changed`，body `{ memberIds }`）；`metaCipher` ≤ 400 KB（413）；一次 `storage.put` 寫入所有 `key:<新epoch>:*`＋`metacipher`＋`meta`（`epoch++`、`metaVersion++`、`rotationDue=false`）＋`meta` 事件（`epoch` 為新值）；`eventId` 冪等。
  - `/meta {caller, eventId, metaCipher, joinPolicy?, removeAnonymous?}` → 201 `{ seq, metaVersion }`；建立者限定；`open`；≤ 400 KB（413）；`removeAnonymous` 只在 `joinPolicy === "accountOnly"` 時允許（否則 400 `bad_request`）——移除所有匿名成員（每人一筆 `kick` 事件，**不**封鎖）並設 `rotationDue`；`meta` 事件不帶 `payloadCipher`。
  - `/meta-cipher {caller}` → `{ metaCipher, metaVersion }`。
  - `/leave {caller}` → 200 `{ remaining: number, removed: { kind, accountId? } }`；非成員 200 `{remaining, removed: null}`。
  - `/kick {caller, targetMemberId}` → 200 `{ removed: { kind, accountId? } | null }`；建立者限定；踢自己 400 `kick_self`；寫 `ban:`（Ruling 13）。
  - 內部 `removeMember(meta, memberId, reason: "leave" | "kick" | "replace")`：刪該成員所有 `key:*:<memberId>`、`push:<memberId>`、其 `tkt:`；關其 socket（4003 `removed`）；寫 `leave`／`kick` 事件（`kick` 帶 `targetMemberId`）；`leave/kick` 設 `rotationDue = true`；建立者離開時依 Ruling 11 轉移並在 `leave` 事件帶 `ownerMemberId`；成員數歸零 → 關所有 socket、`deleteAlarm()`、`deleteAll()`。

- [ ] **Step 1: 寫失敗測試** `group-room-keys.spec.ts`

```ts
it("a new member is awaiting key until a keyed account member relays a wrap", ...); // view.members[n].hasKey false → put → true；之後可發 msg
it("relay is first-write-wins for members, owner may overwrite", ...);
it("anonymous members cannot upload wraps (403 account_required)", ...);
it("an unkeyed member cannot relay (403 not_keyed)", ...);
it("wraps for a non-member are 400 unknown_member and are not stored", ...);
it("rotate requires epoch+1 and exactly the current member set", ...);
it("rotate rejects a wrap set that no longer matches members", async () => {
  // 建立者準備好 3 人的 wraps → 第 4 人加入 → rotate 409 members_changed，memberIds 長度 4；epoch 仍 1
});
it("kicked member loses all wraps, gets no new epoch key, and is banned", async () => {
  // kick → keys/mine 403 not_member；rotate（不含他）成功；他用原 memberId /join → 403 banned；新 memberId 也 banned
});
it("leave and kick set rotationDue; rotate clears it", ...);
it("owner leaving hands ownership to the earliest remaining account member", ...);
it("owner leaving with only anonymous members left closes the room", ...);       // ownerMemberId null、state closed、匿名仍可 list events 與 leave
it("meta size boundary", ...);                                                     // 409,600 B 通過、409,601 B 413
it("switching to accountOnly with removeAnonymous kicks every anon without banning", ...);
it("last leave wipes the room including sockets and tickets", async () => {
  // 有開著的 socket 與未用票券 → 最後一人 leave → socket 收到 close 4003；storage.list().size === 0；getAlarm() null；舊票券升級 404
});
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-room-keys.spec.ts` → FAIL。
- [ ] **Step 3: 實作** 上述端點與 `removeMember`（把 Task 2 的取代流程改走 `removeMember(…, "replace")`）。
- [ ] **Step 4: 跑測試確認通過**＋`npm test -- src/__tests__/group-room.spec.ts src/__tests__/group-room-events.spec.ts`＋`npx tsc --noEmit`。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/src/groupRoom.ts cloudflare-worker/src/__tests__/group-room-keys.spec.ts
git commit -m "feat: add group key wraps, epoch rotation, settings update and member removal" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 推播對象、節流與 `pushToDevice`

**Files:**
- Modify: `cloudflare-worker/src/push.ts:29-60`
- Modify: `cloudflare-worker/src/groupRoom.ts`（`/events/msg` 的 `recipients`、新增 `/request-key`）
- Create: `cloudflare-worker/src/groupPush.ts`（路由用的派送函式）
- Test: `cloudflare-worker/src/__tests__/group-push.spec.ts`

**Interfaces:**
- Produces（`push.ts`）：
  - `pushToDevice(env: Env, deviceId: string, fallbackPlatform: string | null, payload: PushPayload, deps: PushDeps): Promise<boolean>`——讀 `V2_STORE device:<deviceId>`（`{pushToken, platform}`）、送一則、回是否嘗試；**永不 throw**；`APNS_KEY_P8` 未設回 false；失敗時 `console.error("push failed", String(e))`，**不帶 deviceId、token**。
  - `fanOutPush` 改為：D1 `SELECT device_id, platform FROM account_devices WHERE account_id = ?1`（現行 `push.ts:33`）後對每台呼叫 `pushToDevice(env, d.device_id, d.platform, …)`。回傳 `{attempted}` 與送出內容不變；唯一變更是 `push.ts:54` 的錯誤日誌拿掉 `d.device_id`（Ruling 14）。
- Produces（`groupPush.ts`）：`deliverGroupPush(env: Env, recipients: PushRecipient[], payload: PushPayload, deps: PushDeps): Promise<void>`——`account` → `fanOutPush(env, accountId, payload, deps)`（帳號所有裝置）；`device` → `pushToDevice(env, deviceId, null, payload, deps)`；`Promise.all`、吞錯、不回傳任何裝置資訊。
- Produces（DO）：
  - `/events/msg` 201 時 `recipients`＝成員中：非作者、`!isConnected(memberId)`（帳號成員只要**任一** socket 活著就算在線，不推給該帳號任何裝置）、未在節流期內者；帳號成員輸出 `{kind:"account", accountId}`、匿名輸出 `{kind:"device", deviceId}`。
  - **節流以收件身分為單位**：鍵 `push:acct:<accountId>` 或 `push:dev:<sha256(deviceId)>`，值＝上次推播時間；`now - 值 < 60s` 則略過，否則寫入 `now`。用身分而不是 `memberId`，使 Ruling 12 的換裝置不會重置節流；成員被移除時刪掉對應鍵。重送（200）一律 `recipients: []`。
  - `/request-key {caller}` → `{ recipients: PushRecipient[] }`＝持有現行封裝的**帳號**成員（不含呼叫者），一律 `{kind:"account", accountId}`（不節流，路由端已有每小時 6 次上限）。
  - DO 儲存與回應中**不出現帳號成員的 deviceId 或任何推播 token**。
- 推播內容（Task 7 路由使用，這裡定為常數 `GROUP_PUSH` 匯出於 `groupRoom.ts`）：
  - 訊息：`{ alert: { "loc-key": "GROUP_MESSAGE" }, data: { type: "groupMessage", groupId } }`（G1b 須在 `Localizable.xcstrings` 加 `GROUP_MESSAGE`＝「有新訊息」五語系）
  - 補金鑰：`{ silent: true, data: { type: "groupKeyRequest", groupId } }`

- [ ] **Step 1: 寫失敗測試** `group-push.spec.ts`

```ts
it("pushToDevice sends exactly one push with the device's platform topic", ...);  // 假 deps.send 記錄呼叫（仿 diary-push.spec.ts:38-47）；fakeEnv 讓 APNS_KEY_P8 有值
it("fanOutPush behaviour is unchanged", ...);                                    // 一個帳號兩台有 token 的裝置 → attempted 2，兩個 token 各一次
it("fanOutPush failure log carries no device id or token", ...);                // 假 send 拋錯；console.error 參數不含 deviceId、pushToken
it("deliverGroupPush reaches every device of an account member and only the stored device of an anon", ...);
it("recipients exclude the author and any member with a live socket on any device", ...);
it("recipients throttle per recipient identity within 60s and survive a device move", ...); // 第二則 []；同帳號換 memberId 重新加入後 60s 內仍 []；inst.now +60s 後再出現
it("a replayed eventId returns recipients []", ...);
it("request-key targets only keyed account members other than the caller", ...);
it("DO storage never holds an account member's deviceId or push token", ...);    // runInDurableObject：storage.list() 全部值 JSON.stringify 後不含帳號成員的 deviceId／token
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-push.spec.ts` → FAIL。
- [ ] **Step 3: 實作** `pushToDevice`、重構 `fanOutPush`（含日誌）、`groupPush.ts`、DO 的 `recipients`／節流／`/request-key`、`GROUP_PUSH`。
- [ ] **Step 4: 跑測試確認通過**＋`npm test -- src/__tests__/diary-push.spec.ts src/__tests__/notes-send.spec.ts src/__tests__/accountSettings.spec.ts`（`fanOutPush` 回歸）＋`npx tsc --noEmit`。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/src/push.ts cloudflare-worker/src/groupPush.ts cloudflare-worker/src/groupRoom.ts cloudflare-worker/src/__tests__/group-push.spec.ts
git commit -m "feat: compute throttled group push recipients and add pushToDevice" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 路由（一）——驗證、建立、加入、離開、踢出、關閉、邀請

**Files:**
- Create: `cloudflare-worker/src/group.ts`
- Modify: `cloudflare-worker/src/groupSig.ts`（簽章訊息與驗章）
- Modify: `cloudflare-worker/src/index.ts`：`rateLimitClass`（`:119-129`，在 `/v3/` 之前加 `if (path.startsWith("/v3/groups")) return "groups";`）、在 `:1456` 的 admin reports 之前加 `/v3/groups` 分派、匯出 `authorizeGroupCaller`
- Create: `cloudflare-worker/src/__tests__/groupHelpers.ts`
- Test: `cloudflare-worker/src/__tests__/group-routes.spec.ts`

**Interfaces:**
- Consumes: Task 2/4 的 DO 端點；`bumpQuota`、`dayKey`、`json`（`notes.ts:79-91`）；`generateAccountId`、`normalizeAccountId`（`account.ts:39,53`）。
- Produces：
  - `index.ts`：`export interface GroupAuth { deviceId: string; accountId: string | null; lane: AuthLane }`；`export async function authorizeGroupCaller(request: Request, env: Env): Promise<GroupAuth | null>`（包 `authorizeDeviceWithLane`（`:1548-1565`），`accountId = accountIdFromScope(scope)`，可為 null）。分派：

```ts
if (path === "/v3/groups" || path.startsWith("/v3/groups/")) {
  return handleGroupRoute(request, url, path, env, { push: { send: sendAPNs, topicFor: (p) => selectApnsTopic(p, env) }, authorize: (r) => authorizeGroupCaller(r, env) });
}
```

  （放在 `/v3/` 帳號閘門 `:1474` 之前，因為匿名成員沒有帳號 scope。）
  - `group.ts`：`export interface GroupRouteDeps { push: PushDeps; authorize: (r: Request) => Promise<GroupAuth | null> }`；`export async function handleGroupRoute(request, url, path, env, deps): Promise<Response>`（`/v3/groups*` 未匹配回 404 `not_found`）。共用：`groupExistsInD1(db, groupId)`（仿 `diary.ts:65-70`，查 `group_members ∪ group_invites`）、`underGroupLimit(db, accountId, groupId)`（仿 `:81-87`，20）、`failJoinCode(env, key)`（仿 `:100-104`，鍵 `group-join-fail:<accountId 或 dev:<sha256(deviceId)>>:<hour>`）、`bindGroupInviteCode`（仿 `:184-199`，表 `group_invites`）、`hourKey`（仿 `:49-53`）、`callerFor(auth, request): Caller | Response`（讀 `X-Group-Member-Id`，缺或格式錯 400 `missing_fields`）、`doCall(env, groupId, path, body)`。
  - `groupSig.ts`：`memberKeyMessage(groupId, memberId, accountId, pubKey: Uint8Array): Uint8Array`＝`utf8("PDGRPMK1") ‖ utf8(groupId) ‖ utf8(memberId) ‖ utf8(accountId) ‖ pubKey`；`wrapMessage(groupId, epoch, targetMemberId, wrapperMemberId, wrapped: Uint8Array): Uint8Array`＝`utf8("PDGRPWK1") ‖ utf8(groupId) ‖ UInt32BE(epoch) ‖ utf8(targetMemberId) ‖ utf8(wrapperMemberId) ‖ wrapped`；`verifyAccountSig(db, accountId, message, sigB64): Promise<boolean>`（讀 `accounts.signing_key`，Ed25519 驗；任何錯誤回 false）。所有欄位定長（26／26／8／32／92），不需分隔符。
- 路由（本 task）：

| 路由 | 身分 | 要點 |
|---|---|---|
| `POST /v3/groups` | 帳號 | body `{groupId, memberId, pubKey, pubKeySig, ownerWrap:{wrapped,sig}, metaCipher, joinPolicy?}`（body ≤ 600 KB，413）；`joinPolicy` 預設 `accountOnly`；驗 `pubKeySig` 與 `ownerWrap.sig`（400 `bad_sig`）；20 上限（409 `group_limit`）→ 每日建立 20（429）→ `/init` → D1 `group_members` → `bindGroupInviteCode` → 201/200 `{groupId, inviteCode}` |
| `GET /v3/groups` | 帳號 | D1 列出 `[{groupId, joinedAt}]`（只有帳號成員關係） |
| `GET /v3/groups/:id` | 成員 | D1 存在檢查 → `/view` |
| `POST /v3/groups/:id/join`、`POST /v3/groups/join` | 帳號或匿名 | body `{inviteCode, memberId, pubKey, pubKeySig?, as: "account" \| "anon"}`（≤ 4 KB）；`as:"account"` 須有 accountId（403 `account_required`）且驗 `pubKeySig`；`as:"anon"` 須 Bearer（401 `bearer_required`）、不得帶 `pubKeySig`（400）、每裝置每日 20 次加入（429）；短碼路由用 `group_invites` 解析；`/join dryRun` 預檢 → `bad_code` 走 `failJoinCode` → 帳號 20 上限**放最後**（同 `diary.ts:106-119` 的理由）→ 正式 `/join`（其 403 `bad_code` 也走 `failJoinCode`）→ 帳號成員寫 D1 → 新加入時對 `/request-key` 的對象送 `GROUP_PUSH` 補金鑰（silent）→ 201/200 `{groupId, memberId, epoch, state, ownerMemberId}` |
| `POST /v3/groups/:id/leave` | 成員 | `/leave` → 帳號身分刪 D1 `group_members` → `remaining === 0` 刪 `group_invites`（同一 try，失敗 500 `d1_error`）→ 204 |
| `POST /v3/groups/:id/kick` | 建立者 | body `{memberId}`；`/kick` → 被踢者是帳號成員則刪其 D1 列 → 204 |
| `POST /v3/groups/:id/close`、`POST /v3/groups/:id/invite/reset` | 建立者 | 同 `diary.ts:373-400` |

  匿名身分的通道限制：`as:"anon"` 的 join 由路由在呼叫 DO 前檢查 `auth.lane === "bearer"`；既有匿名成員的請求由路由把 `auth.lane` 放進 `Caller`，DO 的 `authorize` 在寫入前拒絕（Task 2）。
  - `groupHelpers.ts`：`makeGroupAccount(deviceId): Promise<{ accountId, token, deviceId, signKey: CryptoKey }>`（直接呼叫 `registerDevice` 保留 `pair.kp.privateKey`，`accountHelpers.ts:87-104`）、`makeAnonDevice(deviceId): Promise<{ deviceId, token }>`（`deviceToken(deviceId)`，default scope）、`newMemberId()`、`fakePubKey()`（32 B）、`fakeWrap()`（92 B）、`signMemberKey(...)`、`signWrap(...)`、`createGroupOk(owner, opts?)`、`joinGroup(headers, groupId, body)`，以及每個路由的薄包裝（仿 `diaryHelpers.ts`）。

- [ ] **Step 1: 寫失敗測試** `group-routes.spec.ts`

```ts
it("routes on an unknown groupId are 404 and never wake a DO", ...);              // runInDurableObject 該 id storage.list().size === 0
it("create validates ids, signatures and size, then indexes owner in D1", ...);    // invalid_id 400、bad_sig 400、413、201 後 group_members 有 1 列
it("create is capped at 20 memberships and 20 creates per day", ...);
it("account join verifies pubKeySig and indexes in D1; anon join writes nothing to D1", async () => {
  // anon 加入 anonymousAllowed 房 → 201；SELECT COUNT(*) FROM group_members WHERE group_id=? 仍為 1（只有建立者）
});
it("anonymous actions refuse the key lane", async () => {
  // X-API-Key + X-Device-Id 以 as:"anon" join → 401 bearer_required；以既有匿名 memberId 打 GET /v3/groups/:id → 401
});
it("anonymous join into accountOnly is 403 account_required", ...);
it("a device-only token cannot create or join as account (403 account_required)", ...);
it("wrong codes are rate limited at 10 per hour per caller", ...);                 // 第 11 次 429；匿名以裝置雜湊計
it("account cap is checked last so a full group still answers group_full_members", ...);
it("group view never carries metaCipher or deviceId", ...);                         // JSON.stringify(body) 不含任何測試 deviceId
it("leave by the last member deletes the invite row and the id becomes 404", ...);
it("kick removes the kicked account's D1 row and bans rejoin", ...);
it("groups have their own rate-limit class", () => {
  expect(rateLimitClass("/v3/groups/X/events", "POST")).toBe("groups");
  expect(rateLimitClass("/v3/diaries", "POST")).toBe("v3");
});
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-routes.spec.ts` → FAIL（404 `Not Found`）。
- [ ] **Step 3: 實作** `authorizeGroupCaller`、分派、`rateLimitClass`、`groupSig.ts` 簽章、`group.ts` 本 task 路由、`groupHelpers.ts`。
- [ ] **Step 4: 跑測試確認通過**＋`npm test -- src/__tests__/rate-limit.spec.ts src/__tests__/auth.spec.ts src/__tests__/diary-routes.spec.ts`＋`npx tsc --noEmit`。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/src/group.ts cloudflare-worker/src/groupSig.ts cloudflare-worker/src/index.ts cloudflare-worker/src/__tests__/groupHelpers.ts cloudflare-worker/src/__tests__/group-routes.spec.ts
git commit -m "feat: add group membership routes with account and anonymous auth" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: 路由（二）——事件、金鑰、輪換、設定、WebSocket、推播接線

**Files:**
- Modify: `cloudflare-worker/src/group.ts`
- Modify: `cloudflare-worker/src/__tests__/groupHelpers.ts`
- Test: `cloudflare-worker/src/__tests__/group-routes-content.spec.ts`

**Interfaces:**
- Consumes: Task 3–6。
- Produces（路由；全部先 `groupExistsInD1`，成員路由帶 `X-Group-Member-Id`）：

| 路由 | 身分 | 要點 |
|---|---|---|
| `GET /v3/groups/:id/events?since=&limit=` | 成員 | → `/events/list` |
| `POST /v3/groups/:id/events` | 成員 | body `{eventId, epoch, payloadCipher}`（≤ 16 KB，413）→ `/events/msg` → 201 時 `deliverGroupPush(env, recipients, GROUP_PUSH 訊息, deps.push)`（吞錯）→ 回 `{seq}`（**只投影 `seq`**，不回 `event`/`recipients`） |
| `GET /v3/groups/:id/meta` | 成員 | → `/meta-cipher` |
| `PUT /v3/groups/:id/meta` | 建立者 | body ≤ 600 KB → `/meta` → `{seq, metaVersion}` |
| `POST /v3/groups/:id/rotate` | 建立者 | body ≤ 640 KB；每筆 `wraps[i].sig` 以建立者帳號驗 `wrapMessage`（400 `bad_sig`）→ `/rotate` → `{seq, epoch}` |
| `GET /v3/groups/:id/keys` | 成員 | → `/keys/mine` |
| `PUT /v3/groups/:id/keys` | 帳號成員 | body `{epoch, wraps}`（≤ 32 KB）；逐筆驗簽（400 `bad_sig`）→ `/keys/put` |
| `POST /v3/groups/:id/request-key` | 成員 | 每成員每小時 6（`group-keyreq:<groupId>:<memberId>:<hour>`，429）→ `/request-key` → silent 推播 → 204 |
| `POST /v3/groups/:id/ws-ticket` | 成員 | → `/ws-ticket` → `{ticket, expiresInSeconds: 60}` |
| `GET /v3/groups/:id/ws?ticket=` | 票券 | **不呼叫 `deps.authorize`**；非 Upgrade 400；`ticket` 只取查詢參數、長度上限 64；以新 `Request("https://group/ws?ticket=…", { headers: { Upgrade: "websocket" } })` 呼叫 DO，原樣回傳其 101／403 |

- [ ] **Step 1: 寫失敗測試** `group-routes-content.spec.ts`（推播用 `fakeEnv`＋假 `deps.push.send` 直接呼叫 `handleGroupRoute`，仿 `diary-push.spec.ts:20-60`；WebSocket 用 `SELF.fetch(".../ws?ticket=", { headers: { Upgrade: "websocket" } })`）

```ts
it("post msg returns only {seq} and pushes to every device of an offline account member", async () => {
  // 帳號 B 有兩台已註冊 token 的裝置 → 兩個 token 各收到一次；匿名成員 C 只有自己那台收到；
  // alert loc-key === "GROUP_MESSAGE"；data 恰為 {type:"groupMessage", groupId}；回應 JSON 只有 seq
});
it("a connected member gets the event over the websocket and no push", ...);
it("rotate verifies every wrap signature (400 bad_sig on one bad sig, epoch unchanged)", ...);
it("key relay over HTTP verifies the relayer's signature", ...);
it("request-key sends a silent push and is limited to 6 per hour", ...);
it("ws upgrade ignores Authorization and forged internal fields; only the ticket counts", async () => {
  // 無 ticket → 403；帶有效 Bearer 但無 ticket → 403；有效 ticket → 101
});
it("closed room: events GET and leave still work; post/meta/rotate are 403 group_closed", ...);
it("a kicked member's open socket closes 4003 and its ticket stops working", ...);
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-routes-content.spec.ts` → FAIL。
- [ ] **Step 3: 實作** 上述路由與推播接線。
- [ ] **Step 4: 跑測試確認通過**＋全部 `group-*.spec.ts`＋`npx tsc --noEmit`。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/src/group.ts cloudflare-worker/src/__tests__/groupHelpers.ts cloudflare-worker/src/__tests__/group-routes-content.spec.ts
git commit -m "feat: add group event, key, rotation, meta and websocket routes with push" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: 檢舉、隱私測試、共用測試向量與部署前檢查

**Files:**
- Modify: `cloudflare-worker/src/group.ts`（檢舉路由）、`cloudflare-worker/src/groupRoom.ts`（`/event/get`）
- Create: `cloudflare-worker/scripts/gen-group-vectors.mjs`、`cloudflare-worker/test-vectors/group-crypto.json`
- Test: `cloudflare-worker/src/__tests__/group-report-privacy.spec.ts`、`cloudflare-worker/src/__tests__/group-vectors.spec.ts`

**Interfaces:**
- Produces（DO）：`/event/get {caller, seq}` → `{ event, author: { kind: "account", accountId } | { kind: "anon", deviceId } | null }`（**只給路由**；作者已離開時 `author: null`）。
- Produces（路由）：`POST /v3/groups/:id/events/:seq/report`（成員；body `{reason: "spam"|"harassment"|"other", excerpt?}` ≤ 8 KB；`excerpt` ≤ `NOTE_LIMITS.excerptMaxChars`＝1,000 字）→ 事件不存在 404；非 `msg`／`meta` 400 `not_reportable`；每日 20（帳號 `report-quota:<accountId>:<day>`、匿名 `report-quota:dev:<sha256(deviceId)>:<day>`）；`sender_hash` 依 Ruling 18（作者已離開時 NULL）；INSERT `reports (id, reporter_account_id, reporter_device_id, sender_hash, inbox_item_id, diary_id, diary_seq, group_id, group_seq, reason, excerpt, created_at)` → 201 `{id}`。
- Produces（向量，給 G1b 的 `GroupCrypto` 測試；格式寫進 JSON 的 `description`）：
  - `memberKeySig`：固定 Ed25519 私鑰（seed hex）、`groupId`、`memberId`、`accountId`、`pubKey` → `message` hex、`signature` hex。
  - `wrap`：收件 X25519 私鑰／公鑰、暫時 X25519 私鑰／公鑰、`roomKey`(32 B)、`nonce`(12 B)、`groupId`、`epoch`、`memberId` → `sharedSecret`、`wrapKey`＝HKDF-SHA256(ikm=sharedSecret, salt=ephPub‖recipientPub, info=utf8("peerdrop-group-wrap-v1"), 32)、`aad`＝`utf8(groupId) ‖ UInt32BE(epoch) ‖ utf8(memberId)`、`wrapped`＝`ephPub(32) ‖ nonce(12) ‖ AES-256-GCM(roomKey)(32) ‖ tag(16)`（共 92 B）。
  - `message`：`roomKey`、`nonce`、`groupId`、`memberId`、`eventId`、`epoch`、`plaintext`(UTF-8) → `aad`＝`utf8(groupId) ‖ utf8(memberId) ‖ utf8(eventId) ‖ UInt32BE(epoch)`（§3.4）、`payloadCipher`＝`nonce ‖ ciphertext ‖ tag`（base64）。
  - `metaCipher`：同上，`aad`＝`utf8(groupId) ‖ UInt32BE(epoch) ‖ utf8("meta")`。
  - `wrapSig`：`wrapMessage(...)` 的 hex 與 Ed25519 簽章。
  - 生成：`node cloudflare-worker/scripts/gen-group-vectors.mjs > cloudflare-worker/test-vectors/group-crypto.json`（Node 22 WebCrypto；所有隨機值固定）。`group-vectors.spec.ts` 在 workerd 內用中間值逐層重算並比對（`aad`、`wrapKey`→AES-GCM 解開得 `roomKey`、`message` 解密得 `plaintext`、兩個簽章用 `verifyAccountSig` 同款邏輯驗過、`memberKeyMessage`／`wrapMessage` 的輸出 hex 相等）。若 workerd 不支援以 JWK／PKCS8 匯入 X25519 私鑰，`sharedSecret` 那一層改為只驗 Node 產出的值（在 spec 註明），其餘層照驗。

- [ ] **Step 1: 寫失敗測試**

```ts
// group-report-privacy.spec.ts
it("an account member's report writes reporter_account_id and the author's senderHash", ...);
it("an anonymous member's report writes reporter_device_id and NULL reporter_account_id", ...);
it("join/leave/kick events are 400 not_reportable; pruned seq is 404", ...);
it("reports are limited to 20 per day per reporter identity", ...);
it("no plaintext, cipher, key, deviceId, accountId, inviteCode or excerpt is ever logged", async () => {
  // vi.spyOn(console, "log"|"warn"|"error"|"info"|"debug") 收集所有參數；跑完整流程（建立、帳號＋匿名加入、發言、設定、輪換、補封裝、ws、檢舉、離開、踢出、最後一人離開），
  // 並讓一次 D1 寫入失敗（fakeEnv 包 ACCOUNTS_DB.prepare 拋錯）、一次推播送出失敗（假 deps.push.send 對其中一個 token 拋錯）以觸發 console.error；
  // 斷言所有輸出字串不含任何一個測試用 payloadCipher、metaCipher、wrapped、pubKey、sig、deviceId（帳號成員的每台裝置與匿名裝置）、
  // pushToken、accountId、inviteCode、excerpt
});
it("push fan-out to a multi-device account reveals no device ids or tokens to members", async () => {
  // 帳號 B 綁 3 台裝置（各有 token）；A 發言後：A 的回應、B/C 的 GET /v3/groups/:id、events、keys、ws 訊框，
  // JSON 都不含 B 的任何 deviceId 或 token；PublicMember 的鍵集合恰為 {memberId, kind, accountId?, joinedAt, pubKey, pubKeySig?, hasKey}
});
it("no KV key or value carries a raw anonymous deviceId, and no wslog entry mentions a groupId", ...);
it("no response body or websocket frame ever contains a deviceId or push token", ...); // 收集上述流程所有回應 JSON 與 ws 訊框
// group-vectors.spec.ts
it("group-crypto.json vectors recompute in workerd", ...);
```

- [ ] **Step 2: 跑測試確認失敗**　`npm test -- src/__tests__/group-report-privacy.spec.ts src/__tests__/group-vectors.spec.ts` → FAIL。
- [ ] **Step 3: 實作** `/event/get`、檢舉路由、生成腳本、產生 JSON、`group-vectors.spec.ts`。
- [ ] **Step 4: 跑全套**　`npm test`（全綠）＋`npx tsc --noEmit`（0 錯）。
- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker/src/group.ts cloudflare-worker/src/groupRoom.ts cloudflare-worker/scripts/gen-group-vectors.mjs cloudflare-worker/test-vectors/group-crypto.json cloudflare-worker/src/__tests__/group-report-privacy.spec.ts cloudflare-worker/src/__tests__/group-vectors.spec.ts
git commit -m "feat: add group reports, privacy guards and shared group crypto vectors" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: 不執行，只回報**　把下方「部署前檢查表」與「回滾方式」原文附在完成報告中交給使用者；執行者不得自行執行其中任何 `wrangler` 指令、不得 push。

---

## 部署前檢查表（使用者執行；執行者只回報）

1. 本分支 `npx tsc --noEmit` 0 錯、`npm test` 全綠（含既有 diary／notes／rendezvous 套件）。
2. `wrangler.toml`：`v1`–`v6` 未被改動；`v7` 在最後、`new_sqlite_classes = ["GroupRoom"]`；`GROUP_ROOM` 綁定存在；`index.ts` 有 `export { GroupRoom }`（缺了會讓部署失敗）。
3. 正式 D1 先備份 `reports`：`wrangler d1 export ACCOUNTS_DB --remote --table reports --output reports-before-0005.sql`，並記下時間點（D1 Time Travel 回復用）。
4. 本機以真的 D1 SQLite 驗 0005：`wrangler d1 migrations apply ACCOUNTS_DB --local`（對本機副本，確認重建在真 D1 上不報錯）。
5. 確認 Workers 方案與 DO WebSocket 費用（§3.7）；沒有客戶端前成本為零，但 G1b 上線前要定用量告警。
6. 確認目前沒有任何已出貨客戶端呼叫 `/v3/groups*`（惰性）；G1b／G2 合併前，使用者看不到任何變化。
7. 合併到 `main` 會**自動**先套 0005、再部署。部署後驗：未帶憑證打 `GET /v3/groups` → 401；以測試帳號建立一個群組 → 201；`GET /v3/admin/reports` 仍正常；觀察 1 小時內 notes／diary 檢舉路由沒有 5xx。
8. 隱私標籤與隱私政策（§3.7）在 G2 送審前更新；本次部署不影響 App Store 狀態。

## 回滾方式（文字說明，不執行）

- **程式碼**：**不要**用 Cloudflare 介面回滾到 v7 之前的版本——DO migration 已套用，回到沒有 `GroupRoom` 類別的版本會被拒或造成綁定錯誤。正確做法是「向前修」：送一個 commit 保留 `groupRoom.ts`、`export { GroupRoom }`、`wrangler.toml` 的綁定與 `v7`，只拿掉 `index.ts` 的 `/v3/groups` 分派（全部回 404），合併後自動部署。真的要移除類別，需另寫 `[[migrations]] tag = "v8" deleted_classes = ["GroupRoom"]`（會刪掉所有群組資料，須使用者明確同意）。
- **D1**：0005 是單向的。`group_members`／`group_invites` 留著無害。`reports` 重建若出問題：優先寫 `0006` 向前修正；最後手段是 D1 Time Travel 回到第 3 點記下的時間點（`wrangler d1 time-travel restore ACCOUNTS_DB --timestamp=<時間>`），代價是遺失那之後寫入 D1 的所有資料（含帳號註冊），或用第 3 點的匯出檔手動補回 `reports`。若要把 `reporter_account_id` 改回 NOT NULL，必須先刪掉所有匿名檢舉列。
- **KV**：新增的鍵（`rl:groups:*`、`group-*`、`report-quota:dev:*`）都有 TTL，自行過期。

## 隱私與已知缺口說明（照抄進 PR 說明與 G2 的隱私說明頁）

- **伺服器看得到**：§3.2 清單全部，另加：帳號成員的推播在送出當下由伺服器查出該帳號所有裝置與 token（與紙條、日記相同機制，不另存）；匿名成員的裝置 ID 存在該房的 DO 內。
- **匿名不是對伺服器匿名**（§0.4 #2）：伺服器可經由裝置 ID 與 `account_devices` 把匿名成員連回帳號。
- **檢舉會跨房關聯匿名裝置**：匿名作者被檢舉時，`reports.sender_hash` 是其裝置 ID 的雜湊，營運者能看出同一台裝置在不同房間被檢舉（使用者 2026-10-25 接受）。
- **匿名參與沒有總房間數上限**：只有每台裝置每天 20 次加入（使用者 2026-10-25 接受）。
- **推播送到帳號的所有裝置**：包含沒有加入該房的裝置，內容一律是「有新訊息」（使用者 2026-10-25 決定）。
- **同帳號一次只有一台裝置在房內**：另一台以邀請碼加入會接手，前一台停用（Ruling 12）。
- **Mac 金鑰通道**：持有 Mac client key 且知道某帳號裝置 ID 的人，可代該帳號做建立者操作（踢人、關房、重設邀請、改參與設定）；塞假公鑰／假封裝會被伺服器驗章擋下（Ruling 19，沿用日記）。
- **建立者離線時不會立即輪換**（§3.4），被踢者在建立者下次上線前仍能解開期間的新訊息。
