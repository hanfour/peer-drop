# 子專案 1：帳號地基 — 設計規格

日期：2026-09-14
狀態：草稿，待使用者審閱
上位規格：`docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md` §2（帳號與暱稱目錄）、§1（現況與漏洞）、§5（客戶端架構）、§8（上架影響）
前置：子專案 0（寵物移除）已併入 main（PR #144）

---

## 0. 目標與範圍

**目標**：讓每台裝置在首次啟動後擁有一個伺服器核發、不可輪換的帳號 ID，可選設定唯一暱稱，並能用 ID 或暱稱查到對方的公鑰與信箱。這是紙條（子專案 2）與日記（子專案 3）共同依賴的地基。

**本子專案交付**
1. Worker：D1 資料庫與 migration 工具鏈、`/v3/account/*` 與 `/v3/directory/*` 路由、帳號範圍 token、擁有權綁定、App Attest 同時接受 iOS 與 Mac bundle ID。
2. 客戶端：新模組 `PeerDropAccount`（註冊、續期、暱稱、目錄查詢、加密落盤）、Mac 改走 App Attest 並移除內嵌 X-API-Key、引導頁與設定頁的帳號 UI（iOS + Mac）。
3. 順手修正：`/v2/inbox/:deviceId` 擁有權綁定；worker URL 的 UserDefaults 鍵統一。

**非目標（明列於 UI 與文件）**
- 換機還原、Apple ID 綁定、金鑰備份：換機即新帳號。
- 多裝置連結 UI：伺服器端已支援同一簽章金鑰綁多裝置，但 MVP 客戶端無金鑰搬移，實際仍是單裝置。
- 紙條收件匣、PoW challenge 路由（子專案 2）。
- 移除 app group / iCloud entitlements（等 `LegacyPetDataCleanup` 跑過一版之後，排在子專案 2 或 3 的釋出）。

**已定決策（使用者 2026-09-14）**
- 混合身分：匿名帳號自動建立，暱稱可選。
- **Mac 也走 App Attest**：worker 接受 `com.hanfour.peerdrop` 與 `com.hanfour.peerdrop.mac`；Mac build 移除內嵌 X-API-Key。無 Secure Enclave 的 Intel Mac 無法建帳號，只能用 P2P 功能，UI 要說明。

---

## 1. 現況（探索 2026-09-14）

| 項目 | 現況 | 本子專案的處置 |
|---|---|---|
| Token | `deviceToken.ts` 的 `TokenPayload {deviceId, scope, expires}`，`scope` 恆為 `"default"`，TTL 15 分鐘 | 新增 `account:<id>` scope；`/v2/device/assert` 續期時依裝置綁定自動帶出 |
| 授權閘 | `isRequestAuthorized` 只驗簽章、丟棄 payload；`requiresAuth` 是手寫路由清單 | 新增 `authorizeV3()` 回傳 `{accountId, deviceId}`；`/v2/inbox/:deviceId` 補綁定 |
| App Attest | 4 個呼叫點硬寫 `env.APP_BUNDLE_ID ?? "com.hanfour.peerdrop"`；`appAttest.ts` 以單一 rpIdHash 比對 | 改為集合比對，新 env `APP_BUNDLE_IDS` |
| 儲存 | 無 D1、無 SQL migration、`worker-deploy.yml` 不套用 migration | 新增 `ACCOUNTS_DB` binding、`migrations/`、npm script、deploy 步驟 |
| 客戶端驗證 | `DeviceTokenManager` 標 `@available(iOS 14.0, *)`；Mac 走 `WorkerAuthHelper.legacyAPIKey()` 讀 Info.plist 的 `PeerDropWorkerAPIKey` | 改 `@available(iOS 14.0, macOS 11.0, *)`；Mac Info.plist 移除該鍵 |
| Worker URL | 兩個 UserDefaults 鍵並存：`peerDropWorkerURL`（Settings、DeviceTokenManager）與 `workerBaseURL`（MailboxClient） | 統一為 `peerDropWorkerURL`，一次性搬移舊值 |
| 引導頁 | `OnboardingView` 五頁硬寫 `.tag(0…4)`，頁數魔數 4 出現四處 | 重構為頁面陣列，加帳號頁 |
| `TrustedContact.userId` | 從未寫入的佔位欄位 | 改名 `accountId`，由目錄查詢結果填入 |

