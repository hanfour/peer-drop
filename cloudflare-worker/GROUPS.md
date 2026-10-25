# 群組聊天室伺服器（G1a）：部署、回滾、已知缺口與客戶端契約

> 對應規格：`docs/superpowers/specs/2026-10-24-project-f-g-categories-group-rooms-design.md` §3；計畫：`docs/superpowers/plans/2026-10-25-project-g1a-group-room-server.md`。
> **合併到 main 會自動套用 D1 0005 並部署 Worker（含 DO migration v7，不可用 Cloudflare 介面回滾）。合併前務必先完成下方第 3 點的 `reports` 備份。**

## 部署前檢查表（使用者執行；執行者只回報）

1. 本分支 `npx tsc --noEmit` 0 錯、`npm test` 全綠（含既有 diary／notes／rendezvous 套件）。
2. `wrangler.toml`：`v1`–`v6` 未被改動；`v7` 在最後、`new_sqlite_classes = ["GroupRoom"]`；`GROUP_ROOM` 綁定存在；`index.ts` 有 `export { GroupRoom }`（缺了會讓部署失敗）。
3. 正式 D1 先備份 `reports`：`wrangler d1 export ACCOUNTS_DB --remote --table reports --output reports-before-0005.sql`，並記下時間點（D1 Time Travel 回復用）。
4. 本機以真的 D1 SQLite 驗 0005：`wrangler d1 migrations apply ACCOUNTS_DB --local`（對本機副本，確認重建在真 D1 上不報錯）。
5. 確認 Workers 方案與 DO WebSocket 費用（§3.7）；沒有客戶端前成本為零，但 G1b 上線前要定用量告警。
6. 確認目前沒有任何已出貨客戶端呼叫 `/v3/groups*`（惰性）；G1b／G2 合併前，使用者看不到任何變化。
7. 合併到 `main` 會**自動**先套 0005、再部署。部署後驗：未帶憑證打 `GET /v3/groups` → 401；以測試帳號建立一個群組 → 201；`GET /v3/admin/reports` 仍正常；觀察 1 小時內 notes／diary 檢舉路由沒有 5xx。
8. 隱私標籤與隱私政策（§3.7）在 G2 送審前更新；本次部署不影響 App Store 狀態。

補充（已對照 `.github/workflows/worker-deploy.yml`）：
- workflow 在 push 到 `main`、且變更涉及 `cloudflare-worker/**` 時觸發。順序是 `test` job（`npm ci` → `tsc --noEmit` → `vitest run`）→ `deploy` job：`npx wrangler d1 migrations apply ACCOUNTS_DB --remote` → `npx wrangler deploy`。
- D1 migration 只套用 `d1_migrations` 表裡還沒有的檔案，所以 0005 只會跑一次。0005 的重建是一次性的，不能重跑。
- 0005 會比新程式碼早幾秒上線。舊的 notes／diary 檢舉 INSERT 都明確列出欄位，所以相容。
- PR 本身只會跑 test job，不會部署。

## 回滾方式（文字說明，不執行）

- **程式碼**：**不要**用 Cloudflare 介面回滾到 v7 之前的版本——DO migration 已套用，回到沒有 `GroupRoom` 類別的版本會被拒或造成綁定錯誤。正確做法是「向前修」：送一個 commit 保留 `groupRoom.ts`、`export { GroupRoom }`、`wrangler.toml` 的綁定與 `v7`，只拿掉 `index.ts` 的 `/v3/groups` 分派（全部回 404），合併後自動部署。真的要移除類別，需另寫 `[[migrations]] tag = "v8" deleted_classes = ["GroupRoom"]`（會刪掉所有群組資料，須使用者明確同意）。
- **D1**：0005 是單向的。`group_members`／`group_invites` 留著無害。`reports` 重建若出問題：優先寫 `0006` 向前修正；最後手段是 D1 Time Travel 回到第 3 點記下的時間點（`wrangler d1 time-travel restore ACCOUNTS_DB --timestamp=<時間>`），代價是遺失那之後寫入 D1 的所有資料（含帳號註冊），或用第 3 點的匯出檔手動補回 `reports`。若要把 `reporter_account_id` 改回 NOT NULL，必須先刪掉所有匿名檢舉列。
- **KV**：新增的鍵（`rl:groups:*`、`group-*`、`report-quota:dev:*`）都有 TTL，自行過期。