---

## 2. 資料模型（D1）

`cloudflare-worker/migrations/0001_accounts.sql`

```sql
CREATE TABLE accounts (
  account_id    TEXT PRIMARY KEY,                -- 8 碼 Crockford base32，大寫，無連字號
  signing_key   BLOB NOT NULL UNIQUE,            -- Ed25519 公鑰 32 B（IdentityKeyManager.signingPublicKey）
  identity_key  BLOB NOT NULL UNIQUE,            -- X25519 公鑰 32 B（IdentityKeyManager.publicKey）
  nickname      TEXT UNIQUE COLLATE NOCASE,      -- NULL = 未設定
  mailbox_id    TEXT NOT NULL,                   -- 目前 pre-key 信箱，可隨 rotateMailbox 更新
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE account_devices (
  account_id    TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  device_id     TEXT NOT NULL,                   -- DeviceIdentity.deviceId（App Attest 綁定）
  platform      TEXT NOT NULL,                   -- 'ios' | 'macos'
  bound_at      INTEGER NOT NULL,
  PRIMARY KEY (account_id, device_id)
);
CREATE UNIQUE INDEX account_devices_device ON account_devices(device_id);  -- 一台裝置只屬一個帳號
```

- 帳號 ID：伺服器以 40 個隨機位元產生 8 碼 Crockford base32（字母表排除 I、L、O、U）；碰撞由 PK 擋下並重試最多 3 次。顯示格式 `XXXX-XXXX`。輸入正規化：去除連字號與空白、轉大寫、`I`/`L`→`1`、`O`→`0`。
- 暱稱：3–20 個字，允許 Unicode 字母（`\p{L}`）、數字（`\p{N}`）與底線，不允許空白與其他符號；以 NFC 正規化後存入；唯一性由 `COLLATE NOCASE` 索引處理（ASCII 大小寫不敏感；非 ASCII 依原字）。保留字：`admin`、`peerdrop`、`support`、`system`、`null`、`me`。
- `mailbox_id` 在 `/v3/account/register` 寫入，`POST /v2/mailbox/rotate` 成功後由 worker 一併更新（rotate 路由需帶帳號 token 才更新 D1；未帶則行為不變）。

---

## 3. Worker 路由與授權

### 3.1 App Attest 接受兩個 bundle ID
- 新 env `APP_BUNDLE_IDS`（逗號分隔），預設 `"com.hanfour.peerdrop,com.hanfour.peerdrop.mac"`；保留 `APP_BUNDLE_ID` 作為向後相容輸入（存在時併入集合）。
- `appAttest.ts` 的 `AttestationInput.bundleIdentifier` / `AssertionInput.bundleIdentifier` 改為 `bundleIdentifiers: string[]`；rpIdHash 對每個候選計算，任一 `constantTimeEq` 命中即通過；`attest:<deviceId>` KV 記錄新增 `bundleId` 欄位（命中的那個），assert 時只比對該 bundle 的 rpIdHash（防止跨 app 重放）。
- `vitest.config.mts` 與 `testSecrets.ts` 補 `APP_BUNDLE_IDS`；新測試：Mac bundle 的 attestation 通過、第三個 bundle 被拒、attest 用 iOS 而 assert 用 Mac 被拒。

### 3.2 帳號範圍 token
- `freshTokenPayload(deviceId, scope)` 已支援 scope；`/v2/device/attest` 與 `/v2/device/assert` 成功後查 `account_devices`：有綁定 → `scope = "account:<accountId>"`，否則 `"default"`。**客戶端不需感知**，`DeviceTokenManager` 照舊存 token。
- 新增 `authorizeV3(request, env): Promise<{deviceId, accountId} | null>`：解析 Bearer（僅 header，不接受 `?token=`）、`verifyToken`、要求 `scope` 以 `account:` 開頭；回傳兩個 ID。**不接受 X-API-Key**。
- `/v3/*` 路由自成閘門（不加入 `requiresAuth` 清單），每條先呼叫 `authorizeV3`，路徑含 `:accountId` 者再比對相等，否則 403 `{error:"forbidden"}`。
- 修既有漏洞：`/v2/inbox/:deviceId` WS 升級改為 `verifyToken` 後比對 `payload.deviceId === :deviceId`（X-API-Key 操作者金鑰仍放行，供 CLI）。新增 `auth.spec.ts` 案例：A 裝置 token 開 B 的 inbox 回 403。