補充：
- **例外**：`group-gone:<groupId>` 墓碑是**永久**的，沒有 TTL（Ruling 11，讓被清空的 id 不能再被建立）。留著無害。
- KV 是最終一致的：墓碑寫入後，在其他地區可能要約 60 秒才看得到。極少數情況下，房間剛被清空後的短時間內，同一個 id 可能被重新建立（Task 6 parked）。
- 一則訊息若有 49 位收件人，**子請求總數**可能逼近上限：帳號成員每人 1 次 D1，每台裝置再各 1 次 KV 與 1 次送出，合計約 250 次。同時連線數已限制為 6，但總數沒有減少。G1b 上線前應改成批次查詢裝置，或改用 Queue。

## 隱私與已知缺口說明（照抄進 PR 說明與 G2 的隱私說明頁）

- **伺服器看得到**：§3.2 清單全部，另加：帳號成員的推播在送出當下由伺服器查出該帳號所有裝置與 token（與紙條、日記相同機制，不另存）；匿名成員的裝置 ID 存在該房的 DO 內。
- **匿名不是對伺服器匿名**（§0.4 #2）：伺服器可經由裝置 ID 與 `account_devices` 把匿名成員連回帳號。
- **檢舉會跨房關聯匿名裝置**：匿名作者被檢舉時，`reports.sender_hash` 是其裝置 ID 的雜湊，營運者能看出同一台裝置在不同房間被檢舉（使用者 2026-10-25 接受）。
- **匿名參與沒有總房間數上限**：只有每台裝置每天 20 次加入（使用者 2026-10-25 接受）。
- **推播送到帳號的所有裝置**：包含沒有加入該房的裝置，內容一律是「有新訊息」（使用者 2026-10-25 決定）。
- **同帳號一次只有一台裝置在房內**：另一台以邀請碼加入會接手，前一台停用（Ruling 12）。
- **Mac 金鑰通道**：持有 Mac client key 且知道某帳號裝置 ID 的人，可代該帳號做建立者操作（踢人、關房、重設邀請、改參與設定）；塞假公鑰／假封裝會被伺服器驗章擋下（Ruling 19，沿用日記）。
- **建立者離線時不會立即輪換**（§3.4），被踢者在建立者下次上線前仍能解開期間的新訊息。

補充（本分支累積下來、也應寫進 PR 說明的項目）：
- **匿名檢舉人**：`reports.reporter_device_id` 存的是原始裝置 ID，營運者在 admin 介面看得到（§0.4 #3）。
- **雙重身分踢出**：同一台裝置可以同時以帳號與匿名身分在同一個房間。踢掉其中一個身分時，會封鎖該裝置已驗證過的身分，但另一個身分的座位要另外踢（Task 4 parked）。
- **KV 墓碑與配額的一致性**：墓碑是最終一致的；配額計數器不是原子操作，高並發時可能少算一點。
- **子請求總數**：49 位收件人時的推播子請求總數，見上方回滾段的補充。

## G1b／G2 客戶端必須實作的事項（伺服器契約）

- **WebSocket**：
  - 先 `POST /v3/groups/:id/ws-ticket`（帶 Bearer 與 `X-Group-Member-Id`）取得 `{ticket, expiresInSeconds:60}`。票券只能用一次，再以 `GET /v3/groups/:id/ws?ticket=…` 升級。升級請求不看 Authorization，長效 Bearer 絕不能放進網址。
  - 每 30 秒送一次**文字**訊框，內容剛好是 `"ping"`，伺服器回 `"pong"`。協定層的 ping 不算數；超過 90 秒沒聲音就視為未連線（會改送推播）。
  - 每條連線最多 2 小時。伺服器送出的下行訊框只有 `{"t":"ev","e":GroupEvent}`；客戶端送上去的其他訊框一律被忽略。發言一律走 HTTP。