### 3.3 路由

| 路由 | 授權 | 說明 |
|---|---|---|
| `POST /v3/account/challenge` | 裝置 token（任一 scope） | body `{deviceId}`；回 `201 {nonce}`（32 B base64；KV `acct-challenge:<deviceId>`，5 分鐘，單次） |
| `POST /v3/account/register` | 裝置 token（任一 scope），`payload.deviceId === body.deviceId` | body `{deviceId, platform, identityKey, signingKey, mailboxId, nonce, signature}`（金鑰與 nonce 皆 base64）。驗 nonce 存在並刪除；驗 `signature` = Ed25519 對 `"peerdrop-account-v1" ‖ nonce(32 B) ‖ utf8(deviceId)` 的簽章；`signing_key` 已存在 → 綁定新裝置（若該 device 已綁其他帳號 → 409 `device_bound`），否則建帳號。回 `201 {accountId, nickname, token, expiresInSeconds}`，`token` 為 `account:` scope。 |
| `GET /v3/account/me` | 帳號 token | 回 `{accountId, nickname, mailboxId, devices:[{deviceId, platform, boundAt}]}` |
| `PUT /v3/account/nickname` | 帳號 token | body `{nickname}` 或 `{nickname:null}` 清除；驗規則 → 400 `invalid_nickname`；保留字 → 400 `reserved`；重複 → 409 `nickname_taken`；每帳號每日 5 次（KV 計數）→ 429。回 `{nickname}` |
| `GET /v3/directory/:handle?bundle=0|1` | 帳號 token | `handle` 正規化後先當帳號 ID 查，再當暱稱查；回 `{accountId, nickname, identityKey, signingKey, mailboxId, preKeyBundle?}`；`bundle=1` 時經 `PREKEY_STORE` DO 取 bundle 並消耗一把 OPK（子專案 2 送出時才用，避免瀏覽就耗 OPK）；找不到 404。每帳號每分鐘 30 次（KV 計數）→ 429 |
| `DELETE /v3/account` | 帳號 token | 刪帳號與裝置綁定（D1 CASCADE）；不動 pre-key 信箱（由既有 `DELETE /v2/keys` 處理）。供設定頁「刪除帳號」與 App Store 帳號刪除規範 |

所有回應走既有 `jsonResponse`；錯誤格式 `{error: "<code>"}`。body 上限 4 KB。

### 3.4 D1 工具鏈
- `wrangler.toml` 新增 `[[d1_databases]] binding = "ACCOUNTS_DB" database_name = "peerdrop-accounts" database_id = "<operator 建立後填入>" migrations_dir = "migrations"`。
- `package.json` 新增 `d1:migrate:local`（`wrangler d1 migrations apply ACCOUNTS_DB --local`）與 `d1:migrate:remote`。
- `worker-deploy.yml` 的 deploy job 在 `wrangler deploy` 前加 `npx wrangler d1 migrations apply ACCOUNTS_DB --remote`。
- `vitest.config.mts`：`cloudflareTest` 讀 `wrangler.toml` 會自動帶入 D1；測試 `beforeAll` 以 `env.ACCOUNTS_DB.exec()` 套用 migration SQL（讀檔）。
- **Operator 前置**：`wrangler d1 create peerdrop-accounts` 一次，把 `database_id` 填入 `wrangler.toml` 並 commit。這一步不在計畫任務內，但沒有它 deploy 會失敗——計畫首個任務要有檢查。

---

## 4. 客戶端

### 4.1 新模組 `PeerDropKit/Sources/PeerDropAccount`
依賴 `PeerDropSecurity`、`PeerDropTransport`、`PeerDropPlatform`。