- **關閉碼**：
  - `4000` replaced：同一成員開了第三條連線，最舊的那條被關。
  - `4001` expired：到了 2 小時上限。重新拿票券連線，再用 `GET events?since=<最後 seq>` 補抓。
  - `4003` removed：已經不是成員（離開、被踢，或被自己另一台裝置接手），**不要再重連**。
- **事件 schema**：`{seq, eventId, type: msg|join|leave|kick|meta, authorMemberId, epoch, payloadCipher?, targetMemberId?, ownerMemberId?, metaVersion?, rotated?, createdAt}`。
  - `meta` 事件帶 `metaVersion`；由輪換產生的 meta 事件另帶 `rotated: true`。
  - **以 `eventId` 去重**，因為 ws 和補抓可能拿到同一筆。
  - `GET events` 會回 `firstSeq`；`since < firstSeq-1` 表示中間有缺口（已被裁剪）。
- **推播**：
  - alert 是 `loc-key: "GROUP_MESSAGE"`，客戶端要在 5 種語言（en、zh-Hant、zh-Hans、ja、ko）都提供這個字串，內容等同「有新訊息」，不含群名與發話者。data 為 `{type:"groupMessage", groupId}`。
  - 靜默推播 `{type:"groupKeyRequest", groupId}` 表示有成員在等金鑰，帳號成員要幫忙補封裝。
  - 收到推播時，本機可能沒有這個房間（帳號的其他裝置也會收到），這種情況就當作「同步一下」處理。
- **標頭**：所有成員路由都要帶 `X-Group-Member-Id`。匿名身分只能走 Bearer。
- **簽章與封裝格式**：以 `cloudflare-worker/test-vectors/group-crypto.json` 為準，G1b 的 `GroupCrypto` 測試必須讀同一個檔案。
  - memberKey 簽章：`"PDGRPMK1"‖groupId‖memberId‖accountId‖pubKey`
  - wrap 簽章：`"PDGRPWK1"‖groupId‖UInt32BE(epoch)‖target‖wrapper‖wrapped`
  - wrap 本體：X25519 → HKDF-SHA256（salt＝ephPub‖recipientPub，info＝`peerdrop-group-wrap-v1`）→ AES-256-GCM，AAD＝`groupId‖UInt32BE(epoch)‖recipientMemberId`，結果共 92 B。
  - message 的 AAD：`groupId‖memberId‖eventId‖UInt32BE(epoch)`
  - metaCipher 的 AAD：`groupId‖UInt32BE(epoch)‖"meta"`
  - 伺服器雖然也會驗章，客戶端仍須自己驗。
- **常見錯誤碼**：
  - Ruling 12 的舊裝置會收到 403 `not_member`，客戶端應把該房標成「已在其他裝置使用」。
  - 等待金鑰時發言回 403 `awaiting_key`；世代不對回 409 `stale_epoch`（附上現行 `epoch`）。
  - 輪換時成員已變動回 409 `members_changed`（附上現行 `memberIds`）。
  - `rotationDue: true` 時，建立者的客戶端要補做輪換。
- **檢舉**：`POST /v3/groups/:id/events/:seq/report {reason, excerpt?}`。excerpt 是客戶端自願附上的解密摘要，最多 1,000 字。

## 上線前要決定的事（最終審查提出）

- `/v3/groups*` 目前共用一個每 IP 每分鐘 30 次的 `groups` 額度（`RATE_LIMIT_MAX_REQUESTS`）。發言、補抓、金鑰、檢視都走 HTTP，同一個 Wi‑Fi 或電信 NAT 後的多位成員會共用額度。G1b 客戶端上線前要調高或改成每帳號限流。
- 檢舉的 `sender_hash` 以 memberId 解析作者：作者被接手（Ruling 12）或離開再加入後，舊訊息的 `sender_hash` 為 NULL，會讓檢舉較難串連（已知缺口）。
- 同一台裝置同時以匿名與帳號身分在同一房間時，會收到兩次推播。
- `DELETE /v3/account` 不會清掉 `group_members` 與房間內座位（與日記相同）。