```
AccountID.swift        struct AccountID: Hashable, Codable { let raw: String /* 8 碼大寫 */ }
                       static func parse(_ input: String) -> AccountID?   // 正規化：去連字號/空白、大寫、I/L→1、O→0，長度 8，字母表檢查
                       var display: String                                // "XXXX-XXXX"
Nickname.swift         enum NicknameValidation { case ok(String) /* NFC */, tooShort, tooLong, invalidCharacters, reserved }
                       static func validate(_: String) -> NicknameValidation
Account.swift          struct Account: Codable { let accountId: AccountID; var nickname: String?; var mailboxId: String; let createdAt: Date }
AccountClient.swift    actor AccountClient { init(baseURL: URL? = nil, session: URLSession = …)
                         func challenge(deviceId:) async throws -> Data
                         func register(_ req: RegisterRequest) async throws -> RegisterResponse
                         func me() async throws -> MeResponse
                         func setNickname(_: String?) async throws -> String?
                         func lookup(handle: String, includeBundle: Bool) async throws -> DirectoryEntry?   // 404 → nil
                         func deleteAccount() async throws }
                       // 每個請求經 WorkerAuthHelper.applyAuth；401 一次 → DeviceTokenManager 重新取 token 後重試一次
                       enum AccountClientError: Error { case notSupported, unauthorized, forbidden, conflict(String), invalid(String), rateLimited, http(Int), invalidResponse }
AccountStore.swift     final class AccountStore { init(storageKey: String = "account")
                         func load() -> Account?; func save(_: Account) throws; func clear() throws }
                       // Documents/Security/<scopedKey(storageKey)>.enc，經 ChatDataEncryptor；使用 PeerDropPersistence.scopedKey（CLI namespace 友善）
AccountManager.swift   @MainActor final class AccountManager: ObservableObject {
                         enum State: Equatable { case unavailable(Reason) /* .attestUnsupported | .offline | .failed(String) */, registering, ready(Account) }
                         @Published private(set) var state: State
                         init(client:, store:, identity: IdentityKeyManager = .shared, mailbox: MailboxManager, deviceId: String, platform: String)
                         func bootstrap() async          // 啟動時：有存檔 → ready；否則 registerIfNeeded
                         func registerIfNeeded() async   // mailbox.registerIfNeeded() → challenge → sign → register → save
                         func setNickname(_: String?) async throws
                         func lookup(handle:) async throws -> DirectoryEntry?
                         func refreshFromServer() async  // GET me，同步暱稱
                         func deleteAccount() async throws }
```

- 簽章訊息組裝與伺服器一致：`Data("peerdrop-account-v1".utf8) + nonce + Data(deviceId.utf8)`，用 `IdentityKeyManager.shared.sign(_:)`。
- `DeviceTokenManager`：`@available(iOS 14.0, macOS 11.0, *)`；`WorkerAuthHelper` 同步放寬。`DCAppAttestService.isSupported == false` → `AccountManager.state = .unavailable(.attestUnsupported)`。
- **Mac 移除 X-API-Key**：`PeerDropMac/App/Info.plist` 刪 `PeerDropWorkerAPIKey`；`project.yml` 的 Mac target 不再綁 `Secrets.xcconfig`（Release 也不綁）。`WorkerAuthHelper.legacyAPIKey()` 保留（CLI 用 env `PEERDROP_WORKER_KEY`）。
- Worker URL 統一：`MailboxClient` 改讀 `peerDropWorkerURL`；`ConnectionManager` 啟動時若 `workerBaseURL` 有值且 `peerDropWorkerURL` 無值則搬移後刪除舊鍵。
- `PeerDropCore`：`ConnectionManager` 持有 `let accountManager: AccountManager`（與 `chatManager` 同模式），在 `handleScenePhaseChange(.active)` 呼叫 `bootstrap()`（首次）；`TrustedContact.userId` → `accountId`（Codable key 沿用 `userId` 以相容舊檔，屬性改名）；`approveFirstContact` 之後若對方 envelope 帶 `senderAccountId`（子專案 2 才會有）再填。
- `ScreenshotModeProvider.mockAccount: Account`（ID `PDRP-DEMO`，暱稱依語系：`mochi` / `麻糬` / `麻薯` / `もち` / `모찌`）。

### 4.2 UI

**引導頁（iOS）**：`OnboardingView` 重構為 `pages: [OnboardingPageModel]`（`icon`、`title`、`subtitle`、可選 `content: AnyView`），去掉魔數。新增第 4 頁「你的 PeerDrop ID」：顯示 `AccountManager.state`——`registering` 轉圈、`ready` 顯示 `XXXX-XXXX` 與「複製」、暱稱 `TextField`（即時驗證，錯誤文案五語）、`unavailable` 顯示原因與「稍後在設定中重試」。引導頁不阻擋完成：使用者可略過，帳號在背景持續重試。

**設定頁**：iOS `SettingsView` 新增 `Section("Account")`：ID 列（`LabeledContent` + 複製）、暱稱 `NavigationLink` → `NicknameEditorView`、狀態列（未就緒時顯示原因與「重試」）、「刪除帳號」（確認對話框）。Mac `MacSettingsView` 的 Profile tab 加同樣四列（共用 `AccountSectionView`，放 `PeerDrop/UI/Account/`，無 UIKit）。

**既有使用者升級**：無引導頁；`bootstrap()` 於首次 `.active` 背景註冊；失敗不打擾，設定頁可見狀態。子專案 2/3 的分頁在 `state != .ready` 時顯示「帳號尚未就緒」卡片而非隱藏（依 Guideline 2.1(b) 教訓）。

**字串**：新增約 20 個鍵，五語。

### 4.3 錯誤與離線
- 註冊失敗分類：`attestUnsupported`（永久，UI 說明 Intel Mac）、`offline`／5xx（自動重試：下次 `.active` 與 60 秒後各一次，之後每次 `.active`）、4xx（顯示錯誤碼，提供重試）。
- 所有持久化失敗浮現到 `state = .unavailable(.failed(msg))`，不 `try?` 吞掉（上位規格 §5.1）。

---

## 5. 測試

- **Worker**（vitest + miniflare D1）：`account.spec.ts`（challenge 單次、簽章錯誤 400、建帳號、同簽章金鑰第二台裝置綁定、device 已綁他帳號 409、ID 正規化查詢、暱稱規則/保留字/重複/每日 5 次、目錄 `bundle=1` 消耗 OPK、`bundle=0` 不消耗、404、每分鐘 30 次、`DELETE /v3/account` 級聯）；`auth.spec.ts` 擴充（`/v3` 拒絕 `default` scope 與 X-API-Key、`:accountId` 不符 403、`/v2/inbox` 綁定）；`appAttest.spec.ts` 多 bundle。
- **客戶端**：`AccountIDTests`（parse/display/正規化向量）、`NicknameTests`、`AccountStoreTests`（`FileStore.namespace` 隔離、毒檔）、`AccountClientTests`（`MockURLProtocol`：401 重試一次、409/429 對應錯誤）、`AccountManagerTests`（狀態機：unsupported、offline 重試、ready）。
- **CI**：既有 `xcodebuild-apps` job 涵蓋 UI 編譯；worker job 涵蓋 vitest。
- **E2E（operator）**：iPhone 與 Mac 各自註冊 → 互查目錄 → 設暱稱 → 改名釋放舊名。

---

## 6. 上架與合規

- 隱私標籤：iOS 與 Mac 兩個 ASC 記錄從「不收集資料」改為收集「使用者 ID」（帳號 ID、裝置 ID）與「名稱」（暱稱），連結到使用者、用於 App 功能；`PrivacyInfo.xcprivacy` 同步。
- App Store 帳號刪除規範（Guideline 5.1.1(v)）：設定頁提供「刪除帳號」，呼叫 `DELETE /v3/account`。
- Mac 版移除內嵌 X-API-Key 後，無 Secure Enclave 的 Mac 失去帳號功能；release notes 說明。

---

## 7. 風險

| 風險 | 處置 |
|---|---|
| D1 database_id 未填即部署 | 計畫首任務加 `wrangler.toml` 檢查；deploy 步驟在 migration 失敗時中止 |
| App Attest 在 Mac 上的 `isSupported` 行為未實測 | 計畫含一個 spike：在此 Mac 上以 dev build 跑一次 attest 全流程；失敗則回退決策（沿用 X-API-Key）並記錄 |
| 舊客戶端持 `default` scope token 呼叫 `/v3` | 401，客戶端以 `/v2/device/assert` 續期後即帶 `account:` scope（伺服器依綁定決定） |
| 暱稱大小寫規則對非 ASCII 不一致 | 文件明示：NOCASE 只對 ASCII；後續可改為 `LOWER()` 儲存正規化欄位 |
| `MailboxClient` 換 UserDefaults 鍵 | 一次性搬移；CLI 沒有 `--worker-url` 參數、同樣經 `MailboxClient()` 預設值讀 UserDefaults，搬移後行為一致 |
