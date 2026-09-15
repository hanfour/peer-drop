# 子專案 1：帳號地基 — 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 每台裝置在首次啟動後取得伺服器核發的 8 碼帳號 ID（綁定既有 Ed25519 簽章金鑰），可選唯一暱稱，並能用 ID 或暱稱查到對方的公鑰與信箱；Mac 改走 App Attest。

**Architecture:** Worker 端新增 D1 資料庫（`ACCOUNTS_DB`）、`/v3/account/*` 與 `/v3/directory/*` 路由、帳號範圍 token（`account:<id>`，由既有 attest/assert 依裝置綁定自動帶出）、App Attest 多 bundle 比對。客戶端新增 SwiftPM 模組 `PeerDropAccount`（值型別 + `AccountClient` actor + `AccountStore` + `@MainActor AccountManager` 狀態機），由 `ConnectionManager` 持有並在 `.active` 時 bootstrap；iOS 引導頁與設定頁、Mac Profile 分頁加帳號 UI。先 worker（T1–T5）後客戶端（T6–T11），最後本機 E2E（T12）。

**Tech Stack:** Cloudflare Workers（TypeScript、D1、KV、vitest + `@cloudflare/vitest-pool-workers`、wrangler 4）、Swift 5.9 / SwiftUI / CryptoKit / DeviceCheck、SwiftPM、XcodeGen、XCTest。

**Spec:** `docs/superpowers/specs/2026-09-14-account-foundation-design.md`（上位：`docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md` §2）

## Global Constraints

- 分支：`feat/account-foundation`，從 `main`（含 PR #144）分出。
- Commit 格式 `type(scope): short description`，空行，結尾兩行 trailer（逐字）：
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WwzkHxSjp7ou9MgGct5irQ
  ```
- Worker 測試：`cd cloudflare-worker && npm test`（`scripts/run-tests.sh` 會 rsync 到無空白路徑）；CI 用 `npx vitest run`。Worker 併入 main 會自動部署，**T1–T5 的每個任務都必須讓舊 iOS/Mac 客戶端行為不變**（新路由只加不改；attest/assert 回應形狀不變）。
- 客戶端建置閘：`cd PeerDropKit && swift build && swift test --filter <Class>`；iOS `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`；Mac `xcodebuild build -scheme PeerDropMac -destination 'platform=macOS,arch=arm64' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -quiet`。新增/刪除 `.swift` 或改 `project.yml` 後必跑 `xcodegen generate` 並提交 pbxproj。
- 本機已知的 `swift test` 失敗：`IdentityKeyManagerTests.testKeyPersistsAcrossInstances`（keychain 在 `swift test` 沙盒不可用），非回歸。
- 帳號 ID 字母表（Crockford base32，32 字元，逐字）：`0123456789ABCDEFGHJKMNPQRSTVWXYZ`。ID 長度 8。顯示 `XXXX-XXXX`。正規化：去除 `-` 與空白、大寫、`I`/`L`→`1`、`O`→`0`。
- 暱稱：NFC 後 3–20 個 Unicode scalar，僅 `\p{L}`、`\p{N}`、`_`；保留字（不分大小寫）：`admin`、`peerdrop`、`support`、`system`、`null`、`me`。
- 簽章訊息：~~`utf8("peerdrop-account-v1") ‖ nonce(32 B) ‖ utf8(deviceId)`~~ → **最終修正波（2026-09-15）改為 v2：`utf8("peerdrop-account-v2") ‖ nonce(32 B) ‖ utf8(deviceId) ‖ sha256(identityKey(32 B) ‖ utf8(mailboxId))`**，Ed25519。v1 沒把 identityKey 與 mailboxId 納入簽章，兩者都可被替換。
- Token TTL 維持 15 分鐘；`account:` scope 字串格式 `account:<accountId>`。
- 錯誤回應 `{error: "<code>"}`；`/v3` 不接受 X-API-Key、不接受 `?token=`。
- 五語系（en、zh-Hant、zh-Hans、ja、ko）；字串以文字方式插入 `PeerDrop/App/Localizable.xcstrings`（格式見 T10）。
- Bundle ID：iOS `com.hanfour.peerdrop`、Mac `com.hanfour.peerdrop.mac`；Team `UK48R5KWLV`。

---

## 檔案總覽

**Worker（`cloudflare-worker/`）**
- Create: `migrations/0001_accounts.sql`、`src/account.ts`（ID 產生、暱稱驗證、簽章驗證、D1 存取）、`src/__tests__/d1.ts`（測試用 migration 套用）、`src/__tests__/account.spec.ts`、`src/__tests__/directory.spec.ts`、`src/__tests__/appAttestBundles.spec.ts`
- Modify: `wrangler.toml`、`package.json`、`vitest.config.mts`、`src/__tests__/testSecrets.ts`、`src/index.ts`（Env、attest/assert、authorizeV3、/v3 路由、inbox 綁定、mailbox rotate）、`src/appAttest.ts`（多 bundle）、`src/__tests__/auth.spec.ts`、`.github/workflows/worker-deploy.yml`

**客戶端**
- Create: `PeerDropKit/Sources/PeerDropAccount/{AccountID,Nickname,Account,AccountStore,AccountClient,AccountManager}.swift`、`PeerDropKit/Tests/PeerDropAccountTests/{AccountIDTests,NicknameTests,AccountStoreTests,AccountClientTests,AccountManagerTests,TestURLProtocol}.swift`
- Create: `PeerDrop/UI/Account/AccountSectionView.swift`、`PeerDrop/UI/Account/NicknameEditorView.swift`、`PeerDrop/UI/Onboarding/OnboardingAccountPage.swift`
- Modify: `PeerDropKit/Package.swift`、`project.yml`、`PeerDropKit/Sources/PeerDropTransport/{DeviceTokenManager,WorkerAuthHelper,MailboxClient}.swift`、`PeerDropMac/App/Info.plist`、`PeerDropKit/Sources/PeerDropCore/{ConnectionManager,ScreenshotModeProvider}.swift`、`PeerDropKit/Sources/PeerDropSecurity/TrustedContact.swift`、`PeerDrop/UI/OnboardingView.swift`、`PeerDrop/UI/SettingsView.swift`、`PeerDropMac/Views/MacSettingsView.swift`、`PeerDrop/App/Localizable.xcstrings`

---

### Task 1: D1 工具鏈與 schema

**Files:**
- Create: `cloudflare-worker/migrations/0001_accounts.sql`、`cloudflare-worker/src/__tests__/d1.ts`、`cloudflare-worker/src/__tests__/d1.spec.ts`
- Modify: `cloudflare-worker/wrangler.toml`、`cloudflare-worker/package.json`、`cloudflare-worker/src/index.ts:21-59`（`Env`）、`.github/workflows/worker-deploy.yml:31-51`

**Interfaces:**
- Produces: `Env.ACCOUNTS_DB: D1Database`；資料表 `accounts`、`account_devices`（欄位見 Step 2）；測試輔助 `applyMigrations(db: D1Database): Promise<void>`；npm script `d1:migrate:local` / `d1:migrate:remote`。

- [ ] **Step 1: 取得 D1 database_id**

Run: `cd cloudflare-worker && npx wrangler whoami 2>&1 | tail -3`
- 若已登入：`npx wrangler d1 create peerdrop-accounts` 並記下輸出的 `database_id`。
- 若未登入（輸出含 `not authenticated`）：使用佔位 `database_id = "00000000-0000-0000-0000-000000000000"`（miniflare 測試不需要真實 id），並在報告中以 **BLOCKED-FOR-DEPLOY** 標記：operator 需在併入 main 前執行 `wrangler d1 create peerdrop-accounts` 並替換此值。

- [ ] **Step 2: 寫 migration**

`cloudflare-worker/migrations/0001_accounts.sql`：
```sql
-- 0001_accounts: anonymous accounts bound to the device's Ed25519 signing key.
CREATE TABLE IF NOT EXISTS accounts (
  account_id    TEXT PRIMARY KEY,
  signing_key   BLOB NOT NULL UNIQUE,
  identity_key  BLOB NOT NULL UNIQUE,
  nickname      TEXT UNIQUE COLLATE NOCASE,
  mailbox_id    TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS account_devices (
  account_id    TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  device_id     TEXT NOT NULL,
  platform      TEXT NOT NULL,
  bound_at      INTEGER NOT NULL,
  PRIMARY KEY (account_id, device_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS account_devices_device ON account_devices(device_id);
```

- [ ] **Step 3: wrangler.toml、package.json、Env、deploy**

`wrangler.toml` 在 `[[durable_objects.bindings]]` 之前加：
```toml
[[d1_databases]]
binding = "ACCOUNTS_DB"
database_name = "peerdrop-accounts"
database_id = "<Step 1 的值>"
migrations_dir = "migrations"
```
`package.json` scripts 加：
```json
"d1:migrate:local": "wrangler d1 migrations apply ACCOUNTS_DB --local",
"d1:migrate:remote": "wrangler d1 migrations apply ACCOUNTS_DB --remote"
```
`src/index.ts` 的 `Env` 介面在 `DEVICE_INBOX: DurableObjectNamespace;` 之後加 `ACCOUNTS_DB: D1Database;`。

`.github/workflows/worker-deploy.yml` deploy job 的 `Deploy via wrangler` step 之前插入：
```yaml
      - name: Apply D1 migrations
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
        run: npx wrangler d1 migrations apply ACCOUNTS_DB --remote
```

- [ ] **Step 4: 測試輔助與失敗測試**

`src/__tests__/d1.ts`：
```ts
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/** Apply every migrations/*.sql file (sorted) to a miniflare D1 binding. */
export async function applyMigrations(db: D1Database): Promise<void> {
  const dir = join(__dirname, "..", "..", "migrations");
  const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
  for (const f of files) {
    const sql = readFileSync(join(dir, f), "utf8");
    const statements = sql.split(";").map((s) => s.trim()).filter((s) => s.length > 0 && !s.startsWith("--"));
    for (const stmt of statements) {
      await db.prepare(stmt).run();
    }
  }
}
```
`src/__tests__/d1.spec.ts`：
```ts
import { env } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";

describe("D1 accounts schema", () => {
  beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

  it("creates accounts and account_devices with the unique device index", async () => {
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, mailbox_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 0, 0)"
    ).bind("ABCDEFGH", new Uint8Array(32), new Uint8Array([1, ...new Array(31).fill(0)]), "mbx").run();
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES ('ABCDEFGH', 'dev-1', 'ios', 0)"
    ).run();
    const dup = env.ACCOUNTS_DB.prepare(
      "INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES ('ABCDEFGH', 'dev-1', 'macos', 0)"
    ).run();
    await expect(dup).rejects.toThrow();
    const row = await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM account_devices").first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("nickname uniqueness is case-insensitive", async () => {
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, nickname, mailbox_id, created_at, updated_at) VALUES ('AAAAAAA1', ?1, ?2, 'Mochi', 'm1', 0, 0)"
    ).bind(new Uint8Array([2, ...new Array(31).fill(0)]), new Uint8Array([3, ...new Array(31).fill(0)])).run();
    const dup = env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, nickname, mailbox_id, created_at, updated_at) VALUES ('AAAAAAA2', ?1, ?2, 'mochi', 'm2', 0, 0)"
    ).bind(new Uint8Array([4, ...new Array(31).fill(0)]), new Uint8Array([5, ...new Array(31).fill(0)])).run();
    await expect(dup).rejects.toThrow();
  });
});
```
`src/__tests__/env.d.ts`（若不存在則新增）讓 `env` 有型別：
```ts
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {}
}
```
（`Env` 需從 `../index` 匯入或以 `import type { Env } from "../index"` 引入，並把 `index.ts` 的 `interface Env` 改為 `export interface Env`。）

- [ ] **Step 5: 跑測試確認失敗**

Run: `cd cloudflare-worker && npm test -- d1.spec 2>&1 | tail -15`
Expected: 在 Step 3 之前跑會因 `env.ACCOUNTS_DB` undefined 失敗；完成 Step 3 後再跑。

- [ ] **Step 6: 跑測試確認通過**

Run: `cd cloudflare-worker && npm test 2>&1 | tail -8`
Expected: `d1.spec.ts` 2 tests pass；既有測試全部仍通過。

- [ ] **Step 7: Commit**

```bash
git add cloudflare-worker/migrations cloudflare-worker/src/__tests__/d1.ts cloudflare-worker/src/__tests__/d1.spec.ts cloudflare-worker/src/__tests__/env.d.ts cloudflare-worker/wrangler.toml cloudflare-worker/package.json cloudflare-worker/src/index.ts .github/workflows/worker-deploy.yml
git commit -m "feat(worker): add D1 accounts database, migrations tooling and deploy step"
```

---

### Task 2: App Attest 接受 iOS 與 Mac 兩個 bundle ID

**Files:**
- Modify: `cloudflare-worker/src/appAttest.ts:68-100`（輸入型別）、`:161-163`、`:223-225`
- Modify: `cloudflare-worker/src/index.ts:45`（Env）、`:842-843`、`:848-858`、`:895-896`
- Modify: `cloudflare-worker/vitest.config.mts`、`cloudflare-worker/src/__tests__/testSecrets.ts`
- Test: `cloudflare-worker/src/__tests__/appAttestBundles.spec.ts`

**Interfaces:**
- Produces: `AttestationInput.bundleIdentifiers: string[]`、`AssertionInput.bundleIdentifiers: string[]`；`AttestationResult.bundleIdentifier: string`（命中的那個）；`export function configuredBundleIds(env: Pick<Env,"APP_BUNDLE_ID"|"APP_BUNDLE_IDS">): string[]`；`export async function matchRpIdHash(rpIdHash: Uint8Array, teamId: string, bundleIds: string[]): Promise<string | null>`（appAttest.ts）；KV `attest:<deviceId>` 記錄新增 `bundleId`。

- [ ] **Step 1: 失敗測試**

`src/__tests__/appAttestBundles.spec.ts`：
```ts
import { describe, it, expect } from "vitest";
import { matchRpIdHash } from "../appAttest";
import { configuredBundleIds } from "../index";

async function sha256(s: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

describe("App Attest bundle set", () => {
  it("configuredBundleIds defaults to iOS + Mac and merges legacy APP_BUNDLE_ID", () => {
    expect(configuredBundleIds({})).toEqual(["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"]);
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "a.b, c.d" })).toEqual(["a.b", "c.d"]);
    expect(configuredBundleIds({ APP_BUNDLE_IDS: "a.b", APP_BUNDLE_ID: "legacy.id" })).toEqual(["a.b", "legacy.id"]);
  });

  it("matchRpIdHash returns the matching bundle id or null", async () => {
    const mac = await sha256("UK48R5KWLV.com.hanfour.peerdrop.mac");
    expect(await matchRpIdHash(mac, "UK48R5KWLV", ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"])).toBe("com.hanfour.peerdrop.mac");
    const other = await sha256("UK48R5KWLV.com.example.other");
    expect(await matchRpIdHash(other, "UK48R5KWLV", ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"])).toBeNull();
  });
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd cloudflare-worker && npm test -- appAttestBundles 2>&1 | tail -8`
Expected: 匯入失敗（`matchRpIdHash` / `configuredBundleIds` 不存在）。

- [ ] **Step 3: 實作 appAttest.ts**

- `AttestationInput` 與 `AssertionInput` 的 `bundleIdentifier: string` 改為 `bundleIdentifiers: string[]`；`AttestationResult` 加 `bundleIdentifier: string`。
- 新增：
```ts
export async function matchRpIdHash(rpIdHash: Uint8Array, teamId: string, bundleIds: string[]): Promise<string | null> {
  for (const bundleId of bundleIds) {
    const expected = await sha256(utf8Bytes(`${teamId}.${bundleId}`));
    if (constantTimeEq(rpIdHash, expected)) return bundleId;
  }
  return null;
}
```
- attestation（原 `:161-163`）改為：
```ts
  const matchedBundle = await matchRpIdHash(parsed.rpIdHash, input.teamIdentifier, input.bundleIdentifiers);
  if (!matchedBundle) throw new Error("rpIdHash mismatch");
```
並在回傳物件加 `bundleIdentifier: matchedBundle`。
- assertion（原 `:223-225`）同樣改用 `matchRpIdHash(rpIdHash, input.teamIdentifier, input.bundleIdentifiers)`，null 即 throw。

- [ ] **Step 4: 實作 index.ts**

- `Env` 加 `APP_BUNDLE_IDS?: string;   // comma-separated; default "com.hanfour.peerdrop,com.hanfour.peerdrop.mac"`。
- 新增（放在 `selectApnsTopic` 附近，`export`）：
```ts
export function configuredBundleIds(env: Pick<Env, "APP_BUNDLE_ID" | "APP_BUNDLE_IDS">): string[] {
  const list = (env.APP_BUNDLE_IDS ?? "com.hanfour.peerdrop,com.hanfour.peerdrop.mac")
    .split(",").map((s) => s.trim()).filter((s) => s.length > 0);
  if (env.APP_BUNDLE_ID && !list.includes(env.APP_BUNDLE_ID)) list.push(env.APP_BUNDLE_ID);
  return list;
}
```
- `/v2/device/attest`：`bundleIdentifier: env.APP_BUNDLE_ID ?? "com.hanfour.peerdrop"` → `bundleIdentifiers: configuredBundleIds(env)`；KV 記錄加 `bundleId: result.bundleIdentifier`。
- `/v2/device/assert`：`meta` 型別加 `bundleId?: string`；`bundleIdentifiers: meta.bundleId ? [meta.bundleId] : configuredBundleIds(env)`（舊記錄無 `bundleId` 時退回集合，避免既有裝置被鎖死）。
- `vitest.config.mts` bindings 加 `APP_BUNDLE_IDS: "com.hanfour.peerdrop,com.hanfour.peerdrop.mac"`；`testSecrets.ts` 加 `export const TEST_BUNDLE_IDS = ["com.hanfour.peerdrop", "com.hanfour.peerdrop.mac"];`。
- `device-token.spec.ts` 內既有呼叫 `verifyAssertion({... bundleIdentifier: ...})` 的地方改為 `bundleIdentifiers: [...]`。

- [ ] **Step 5: 跑全部測試**

Run: `cd cloudflare-worker && npm test 2>&1 | tail -8`
Expected: 新增 2 tests pass；`device-token.spec.ts` 全過。

- [ ] **Step 6: Commit**

```bash
git add cloudflare-worker
git commit -m "feat(worker): accept iOS and Mac bundle IDs in App Attest verification"
```

---

### Task 3: 帳號範圍 token、`authorizeV3`、`/v2/inbox` 擁有權綁定

**Files:**
- Create: `cloudflare-worker/src/account.ts`（本任務只放 `scopeForDevice`；後續任務擴充）
- Modify: `cloudflare-worker/src/index.ts`（attest/assert 發 token 處、`isRequestAuthorized`、inbox 路由）
- Test: `cloudflare-worker/src/__tests__/auth.spec.ts`（擴充）、`cloudflare-worker/src/__tests__/account.spec.ts`（新建，本任務先放 scope 測試）

**Interfaces:**
- Produces（`account.ts`）：`export async function scopeForDevice(db: D1Database, deviceId: string): Promise<string>`（有綁定 → `account:<id>`，否則 `"default"`）；`export function accountIdFromScope(scope: string): string | null`。
- Produces（`index.ts`）：`export interface V3Auth { deviceId: string; accountId: string }`；`export async function authorizeV3(request: Request, env: Env): Promise<V3Auth | null>`；`export async function authorizeDevice(request: Request, env: Env): Promise<TokenPayload | null>`（任一 scope 的 Bearer，header only；T4 的 challenge/register 用）。

- [ ] **Step 1: 失敗測試**

`src/__tests__/account.spec.ts`（第一版）：
```ts
import { env, SELF } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { issueToken, freshTokenPayload } from "../deviceToken";
import { TEST_TOKEN_SECRET } from "./testSecrets";
import { scopeForDevice, accountIdFromScope } from "../account";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

describe("account scope", () => {
  it("scopeForDevice is default for unbound devices and account:<id> for bound ones", async () => {
    expect(await scopeForDevice(env.ACCOUNTS_DB, "dev-unbound-1")).toBe("default");
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO accounts (account_id, signing_key, identity_key, mailbox_id, created_at, updated_at) VALUES ('SCOPE001', ?1, ?2, 'm', 0, 0)"
    ).bind(new Uint8Array([9, ...new Array(31).fill(0)]), new Uint8Array([8, ...new Array(31).fill(0)])).run();
    await env.ACCOUNTS_DB.prepare(
      "INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES ('SCOPE001', 'dev-bound-1', 'ios', 0)"
    ).run();
    expect(await scopeForDevice(env.ACCOUNTS_DB, "dev-bound-1")).toBe("account:SCOPE001");
    expect(accountIdFromScope("account:SCOPE001")).toBe("SCOPE001");
    expect(accountIdFromScope("default")).toBeNull();
  });
});

describe("/v3 gate", () => {
  it("rejects default-scope tokens, X-API-Key and ?token= on /v3/account/me", async () => {
    const def = await issueToken(freshTokenPayload("dev-bound-1", "default"), TEST_TOKEN_SECRET);
    expect((await SELF.fetch("https://example.com/v3/account/me", { headers: { Authorization: `Bearer ${def}` } })).status).toBe(401);
    expect((await SELF.fetch("https://example.com/v3/account/me", { headers: { "X-API-Key": "test-api-key-12345" } })).status).toBe(401);
    const acct = await issueToken(freshTokenPayload("dev-bound-1", "account:SCOPE001"), TEST_TOKEN_SECRET);
    expect((await SELF.fetch(`https://example.com/v3/account/me?token=${acct}`)).status).toBe(401);
  });
});
```
`src/__tests__/auth.spec.ts` 尾端加：
```ts
describe("auth — /v2/inbox ownership binding", () => {
  it("rejects a device token whose deviceId differs from the path", async () => {
    const token = await issueToken(freshTokenPayload("device-aaaa-1111", "default"), TEST_TOKEN_SECRET);
    const resp = await SELF.fetch(`https://example.com/v2/inbox/device-bbbb-2222?token=${token}`, {
      headers: { Upgrade: "websocket" },
    });
    expect(resp.status).toBe(403);
  });
  it("accepts a device token for its own inbox", async () => {
    const token = await issueToken(freshTokenPayload("device-aaaa-1111", "default"), TEST_TOKEN_SECRET);
    const resp = await SELF.fetch(`https://example.com/v2/inbox/device-aaaa-1111?token=${token}`, {
      headers: { Upgrade: "websocket" },
    });
    expect(resp.status).toBe(101);
  });
});
```
（`auth.spec.ts` 頂端需 `import { issueToken, freshTokenPayload } from "../deviceToken"; import { TEST_TOKEN_SECRET } from "./testSecrets";`。若 miniflare 對 WS 升級回 101 有困難，改以 `webSocket` 是否為 null 判斷，並在報告說明。）

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd cloudflare-worker && npm test -- account.spec auth.spec 2>&1 | tail -12`
Expected: `account.ts` 不存在 → 匯入失敗；inbox 綁定測試第一個案例得到 101 而非 403。

- [ ] **Step 3: 實作 `account.ts`（第一版）**

```ts
/** Account layer helpers shared by /v2 token issuance and /v3 routes. */
export async function scopeForDevice(db: D1Database, deviceId: string): Promise<string> {
  const row = await db.prepare("SELECT account_id FROM account_devices WHERE device_id = ?1")
    .bind(deviceId).first<{ account_id: string }>();
  return row ? `account:${row.account_id}` : "default";
}

export function accountIdFromScope(scope: string): string | null {
  return scope.startsWith("account:") && scope.length > 8 ? scope.slice(8) : null;
}
```

- [ ] **Step 4: 實作 index.ts**

- attest 與 assert 兩處 `issueToken(freshTokenPayload(body.deviceId), env.TOKEN_SECRET)` → `issueToken(freshTokenPayload(body.deviceId, await scopeForDevice(env.ACCOUNTS_DB, body.deviceId)), env.TOKEN_SECRET)`（頂部 `import { scopeForDevice, accountIdFromScope } from "./account";`）。
- 新增：
```ts
export interface V3Auth { deviceId: string; accountId: string }

/** Bearer-only device token (any scope). Never reads the query string. */
export async function authorizeDevice(request: Request, env: Env): Promise<TokenPayload | null> {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ") || !env.TOKEN_SECRET) return null;
  try {
    const { verifyToken } = await import("./deviceToken");
    return await verifyToken(header.slice(7).trim(), env.TOKEN_SECRET);
  } catch { return null; }
}

/** Bearer-only, account-scoped. Returns null for default scope / API key / ?token=. */
export async function authorizeV3(request: Request, env: Env): Promise<V3Auth | null> {
  const payload = await authorizeDevice(request, env);
  if (!payload) return null;
  const accountId = accountIdFromScope(payload.scope);
  return accountId ? { deviceId: payload.deviceId, accountId } : null;
}
```
（`TokenPayload` 以 `import type { TokenPayload } from "./deviceToken"` 引入。）
- `/v2/inbox/:deviceId` WS 升級處：在既有 `requiresAuth` 通過後、進入 DO 前加：
```ts
    const inboxMatch = path.match(/^\/v2\/inbox\/([a-zA-Z0-9-]{8,64})$/);
    if (inboxMatch && request.headers.get("Upgrade") === "websocket") {
      const providedKey = request.headers.get("X-API-Key") || url.searchParams.get("apiKey");
      if (providedKey !== env.API_KEY) {
        const candidate = (request.headers.get("Authorization")?.startsWith("Bearer ")
          ? request.headers.get("Authorization")!.slice(7).trim() : null) ?? url.searchParams.get("token");
        try {
          const { verifyToken } = await import("./deviceToken");
          const payload = await verifyToken(candidate ?? "", env.TOKEN_SECRET);
          if (payload.deviceId !== inboxMatch[1]) return jsonResponse({ error: "forbidden" }, 403);
        } catch { return jsonResponse({ error: "Unauthorized" }, 401); }
      }
    }
```
- 暫時的 `/v3/account/me` 佔位（T4 會完整實作）：路由分派中加
```ts
    if (path.startsWith("/v3/")) {
      const auth = await authorizeV3(request, env);
      if (!auth) return jsonResponse({ error: "Unauthorized" }, 401);
      return await handleV3(request, url, path, env, auth);
    }
```
並新增 `async function handleV3(request: Request, url: URL, path: string, env: Env, auth: V3Auth): Promise<Response> { return jsonResponse({ error: "not_found" }, 404); }`（T4 填入路由）。`rateLimitClass` 加 `if (path.startsWith("/v3/")) return "v3";`。

- [ ] **Step 5: 跑全部測試**

Run: `cd cloudflare-worker && npm test 2>&1 | tail -8`
Expected: 新增 4 tests pass，既有全過。

- [ ] **Step 6: Commit**

```bash
git add cloudflare-worker
git commit -m "feat(worker): account-scoped device tokens, /v3 auth gate and inbox ownership binding"
```

---

### Task 4: `/v3/account/*` 路由（challenge、register、me、nickname、delete）

**Files:**
- Modify: `cloudflare-worker/src/account.ts`、`cloudflare-worker/src/index.ts`（`handleV3`、`/v3/account/challenge` 與 `/register` 走 `authorizeDevice`）
- Test: `cloudflare-worker/src/__tests__/account.spec.ts`（擴充）

**Interfaces:**
- Produces（`account.ts`）：
  ```ts
  export const ACCOUNT_ID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  export function generateAccountId(): string;                       // 8 chars from 40 random bits
  export function normalizeAccountId(input: string): string | null; // strip -/space, upper, I/L→1, O→0, validate 8 chars in alphabet
  export const RESERVED_NICKNAMES = ["admin","peerdrop","support","system","null","me"];
  export type NicknameCheck = { ok: true; value: string } | { ok: false; code: "invalid_nickname" | "reserved" };
  export function validateNickname(raw: string): NicknameCheck;      // NFC, 3–20 scalars, \p{L}\p{N}_
  export async function verifyRegistrationSignature(signingKeyRaw: Uint8Array, nonce: Uint8Array, deviceId: string, signature: Uint8Array): Promise<boolean>;
  export interface AccountRow { account_id: string; signing_key: ArrayBuffer; identity_key: ArrayBuffer; nickname: string | null; mailbox_id: string }
  export async function findAccountByHandle(db: D1Database, handle: string): Promise<AccountRow | null>; // T5 uses
  ```
- Routes（回應形狀見規格 §3.3）。

- [ ] **Step 1: 失敗測試（追加到 account.spec.ts）**

```ts
import { generateAccountId, normalizeAccountId, validateNickname, ACCOUNT_ID_ALPHABET } from "../account";

function b64(u8: Uint8Array): string { return btoa(String.fromCharCode(...u8)); }
async function ed25519Pair() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  return { kp, raw };
}
async function deviceToken(deviceId: string, scope = "default") {
  return issueToken(freshTokenPayload(deviceId, scope), TEST_TOKEN_SECRET);
}
async function registerDevice(deviceId: string, platform = "ios", pair?: { kp: CryptoKeyPair; raw: Uint8Array }) {
  const p = pair ?? await ed25519Pair();
  const tok = await deviceToken(deviceId);
  const ch = await SELF.fetch("https://example.com/v3/account/challenge", {
    method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId }),
  });
  expect(ch.status).toBe(201);
  const { nonce } = await ch.json() as { nonce: string };
  const nonceBytes = Uint8Array.from(atob(nonce), (c) => c.charCodeAt(0));
  const msg = new Uint8Array([...new TextEncoder().encode("peerdrop-account-v1"), ...nonceBytes, ...new TextEncoder().encode(deviceId)]);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, p.kp.privateKey, msg));
  const identityKey = new Uint8Array(32); identityKey[0] = deviceId.charCodeAt(0); identityKey[1] = deviceId.charCodeAt(deviceId.length - 1);
  const reg = await SELF.fetch("https://example.com/v3/account/register", {
    method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId, platform, identityKey: b64(identityKey), signingKey: b64(p.raw), mailboxId: `mbx-${deviceId}`, nonce, signature: b64(sig) }),
  });
  return { reg, pair: p };
}

describe("account id + nickname helpers", () => {
  it("generateAccountId yields 8 chars from the alphabet", () => {
    for (let i = 0; i < 50; i++) {
      const id = generateAccountId();
      expect(id).toHaveLength(8);
      for (const c of id) expect(ACCOUNT_ID_ALPHABET).toContain(c);
    }
  });
  it("normalizeAccountId strips, uppercases and maps confusables", () => {
    expect(normalizeAccountId("abcd-efgh")).toBe("ABCDEFGH");
    expect(normalizeAccountId(" 0o1i-lL2z ")).toBe("00111122".replace("22", "2Z"));
    expect(normalizeAccountId("ABCDEFG")).toBeNull();
    expect(normalizeAccountId("ABCDEFGU")).toBeNull();
  });
  it("validateNickname enforces length, charset, reserved words and NFC", () => {
    expect(validateNickname("mo")).toEqual({ ok: false, code: "invalid_nickname" });
    expect(validateNickname("a".repeat(21))).toEqual({ ok: false, code: "invalid_nickname" });
    expect(validateNickname("mo chi")).toEqual({ ok: false, code: "invalid_nickname" });
    expect(validateNickname("Admin")).toEqual({ ok: false, code: "reserved" });
    expect(validateNickname("麻糬_01")).toEqual({ ok: true, value: "麻糬_01" });
    expect(validateNickname("éclair")).toEqual({ ok: true, value: "éclair" });
  });
});

describe("/v3/account", () => {
  it("register creates an account and returns an account-scoped token", async () => {
    const { reg } = await registerDevice("dev-reg-000001");
    expect(reg.status).toBe(201);
    const body = await reg.json() as { accountId: string; nickname: string | null; token: string; expiresInSeconds: number };
    expect(body.accountId).toMatch(/^[0-9A-HJKMNP-TV-Z]{8}$/);
    expect(body.nickname).toBeNull();
    expect(body.expiresInSeconds).toBe(900);
    const me = await SELF.fetch("https://example.com/v3/account/me", { headers: { Authorization: `Bearer ${body.token}` } });
    expect(me.status).toBe(200);
    const meBody = await me.json() as { accountId: string; devices: { deviceId: string; platform: string }[] };
    expect(meBody.accountId).toBe(body.accountId);
    expect(meBody.devices).toEqual([{ deviceId: "dev-reg-000001", platform: "ios", boundAt: expect.any(Number) }]);
  });
  it("register rejects a reused nonce and a bad signature", async () => {
    const tok = await deviceToken("dev-reg-000002");
    const ch = await SELF.fetch("https://example.com/v3/account/challenge", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002" }) });
    const { nonce } = await ch.json() as { nonce: string };
    const { raw } = await ed25519Pair();
    const bad = await SELF.fetch("https://example.com/v3/account/register", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002", platform: "ios", identityKey: b64(new Uint8Array(32)), signingKey: b64(raw), mailboxId: "m", nonce, signature: b64(new Uint8Array(64)) }) });
    expect(bad.status).toBe(400);
    expect((await bad.json() as { error: string }).error).toBe("bad_signature");
    const again = await SELF.fetch("https://example.com/v3/account/register", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-reg-000002", platform: "ios", identityKey: b64(new Uint8Array(32)), signingKey: b64(raw), mailboxId: "m", nonce, signature: b64(new Uint8Array(64)) }) });
    expect(again.status).toBe(400);
    expect((await again.json() as { error: string }).error).toBe("nonce_invalid");
  });
  it("same signing key from a second device binds to the existing account", async () => {
    const first = await registerDevice("dev-multi-00001", "ios");
    const a = (await first.reg.json() as { accountId: string }).accountId;
    const second = await registerDevice("dev-multi-00002", "macos", first.pair);
    expect(second.reg.status).toBe(201);
    expect((await second.reg.json() as { accountId: string }).accountId).toBe(a);
  });
  it("a device already bound to another account gets 409 device_bound", async () => {
    const first = await registerDevice("dev-bound-00001");
    expect(first.reg.status).toBe(201);
    const other = await registerDevice("dev-bound-00001");  // fresh key pair, same device
    expect(other.reg.status).toBe(409);
    expect((await other.reg.json() as { error: string }).error).toBe("device_bound");
  });
  it("register requires the token deviceId to match the body", async () => {
    const tok = await deviceToken("dev-mismatch-001");
    const resp = await SELF.fetch("https://example.com/v3/account/challenge", { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json" }, body: JSON.stringify({ deviceId: "dev-mismatch-002" }) });
    expect(resp.status).toBe(403);
  });
  it("nickname set / conflict / clear / rate limit", async () => {
    const a = await registerDevice("dev-nick-000001");
    const b = await registerDevice("dev-nick-000002");
    const ta = (await a.reg.json() as { token: string }).token;
    const tb = (await b.reg.json() as { token: string }).token;
    const put = (t: string, nickname: string | null) => SELF.fetch("https://example.com/v3/account/nickname", { method: "PUT", headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" }, body: JSON.stringify({ nickname }) });
    expect((await put(ta, "Mochi")).status).toBe(200);
    const taken = await put(tb, "mochi");
    expect(taken.status).toBe(409);
    expect((await taken.json() as { error: string }).error).toBe("nickname_taken");
    expect((await put(tb, "admin")).status).toBe(400);
    expect((await put(ta, null)).status).toBe(200);
    expect((await put(tb, "mochi")).status).toBe(200);  // released
    for (let i = 0; i < 3; i++) expect((await put(ta, `n${i}abc`)).status).toBe(200);  // ta: 2 used + 3 = 5
    expect((await put(ta, "over_limit")).status).toBe(429);
  });
  it("DELETE /v3/account removes the account and its devices", async () => {
    const a = await registerDevice("dev-del-0000001");
    const t = (await a.reg.json() as { token: string }).token;
    expect((await SELF.fetch("https://example.com/v3/account", { method: "DELETE", headers: { Authorization: `Bearer ${t}` } })).status).toBe(204);
    const row = await env.ACCOUNTS_DB.prepare("SELECT COUNT(*) AS n FROM account_devices WHERE device_id = 'dev-del-0000001'").first<{ n: number }>();
    expect(row?.n).toBe(0);
  });
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd cloudflare-worker && npm test -- account.spec 2>&1 | tail -15`
Expected: 匯入 `generateAccountId` 等失敗。

- [ ] **Step 3: 實作 `account.ts`**

```ts
export const ACCOUNT_ID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const RESERVED_NICKNAMES = ["admin", "peerdrop", "support", "system", "null", "me"];

export function generateAccountId(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < 8; i++) out += ACCOUNT_ID_ALPHABET[bytes[i] % 32];
  return out;
}

export function normalizeAccountId(input: string): string | null {
  const cleaned = input.replace(/[\s-]/g, "").toUpperCase().replace(/[IL]/g, "1").replace(/O/g, "0");
  if (cleaned.length !== 8) return null;
  for (const c of cleaned) if (!ACCOUNT_ID_ALPHABET.includes(c)) return null;
  return cleaned;
}

export type NicknameCheck = { ok: true; value: string } | { ok: false; code: "invalid_nickname" | "reserved" };
export function validateNickname(raw: string): NicknameCheck {
  const value = raw.normalize("NFC");
  const scalars = Array.from(value);
  if (scalars.length < 3 || scalars.length > 20) return { ok: false, code: "invalid_nickname" };
  if (!/^[\p{L}\p{N}_]+$/u.test(value)) return { ok: false, code: "invalid_nickname" };
  if (RESERVED_NICKNAMES.includes(value.toLowerCase())) return { ok: false, code: "reserved" };
  return { ok: true, value };
}

export async function verifyRegistrationSignature(signingKeyRaw: Uint8Array, nonce: Uint8Array, deviceId: string, signature: Uint8Array): Promise<boolean> {
  if (signingKeyRaw.length !== 32 || nonce.length !== 32 || signature.length !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", signingKeyRaw, { name: "Ed25519" }, false, ["verify"]);
    const enc = new TextEncoder();
    const msg = new Uint8Array([...enc.encode("peerdrop-account-v1"), ...nonce, ...enc.encode(deviceId)]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, msg);
  } catch { return false; }
}

export interface AccountRow { account_id: string; signing_key: ArrayBuffer; identity_key: ArrayBuffer; nickname: string | null; mailbox_id: string }

export async function findAccountByHandle(db: D1Database, handle: string): Promise<AccountRow | null> {
  const id = normalizeAccountId(handle);
  if (id) {
    const byId = await db.prepare("SELECT * FROM accounts WHERE account_id = ?1").bind(id).first<AccountRow>();
    if (byId) return byId;
  }
  const nick = validateNickname(handle);
  if (!nick.ok) return null;
  return await db.prepare("SELECT * FROM accounts WHERE nickname = ?1 COLLATE NOCASE").bind(nick.value).first<AccountRow>();
}
```
（`scopeForDevice`、`accountIdFromScope` 保留。）

- [ ] **Step 4: 實作 `handleV3` 與兩條裝置 token 路由**

在 `index.ts` 的 `/v3/` 分派前，先處理只需裝置 token 的兩條（放在 `path.startsWith("/v3/")` 區塊之前）：
```ts
    if (path === "/v3/account/challenge" && request.method === "POST") {
      const payload = await authorizeDevice(request, env);
      if (!payload) return jsonResponse({ error: "Unauthorized" }, 401);
      const body = await request.json().catch(() => null) as { deviceId?: string } | null;
      if (!body?.deviceId || !/^[a-zA-Z0-9-]{8,64}$/.test(body.deviceId)) return jsonResponse({ error: "invalid_device_id" }, 400);
      if (body.deviceId !== payload.deviceId) return jsonResponse({ error: "forbidden" }, 403);
      const nonce = new Uint8Array(32); crypto.getRandomValues(nonce);
      const nonceB64 = arrayBufferToBase64(nonce);
      await env.V2_STORE.put(`acct-challenge:${body.deviceId}`, nonceB64, { expirationTtl: 300 });
      return jsonResponse({ nonce: nonceB64 }, 201);
    }
    if (path === "/v3/account/register" && request.method === "POST") {
      const payload = await authorizeDevice(request, env);
      if (!payload) return jsonResponse({ error: "Unauthorized" }, 401);
      const raw = await request.text();
      if (raw.length > 4096) return jsonResponse({ error: "too_large" }, 413);
      const body = JSON.parse(raw || "null") as { deviceId?: string; platform?: string; identityKey?: string; signingKey?: string; mailboxId?: string; nonce?: string; signature?: string } | null;
      if (!body?.deviceId || !body.platform || !body.identityKey || !body.signingKey || !body.mailboxId || !body.nonce || !body.signature) return jsonResponse({ error: "missing_fields" }, 400);
      if (body.deviceId !== payload.deviceId) return jsonResponse({ error: "forbidden" }, 403);
      if (!["ios", "macos"].includes(body.platform)) return jsonResponse({ error: "invalid_platform" }, 400);
      if (!/^[a-z0-9]{1,64}$/.test(body.mailboxId)) return jsonResponse({ error: "invalid_mailbox" }, 400);
      const stored = await env.V2_STORE.get(`acct-challenge:${body.deviceId}`);
      if (!stored || stored !== body.nonce) return jsonResponse({ error: "nonce_invalid" }, 400);
      await env.V2_STORE.delete(`acct-challenge:${body.deviceId}`);
      const signingKey = base64Decode(body.signingKey), identityKey = base64Decode(body.identityKey);
      const ok = await verifyRegistrationSignature(signingKey, base64Decode(body.nonce), body.deviceId, base64Decode(body.signature));
      if (!ok) return jsonResponse({ error: "bad_signature" }, 400);
      if (identityKey.length !== 32) return jsonResponse({ error: "invalid_identity_key" }, 400);
      const now = Date.now();
      const bound = await env.ACCOUNTS_DB.prepare("SELECT account_id FROM account_devices WHERE device_id = ?1").bind(body.deviceId).first<{ account_id: string }>();
      let existing = await env.ACCOUNTS_DB.prepare("SELECT account_id, nickname FROM accounts WHERE signing_key = ?1").bind(signingKey).first<{ account_id: string; nickname: string | null }>();
      if (bound && (!existing || bound.account_id !== existing.account_id)) return jsonResponse({ error: "device_bound" }, 409);
      if (!existing) {
        let accountId = "";
        for (let attempt = 0; attempt < 3; attempt++) {
          accountId = generateAccountId();
          try {
            await env.ACCOUNTS_DB.prepare("INSERT INTO accounts (account_id, signing_key, identity_key, nickname, mailbox_id, created_at, updated_at) VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?5)")
              .bind(accountId, signingKey, identityKey, body.mailboxId, now).run();
            break;
          } catch (e) { if (attempt === 2) throw e; }
        }
        existing = { account_id: accountId, nickname: null };
      } else {
        await env.ACCOUNTS_DB.prepare("UPDATE accounts SET mailbox_id = ?1, updated_at = ?2 WHERE account_id = ?3").bind(body.mailboxId, now, existing.account_id).run();
      }
      if (!bound) {
        await env.ACCOUNTS_DB.prepare("INSERT INTO account_devices (account_id, device_id, platform, bound_at) VALUES (?1, ?2, ?3, ?4)")
          .bind(existing.account_id, body.deviceId, body.platform, now).run();
      }
      const token = await issueToken(freshTokenPayload(body.deviceId, `account:${existing.account_id}`), env.TOKEN_SECRET);
      return jsonResponse({ accountId: existing.account_id, nickname: existing.nickname, token, expiresInSeconds: 900 }, 201);
    }
```
`handleV3`（帳號 token 已驗）：
```ts
async function handleV3(request: Request, url: URL, path: string, env: Env, auth: V3Auth): Promise<Response> {
  const db = env.ACCOUNTS_DB;
  if (path === "/v3/account/me" && request.method === "GET") {
    const acct = await db.prepare("SELECT account_id, nickname, mailbox_id FROM accounts WHERE account_id = ?1").bind(auth.accountId).first<{ account_id: string; nickname: string | null; mailbox_id: string }>();
    if (!acct) return jsonResponse({ error: "not_found" }, 404);
    const devices = (await db.prepare("SELECT device_id, platform, bound_at FROM account_devices WHERE account_id = ?1 ORDER BY bound_at").bind(auth.accountId).all<{ device_id: string; platform: string; bound_at: number }>()).results
      .map((d) => ({ deviceId: d.device_id, platform: d.platform, boundAt: d.bound_at }));
    return jsonResponse({ accountId: acct.account_id, nickname: acct.nickname, mailboxId: acct.mailbox_id, devices });
  }
  if (path === "/v3/account/nickname" && request.method === "PUT") {
    const body = await request.json().catch(() => null) as { nickname?: string | null } | null;
    if (!body || !("nickname" in body)) return jsonResponse({ error: "missing_fields" }, 400);
    const day = new Date().toISOString().slice(0, 10);
    const quotaKey = `nick-quota:${auth.accountId}:${day}`;
    const used = parseInt((await env.V2_STORE.get(quotaKey)) ?? "0", 10) || 0;
    if (used >= 5) return jsonResponse({ error: "rate_limited" }, 429);
    let value: string | null = null;
    if (body.nickname !== null) {
      const check = validateNickname(String(body.nickname));
      if (!check.ok) return jsonResponse({ error: check.code }, 400);
      value = check.value;
    }
    try {
      await db.prepare("UPDATE accounts SET nickname = ?1, updated_at = ?2 WHERE account_id = ?3").bind(value, Date.now(), auth.accountId).run();
    } catch (e) {
      if (String((e as Error).message).includes("UNIQUE")) return jsonResponse({ error: "nickname_taken" }, 409);
      throw e;
    }
    await env.V2_STORE.put(quotaKey, String(used + 1), { expirationTtl: 86400 });
    return jsonResponse({ nickname: value });
  }
  if (path === "/v3/account" && request.method === "DELETE") {
    await db.prepare("DELETE FROM account_devices WHERE account_id = ?1").bind(auth.accountId).run();
    await db.prepare("DELETE FROM accounts WHERE account_id = ?1").bind(auth.accountId).run();
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  return jsonResponse({ error: "not_found" }, 404);
}
```
（D1 不保證 `ON DELETE CASCADE` 啟用 foreign_keys，因此明確先刪 devices。）

- [ ] **Step 5: 跑測試**

Run: `cd cloudflare-worker && npm test 2>&1 | tail -8`
Expected: account.spec 全部 pass。

- [ ] **Step 6: Commit**

```bash
git add cloudflare-worker
git commit -m "feat(worker): /v3 account registration, me, nickname and delete"
```

---

### Task 5: `/v3/directory/:handle`、目錄限流、mailbox rotate 同步 D1

**Files:**
- Modify: `cloudflare-worker/src/index.ts`（`handleV3`、`/v2/mailbox/rotate`）
- Test: `cloudflare-worker/src/__tests__/directory.spec.ts`

**Interfaces:**
- Produces: `GET /v3/directory/:handle?bundle=0|1` 回 `{accountId, nickname, identityKey, signingKey, mailboxId, preKeyBundle?}`（金鑰 base64）；限流 KV `dir-quota:<accountId>:<minuteWindow>` 30/min。`POST /v2/mailbox/rotate` 若帶帳號 Bearer，成功後更新 `accounts.mailbox_id`。

- [ ] **Step 1: 失敗測試**

`src/__tests__/directory.spec.ts`（重用 account.spec 的 `registerDevice`/`ed25519Pair` — 把那兩個輔助搬到 `src/__tests__/accountHelpers.ts` 並在兩個 spec 匯入）：
```ts
import { env, SELF } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { applyMigrations } from "./d1";
import { registerDevice } from "./accountHelpers";

beforeAll(async () => { await applyMigrations(env.ACCOUNTS_DB); });

describe("/v3/directory", () => {
  it("resolves by normalized id and by nickname; 404 otherwise", async () => {
    const a = await registerDevice("dev-dir-0000001");
    const { accountId, token } = await a.reg.json() as { accountId: string; token: string };
    await SELF.fetch("https://example.com/v3/account/nickname", { method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify({ nickname: "Dir_Owner" }) });
    const b = await registerDevice("dev-dir-0000002");
    const tb = (await b.reg.json() as { token: string }).token;
    const dashed = `${accountId.slice(0, 4)}-${accountId.slice(4).toLowerCase()}`;
    const r1 = await SELF.fetch(`https://example.com/v3/directory/${dashed}`, { headers: { Authorization: `Bearer ${tb}` } });
    expect(r1.status).toBe(200);
    const e1 = await r1.json() as { accountId: string; nickname: string; mailboxId: string; signingKey: string; preKeyBundle?: unknown };
    expect(e1.accountId).toBe(accountId); expect(e1.nickname).toBe("Dir_Owner"); expect(e1.mailboxId).toBe("mbx-dev-dir-0000001"); expect(e1.preKeyBundle).toBeUndefined();
    const r2 = await SELF.fetch("https://example.com/v3/directory/dir_owner", { headers: { Authorization: `Bearer ${tb}` } });
    expect((await r2.json() as { accountId: string }).accountId).toBe(accountId);
    expect((await SELF.fetch("https://example.com/v3/directory/nobody_here", { headers: { Authorization: `Bearer ${tb}` } })).status).toBe(404);
  });
  it("bundle=1 returns the pre-key bundle when the mailbox has keys", async () => {
    const a = await registerDevice("dev-dir-0000003");
    const { accountId } = await a.reg.json() as { accountId: string };
    // seed a pre-key bundle in KV the same way /v2/keys/register does
    await env.V2_STORE.put(`keys:mbx-dev-dir-0000003`, JSON.stringify({ identityKey: "AA==", signingKey: "AA==", signedPreKey: { id: 1, publicKey: "AA==", signature: "AA==" }, oneTimePreKeys: [{ id: 7, publicKey: "AA==" }] }));
    const b = await registerDevice("dev-dir-0000004");
    const tb = (await b.reg.json() as { token: string }).token;
    const r = await SELF.fetch(`https://example.com/v3/directory/${accountId}?bundle=1`, { headers: { Authorization: `Bearer ${tb}` } });
    expect(r.status).toBe(200);
    const e = await r.json() as { preKeyBundle: { oneTimePreKey: { id: number } | null } };
    expect(e.preKeyBundle.oneTimePreKey?.id).toBe(7);
  });
  it("rate limits at 30 lookups per minute per account", async () => {
    const a = await registerDevice("dev-dir-0000005");
    const t = (await a.reg.json() as { token: string }).token;
    let last = 0;
    for (let i = 0; i < 31; i++) last = (await SELF.fetch("https://example.com/v3/directory/zzzzzzzz", { headers: { Authorization: `Bearer ${t}` } })).status;
    expect(last).toBe(429);
  });
});
```
（seed 的 KV 形狀需與 `GET /v2/keys/:mailboxId` 讀取的一致 — 實作前先讀 `index.ts:948-960` 與 `PreKeyStore` DO 的 `fetch` 邏輯，照其結構調整測試 seed 與回傳欄位名，並在報告中註明。）

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd cloudflare-worker && npm test -- directory.spec 2>&1 | tail -12`
Expected: 404 `not_found`（路由未實作）。

- [ ] **Step 3: 實作**

`handleV3` 加：
```ts
  const dirMatch = path.match(/^\/v3\/directory\/([^/]{1,64})$/);
  if (dirMatch && request.method === "GET") {
    const minute = Math.floor(Date.now() / 60_000);
    const quotaKey = `dir-quota:${auth.accountId}:${minute}`;
    const used = parseInt((await env.V2_STORE.get(quotaKey)) ?? "0", 10) || 0;
    if (used >= 30) return jsonResponse({ error: "rate_limited" }, 429);
    await env.V2_STORE.put(quotaKey, String(used + 1), { expirationTtl: 120 });
    const row = await findAccountByHandle(db, decodeURIComponent(dirMatch[1]));
    if (!row) return jsonResponse({ error: "not_found" }, 404);
    const out: Record<string, unknown> = {
      accountId: row.account_id, nickname: row.nickname,
      identityKey: arrayBufferToBase64(new Uint8Array(row.identity_key)),
      signingKey: arrayBufferToBase64(new Uint8Array(row.signing_key)),
      mailboxId: row.mailbox_id,
    };
    if (url.searchParams.get("bundle") === "1") {
      const bundle = await fetchAndConsumePreKeyBundle(env, row.mailbox_id);   // 抽出 GET /v2/keys/:mailboxId 現有邏輯成函式
      if (bundle) out.preKeyBundle = bundle;
    }
    return jsonResponse(out);
  }
```
把 `GET /v2/keys/:mailboxId` 的 DO 呼叫抽為 `async function fetchAndConsumePreKeyBundle(env: Env, mailboxId: string): Promise<unknown | null>`，原路由改呼叫它（行為不變）。

`/v2/mailbox/rotate` 成功回應前加：
```ts
      const acct = await authorizeV3(request, env);
      if (acct) await env.ACCOUNTS_DB.prepare("UPDATE accounts SET mailbox_id = ?1, updated_at = ?2 WHERE account_id = ?3").bind(newMailboxId, Date.now(), acct.accountId).run();
```
（`newMailboxId` 為該路由既有的新 id 變數名，讀碼後對應。）

- [ ] **Step 4: 跑測試**

Run: `cd cloudflare-worker && npm test 2>&1 | tail -8`
Expected: 全部 pass。

- [ ] **Step 5: Commit**

```bash
git add cloudflare-worker
git commit -m "feat(worker): /v3 directory lookup with optional pre-key bundle and per-account rate limit"
```

---

### Task 6: 客戶端傳輸層：Mac App Attest、移除 Mac API key、統一 worker URL 鍵

> **已被最終修正波取代（2026-09-15，見規格 §7「2026-09-15 spike 結果」）**：原生 macOS 的
> `DCAppAttestService.isSupported == false`，所以「Mac 走 App Attest、移除內嵌金鑰」這一半沒有成立。
> Mac target 重新綁回 `Secrets.xcconfig`（Debug + Release），Info.plist 的 `PeerDropWorkerAPIKey`
> 改讀專屬的 `$(PEERDROP_MAC_CLIENT_KEY)`，並在 worker 端限制該通道。worker URL 鍵統一那一半仍然有效。

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropTransport/DeviceTokenManager.swift:29`、`WorkerAuthHelper.swift:22,52`、`MailboxClient.swift:14-17`
- Modify: `PeerDropMac/App/Info.plist:76-79`、`project.yml:218-223`
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（URL 鍵搬移）
- Test: `PeerDropKit/Tests/PeerDropTransportTests/WorkerURLMigrationTests.swift`

**Interfaces:**
- Produces: `public enum WorkerURL { public static let defaultsKey = "peerDropWorkerURL"; public static let legacyDefaultsKey = "workerBaseURL"; public static let production = URL(string: "https://peerdrop-signal.hanfourhuang.workers.dev")!; public static func current(defaults: UserDefaults = .standard) -> URL; public static func migrateLegacyKey(defaults: UserDefaults = .standard) }`（放 `PeerDropTransport/WorkerURL.swift`，新檔）。`DeviceTokenManager` 與 `WorkerAuthHelper` 在 macOS 11+ 可用。

- [ ] **Step 1: 失敗測試**

```swift
import XCTest
@testable import PeerDropTransport

final class WorkerURLMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { suite = "test.workerurl.\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testCurrentFallsBackToProduction() {
        XCTAssertEqual(WorkerURL.current(defaults: defaults), WorkerURL.production)
    }
    func testMigrateMovesLegacyKeyWhenNewKeyUnset() {
        defaults.set("https://staging.example.com", forKey: WorkerURL.legacyDefaultsKey)
        WorkerURL.migrateLegacyKey(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: WorkerURL.defaultsKey), "https://staging.example.com")
        XCTAssertNil(defaults.string(forKey: WorkerURL.legacyDefaultsKey))
        XCTAssertEqual(WorkerURL.current(defaults: defaults).absoluteString, "https://staging.example.com")
    }
    func testMigrateKeepsNewKeyWhenBothSet() {
        defaults.set("https://new.example.com", forKey: WorkerURL.defaultsKey)
        defaults.set("https://old.example.com", forKey: WorkerURL.legacyDefaultsKey)
        WorkerURL.migrateLegacyKey(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: WorkerURL.defaultsKey), "https://new.example.com")
        XCTAssertNil(defaults.string(forKey: WorkerURL.legacyDefaultsKey))
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd PeerDropKit && swift test --filter WorkerURLMigrationTests 2>&1 | tail -5`
Expected: `cannot find 'WorkerURL'`。

- [ ] **Step 3: 實作**

`PeerDropTransport/WorkerURL.swift`：
```swift
import Foundation

/// Single source of truth for the relay worker base URL (UserDefaults-overridable).
public enum WorkerURL {
    public static let defaultsKey = "peerDropWorkerURL"
    public static let legacyDefaultsKey = "workerBaseURL"   // pre-6.1 MailboxClient key
    public static let production = URL(string: "https://peerdrop-signal.hanfourhuang.workers.dev")!

    public static func current(defaults: UserDefaults = .standard) -> URL {
        if let s = defaults.string(forKey: defaultsKey), let u = URL(string: s), !s.isEmpty { return u }
        return production
    }

    /// One-shot: move a value stored under the legacy key to the canonical key.
    public static func migrateLegacyKey(defaults: UserDefaults = .standard) {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey) else { return }
        if defaults.string(forKey: defaultsKey) == nil { defaults.set(legacy, forKey: defaultsKey) }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}
```
- `MailboxClient.init`：`self.baseURL = baseURL ?? WorkerURL.current()`。
- `DeviceTokenManager.workerBaseURL`：`WorkerURL.current()`。`@available(iOS 14.0, *)` → `@available(iOS 14.0, macOS 11.0, *)`；`WorkerAuthHelper` 的兩個 `if #available(iOS 14.0, *)` → `if #available(iOS 14.0, macOS 11.0, *)`。
- `ConnectionManager.init`（或首個 `.active`）最前面呼叫 `WorkerURL.migrateLegacyKey()`。
- `PeerDropMac/App/Info.plist`：刪除 `PeerDropWorkerAPIKey` 的 key/string 與其上方註解。`project.yml` Mac target 的 `configFiles:` 區塊整段刪除（連同三行註解）。`xcodegen generate`。

- [ ] **Step 4: 建置與測試**

Run:
```bash
cd PeerDropKit && swift build && swift test --filter "WorkerURLMigrationTests|MailboxClient" 2>&1 | tail -4 && cd .. && xcodegen generate && \
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && \
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS,arch=arm64' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -quiet && \
grep -rn "workerBaseURL\|PeerDropWorkerAPIKey" --include='*.swift' --include='*.plist' PeerDropKit/Sources PeerDropMac PeerDrop | grep -v "WorkerURL.swift\|WorkerSignaling.swift"; echo "exit=$?"
```
Expected: 建置成功；3 tests pass；grep 無輸出（`WorkerSignaling.bundledAPIKey` 保留供 iOS Debug/CLI）。

- [ ] **Step 5: Commit**

```bash
git add -A PeerDropKit/Sources/PeerDropTransport PeerDropKit/Tests/PeerDropTransportTests PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift PeerDropMac/App/Info.plist project.yml PeerDrop.xcodeproj
git commit -m "feat(transport): App Attest on macOS, drop the Mac embedded API key, unify the worker URL key"
```

---

### Task 7: `PeerDropAccount` 模組 — 值型別與 `AccountStore`

**Files:**
- Create: `PeerDropKit/Sources/PeerDropAccount/{AccountID,Nickname,Account,AccountStore}.swift`
- Create: `PeerDropKit/Tests/PeerDropAccountTests/{AccountIDTests,NicknameTests,AccountStoreTests}.swift`
- Modify: `PeerDropKit/Package.swift`（product、target、testTarget）

**Interfaces:**
- Produces:
  ```swift
  public struct AccountID: Hashable, Codable, Sendable { public let raw: String; public init?(raw: String); public static func parse(_ input: String) -> AccountID?; public var display: String }
  public enum NicknameValidation: Equatable { case ok(String), tooShort, tooLong, invalidCharacters, reserved }
  public enum Nickname { public static let reserved: Set<String>; public static func validate(_ raw: String) -> NicknameValidation }
  public struct Account: Codable, Equatable, Sendable { public let accountId: AccountID; public var nickname: String?; public var mailboxId: String; public let createdAt: Date }
  public final class AccountStore { public init(storageKey: String = "account", directory: URL? = nil); public func load() -> Account?; public func save(_ account: Account) throws; public func clear() throws }
  ```

- [ ] **Step 1: Package.swift**

products 加 `.library(name: "PeerDropAccount", targets: ["PeerDropAccount"]),`；targets 加
```swift
        .target(
            name: "PeerDropAccount",
            dependencies: ["PeerDropPlatform", "PeerDropSecurity", "PeerDropTransport"]
        ),
        .testTarget(name: "PeerDropAccountTests", dependencies: ["PeerDropAccount"]),
```
並讓 `PeerDropCore` 的 dependencies 加 `"PeerDropAccount"`。

- [ ] **Step 2: 失敗測試**

`AccountIDTests.swift`：
```swift
import XCTest
@testable import PeerDropAccount

final class AccountIDTests: XCTestCase {
    func testParseNormalizes() {
        XCTAssertEqual(AccountID.parse("abcd-efgh")?.raw, "ABCDEFGH")
        XCTAssertEqual(AccountID.parse(" 0o1i lL2Z ")?.raw, "00111122".replacingOccurrences(of: "22", with: "2Z"))
        XCTAssertNil(AccountID.parse("ABCDEFG"))
        XCTAssertNil(AccountID.parse("ABCDEFGU"))
        XCTAssertNil(AccountID.parse(""))
    }
    func testDisplayInsertsHyphen() {
        XCTAssertEqual(AccountID(raw: "ABCDEFGH")?.display, "ABCD-EFGH")
        XCTAssertNil(AccountID(raw: "abcdefgh"), "init(raw:) is strict; use parse for user input")
    }
    func testCodableRoundTrip() throws {
        let id = AccountID(raw: "7K3MQ2ZD")!
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"7K3MQ2ZD\"")
        XCTAssertEqual(try JSONDecoder().decode(AccountID.self, from: data), id)
    }
}
```
`NicknameTests.swift`：
```swift
import XCTest
@testable import PeerDropAccount

final class NicknameTests: XCTestCase {
    func testRules() {
        XCTAssertEqual(Nickname.validate("mo"), .tooShort)
        XCTAssertEqual(Nickname.validate(String(repeating: "a", count: 21)), .tooLong)
        XCTAssertEqual(Nickname.validate("mo chi"), .invalidCharacters)
        XCTAssertEqual(Nickname.validate("mo-chi"), .invalidCharacters)
        XCTAssertEqual(Nickname.validate("Admin"), .reserved)
        XCTAssertEqual(Nickname.validate("麻糬_01"), .ok("麻糬_01"))
        XCTAssertEqual(Nickname.validate("e\u{0301}clair"), .ok("éclair"))
    }
}
```
`AccountStoreTests.swift`：
```swift
import XCTest
@testable import PeerDropAccount

final class AccountStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AccountStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRoundTripAndClear() throws {
        let store = AccountStore(storageKey: "account-test", directory: dir)
        XCTAssertNil(store.load())
        let account = Account(accountId: AccountID(raw: "7K3MQ2ZD")!, nickname: "mochi", mailboxId: "abc123", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(account)
        XCTAssertEqual(AccountStore(storageKey: "account-test", directory: dir).load(), account)
        let raw = try Data(contentsOf: dir.appendingPathComponent("account-test.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("7K3MQ2ZD"), "file must be encrypted at rest")
        try store.clear()
        XCTAssertNil(store.load())
    }
    func testCorruptFileLoadsAsNil() throws {
        let store = AccountStore(storageKey: "account-corrupt", directory: dir)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("account-corrupt.enc"))
        XCTAssertNil(store.load())
    }
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `cd PeerDropKit && swift test --filter "AccountIDTests|NicknameTests|AccountStoreTests" 2>&1 | tail -5`
Expected: 編譯失敗（型別不存在）。

- [ ] **Step 4: 實作**

`AccountID.swift`：
```swift
import Foundation

/// 8-character Crockford base32 account identifier issued by the worker.
public struct AccountID: Hashable, Codable, Sendable {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public let raw: String

    /// Strict: `raw` must already be 8 uppercase alphabet characters.
    public init?(raw: String) {
        guard raw.count == 8, raw.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.raw = raw
    }

    /// Lenient user-input parser: strips hyphens/whitespace, uppercases, maps I/L→1 and O→0.
    public static func parse(_ input: String) -> AccountID? {
        var cleaned = ""
        for ch in input.uppercased() where ch != "-" && !ch.isWhitespace {
            switch ch {
            case "I", "L": cleaned.append("1")
            case "O": cleaned.append("0")
            default: cleaned.append(ch)
            }
        }
        return AccountID(raw: cleaned)
    }

    public var display: String { raw.prefix(4) + "-" + raw.suffix(4) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = AccountID(raw: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid account id \(s)"))
        }
        self = id
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}
```
`Nickname.swift`：
```swift
import Foundation

public enum NicknameValidation: Equatable { case ok(String), tooShort, tooLong, invalidCharacters, reserved }

public enum Nickname {
    public static let reserved: Set<String> = ["admin", "peerdrop", "support", "system", "null", "me"]
    public static let minLength = 3, maxLength = 20

    public static func validate(_ raw: String) -> NicknameValidation {
        let value = raw.precomposedStringWithCanonicalMapping   // NFC
        let scalars = value.unicodeScalars
        if scalars.count < minLength { return .tooShort }
        if scalars.count > maxLength { return .tooLong }
        for s in scalars {
            let ok = s == "_" || s.properties.isAlphabetic || s.properties.numericType != nil
            if !ok { return .invalidCharacters }
        }
        if reserved.contains(value.lowercased()) { return .reserved }
        return .ok(value)
    }
}
```
（`isAlphabetic` 涵蓋 `\p{L}` 與部分 `\p{M}`；worker 端用 `\p{L}\p{N}_`。兩端差異只影響極少數組合字元；以伺服器為準，客戶端僅做即時提示。）

`Account.swift`：
```swift
import Foundation
public struct Account: Codable, Equatable, Sendable {
    public let accountId: AccountID
    public var nickname: String?
    public var mailboxId: String
    public let createdAt: Date
    public init(accountId: AccountID, nickname: String?, mailboxId: String, createdAt: Date) { … }
}
```
`AccountStore.swift`（沿用 `TrustedContactStore` 模式，加 `directory` 注入）：
```swift
import Foundation
import os
import PeerDropSecurity

public final class AccountStore {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "AccountStore")
    private let storageKey: String
    private let directory: URL
    private let encryptor = ChatDataEncryptor.shared

    public init(storageKey: String = "account", directory: URL? = nil) {
        self.storageKey = storageKey
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
    }
    private var url: URL { directory.appendingPathComponent("\(storageKey).enc") }

    public func load() -> Account? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            return try JSONDecoder().decode(Account.self, from: data)
        } catch {
            Self.logger.error("account file unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    public func save(_ account: Account) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(JSONEncoder().encode(account), to: url)
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
```
（`ChatDataEncryptor` 在 `swift test` 沙盒可能無 keychain — 若 `AccountStoreTests` 因此失敗，改用 `encryptor` 注入：`init(..., encryptor: ChatDataEncryptor = .shared)` 並在測試用 `ChatDataEncryptor(key: SymmetricKey(size: .bits256))` 若該 init 存在；否則在報告中標記並讓測試以 `XCTSkip` 略過 keychain 不可用的環境，說明原因。）

- [ ] **Step 5: 跑測試**

Run: `cd PeerDropKit && swift build && swift test --filter "AccountIDTests|NicknameTests|AccountStoreTests" 2>&1 | tail -5`
Expected: 全過（或 AccountStore 依上述註記 skip）。

- [ ] **Step 6: Commit**

```bash
git add PeerDropKit/Package.swift PeerDropKit/Sources/PeerDropAccount PeerDropKit/Tests/PeerDropAccountTests
git commit -m "feat(account): PeerDropAccount module with AccountID, Nickname, Account and encrypted AccountStore"
```

---

### Task 8: `AccountClient`

**Files:**
- Create: `PeerDropKit/Sources/PeerDropAccount/AccountClient.swift`
- Create: `PeerDropKit/Tests/PeerDropAccountTests/{TestURLProtocol,AccountClientTests}.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RegisterRequest: Encodable { public var deviceId: String; public var platform: String; public var identityKey: Data; public var signingKey: Data; public var mailboxId: String; public var nonce: Data; public var signature: Data }   // Data 以 base64 編碼
  public struct RegisterResponse: Decodable { public let accountId: AccountID; public let nickname: String?; public let token: String; public let expiresInSeconds: Int }
  public struct MeResponse: Decodable { public let accountId: AccountID; public let nickname: String?; public let mailboxId: String }
  public struct DirectoryEntry: Decodable, Equatable { public let accountId: AccountID; public let nickname: String?; public let identityKey: Data; public let signingKey: Data; public let mailboxId: String }
  public enum AccountClientError: Error, Equatable { case unauthorized, forbidden, conflict(String), invalid(String), rateLimited, http(Int), invalidResponse }
  public actor AccountClient {
      public init(baseURL: URL? = nil, session: URLSession? = nil, authProvider: @escaping @Sendable (inout URLRequest) async -> Void = { await WorkerAuthHelper.applyAuth(to: &$0) }, tokenInvalidator: @escaping @Sendable () async -> Void = { await DeviceTokenManager.shared.invalidate() })
      public func challenge(deviceId: String) async throws -> Data
      public func register(_ req: RegisterRequest) async throws -> RegisterResponse
      public func me() async throws -> MeResponse
      public func setNickname(_ nickname: String?) async throws -> String?
      public func lookup(handle: String, includeBundle: Bool) async throws -> DirectoryEntry?
      public func deleteAccount() async throws
  }
  ```
- Consumes: `DeviceTokenManager.invalidate()`（**新增**於 T8：`public func invalidate()` 清 `cachedToken`/`tokenExpiresAt`/keychain token，使下次 `bearerHeader()` 重新 attest/assert）。註冊回傳的 `token` 由呼叫端交給 `DeviceTokenManager.adopt(token:expiresInSeconds:)`（**新增** public 方法，呼叫既有 private `storeToken`）。

- [ ] **Step 1: 失敗測試**

`TestURLProtocol.swift`（模組內測試用，仿 `PeerDropTests/Helpers/MockURLProtocol.swift` 但支援序列回應）：
```swift
import Foundation

final class TestURLProtocol: URLProtocol {
    struct Stub { let status: Int; let body: Data }
    static var queue: [Stub] = []
    static var requests: [URLRequest] = []
    static func reset() { queue = []; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        let stub = Self.queue.isEmpty ? Stub(status: 500, body: Data()) : Self.queue.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
```
`AccountClientTests.swift`：
```swift
import XCTest
@testable import PeerDropAccount

final class AccountClientTests: XCTestCase {
    private var client: AccountClient!
    private var authCalls = 0
    private var invalidations = 0

    override func setUp() {
        TestURLProtocol.reset(); authCalls = 0; invalidations = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TestURLProtocol.self]
        client = AccountClient(
            baseURL: URL(string: "https://worker.test")!,
            session: URLSession(configuration: cfg),
            authProvider: { req in self.authCalls += 1; req.setValue("Bearer t\(self.authCalls)", forHTTPHeaderField: "Authorization") },
            tokenInvalidator: { self.invalidations += 1 })
    }

    func testLookupDecodesEntryAndSendsBearer() async throws {
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":"mochi","identityKey":"AAAA","signingKey":"AAAA","mailboxId":"abc"}"#.utf8))]
        let entry = try await client.lookup(handle: "7k3m-q2zd", includeBundle: false)
        XCTAssertEqual(entry?.accountId.raw, "7K3MQ2ZD")
        XCTAssertEqual(entry?.nickname, "mochi")
        let req = TestURLProtocol.requests[0]
        XCTAssertEqual(req.url?.path, "/v3/directory/7k3m-q2zd")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
    }
    func testLookup404ReturnsNil() async throws {
        TestURLProtocol.queue = [.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))]
        XCTAssertNil(try await client.lookup(handle: "nobody", includeBundle: false))
    }
    func test401RetriesOnceAfterInvalidatingToken() async throws {
        TestURLProtocol.queue = [.init(status: 401, body: Data()), .init(status: 200, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"mailboxId":"abc"}"#.utf8))]
        let me = try await client.me()
        XCTAssertEqual(me.accountId.raw, "7K3MQ2ZD")
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(TestURLProtocol.requests.count, 2)
        XCTAssertEqual(TestURLProtocol.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer t2")
    }
    func testErrorMapping() async {
        TestURLProtocol.queue = [.init(status: 409, body: Data(#"{"error":"nickname_taken"}"#.utf8))]
        await XCTAssertThrowsErrorAsync(try await client.setNickname("x_y_z")) { XCTAssertEqual($0 as? AccountClientError, .conflict("nickname_taken")) }
        TestURLProtocol.queue = [.init(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8))]
        await XCTAssertThrowsErrorAsync(try await client.setNickname("x_y_z")) { XCTAssertEqual($0 as? AccountClientError, .rateLimited) }
        TestURLProtocol.queue = [.init(status: 400, body: Data(#"{"error":"reserved"}"#.utf8))]
        await XCTAssertThrowsErrorAsync(try await client.setNickname("admin")) { XCTAssertEqual($0 as? AccountClientError, .invalid("reserved")) }
        TestURLProtocol.queue = [.init(status: 401, body: Data()), .init(status: 401, body: Data())]
        await XCTAssertThrowsErrorAsync(try await client.me()) { XCTAssertEqual($0 as? AccountClientError, .unauthorized) }
    }
    func testRegisterEncodesBase64AndDecodesResponse() async throws {
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"tok","expiresInSeconds":900}"#.utf8))]
        let req = RegisterRequest(deviceId: "dev-1", platform: "ios", identityKey: Data(repeating: 1, count: 32), signingKey: Data(repeating: 2, count: 32), mailboxId: "m", nonce: Data(repeating: 3, count: 32), signature: Data(repeating: 4, count: 64))
        let resp = try await client.register(req)
        XCTAssertEqual(resp.token, "tok")
        let sent = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["signingKey"] as? String, Data(repeating: 2, count: 32).base64EncodedString())
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expr: @autoclosure () async throws -> T, _ handler: (Error) -> Void) async {
    do { _ = try await expr(); XCTFail("expected error") } catch { handler(error) }
}
```
（`URLRequest.httpBody` 在 URLProtocol 內可能為 nil、改在 `httpBodyStream`；若如此，AccountClient 改以 `session.upload(for:from:)` 送 body，或測試改讀 stream — 實作時擇一並在報告註明。）

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd PeerDropKit && swift test --filter AccountClientTests 2>&1 | tail -5`
Expected: 編譯失敗。

- [ ] **Step 3: 實作 `AccountClient.swift` 與 `DeviceTokenManager` 兩個新方法**

`DeviceTokenManager` 加：
```swift
    /// Drop the cached bearer so the next request re-asserts (used after a 401).
    public func invalidate() {
        cachedToken = nil; tokenExpiresAt = nil
        Self.writeKeychainToken(nil)   // 若既有 writeKeychainToken 不接受 nil，新增 deleteKeychainToken()
        UserDefaults.standard.removeObject(forKey: Self.expiryKey)
    }
    /// Adopt a token minted by another route (e.g. /v3/account/register).
    public func adopt(token: String, expiresInSeconds: Int) { storeToken(token, expiresInSeconds: expiresInSeconds) }
```
`AccountClient.swift`：
```swift
import Foundation
import PeerDropTransport

public actor AccountClient {
    private let baseURL: URL
    private let session: URLSession
    private let authProvider: @Sendable (inout URLRequest) async -> Void
    private let tokenInvalidator: @Sendable () async -> Void

    public init(baseURL: URL? = nil, session: URLSession? = nil,
                authProvider: @escaping @Sendable (inout URLRequest) async -> Void = { await WorkerAuthHelper.applyAuth(to: &$0) },
                tokenInvalidator: @escaping @Sendable () async -> Void = { if #available(iOS 14.0, macOS 11.0, *) { await DeviceTokenManager.shared.invalidate() } }) {
        self.baseURL = baseURL ?? WorkerURL.current()
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: cfg)
        }
        self.authProvider = authProvider; self.tokenInvalidator = tokenInvalidator
    }

    public func challenge(deviceId: String) async throws -> Data {
        struct R: Decodable { let nonce: String }
        let r: R = try await send("POST", "v3/account/challenge", body: ["deviceId": deviceId])
        guard let d = Data(base64Encoded: r.nonce), d.count == 32 else { throw AccountClientError.invalidResponse }
        return d
    }
    public func register(_ req: RegisterRequest) async throws -> RegisterResponse { try await send("POST", "v3/account/register", body: req) }
    public func me() async throws -> MeResponse { try await send("GET", "v3/account/me", body: Optional<Int>.none) }
    public func setNickname(_ nickname: String?) async throws -> String? {
        struct R: Decodable { let nickname: String? }
        let r: R = try await send("PUT", "v3/account/nickname", body: ["nickname": nickname])
        return r.nickname
    }
    public func lookup(handle: String, includeBundle: Bool) async throws -> DirectoryEntry? {
        let escaped = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        do { return try await send("GET", "v3/directory/\(escaped)" + (includeBundle ? "?bundle=1" : ""), body: Optional<Int>.none) }
        catch AccountClientError.http(404) { return nil }
    }
    public func deleteAccount() async throws { let _: Empty = try await send("DELETE", "v3/account", body: Optional<Int>.none) }

    private struct Empty: Decodable {}
    private struct ErrorBody: Decodable { let error: String }

    private func send<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B?, retrying: Bool = true) async throws -> R {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { let enc = JSONEncoder(); enc.dataEncodingStrategy = .base64; request.httpBody = try enc.encode(body) }
        await authProvider(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountClientError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            if data.isEmpty, R.self == Empty.self { return Empty() as! R }
            let dec = JSONDecoder(); dec.dataDecodingStrategy = .base64
            return try dec.decode(R.self, from: data)
        case 401:
            if retrying { await tokenInvalidator(); return try await send(method, path, body: body, retrying: false) }
            throw AccountClientError.unauthorized
        case 403: throw AccountClientError.forbidden
        case 404: throw AccountClientError.http(404)
        case 409: throw AccountClientError.conflict(Self.code(data))
        case 400, 413: throw AccountClientError.invalid(Self.code(data))
        case 429: throw AccountClientError.rateLimited
        default: throw AccountClientError.http(http.statusCode)
        }
    }
    private static func code(_ data: Data) -> String { (try? JSONDecoder().decode(ErrorBody.self, from: data).error) ?? "unknown" }
}
```
（`[String: String?]` 作為 `Encodable` body 需自訂型別：`struct NicknameBody: Encodable { let nickname: String? }` 並以 `encode(nickname)` 明確輸出 null；`RegisterRequest` 的 `Data` 欄位靠 `.base64` 策略。）

- [ ] **Step 4: 跑測試**

Run: `cd PeerDropKit && swift build && swift test --filter "AccountClientTests|DeviceToken" 2>&1 | tail -5`
Expected: 5 tests pass；建置無警告。

- [ ] **Step 5: Commit**

```bash
git add PeerDropKit/Sources/PeerDropAccount/AccountClient.swift PeerDropKit/Tests/PeerDropAccountTests PeerDropKit/Sources/PeerDropTransport/DeviceTokenManager.swift
git commit -m "feat(account): AccountClient with 401 retry, error mapping and base64 key encoding"
```

---

### Task 9: `AccountManager` 狀態機與 `ConnectionManager` 整合

**Files:**
- Create: `PeerDropKit/Sources/PeerDropAccount/AccountManager.swift`
- Create: `PeerDropKit/Tests/PeerDropAccountTests/AccountManagerTests.swift`
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（屬性、`.active` bootstrap）、`PeerDropKit/Sources/PeerDropSecurity/TrustedContact.swift`（`userId` → `accountId`）、`PeerDropKit/Sources/PeerDropCore/ScreenshotModeProvider.swift`（`mockAccount`）

**Interfaces:**
- Produces:
  ```swift
  public protocol AccountRegistrationDependencies: Sendable {
      var deviceId: String { get }; var platform: String { get }
      func identityKeys() throws -> (identity: Data, signing: Data)
      func sign(_ data: Data) throws -> Data
      func currentMailboxId() async throws -> String        // MailboxManager.registerIfNeeded() 後的 id
      var attestSupported: Bool { get }
  }
  @MainActor public final class AccountManager: ObservableObject {
      public enum Unavailable: Equatable { case attestUnsupported, offline, failed(String) }
      public enum State: Equatable { case idle, registering, ready(Account), unavailable(Unavailable) }
      @Published public private(set) var state: State
      public init(client: AccountClient, store: AccountStore, deps: AccountRegistrationDependencies, tokenAdopter: @escaping @Sendable (String, Int) async -> Void)
      public var account: Account? { if case .ready(let a) = state { return a } else { return nil } }
      public func bootstrap() async
      public func registerIfNeeded() async
      public func setNickname(_ raw: String?) async throws   // 先本地 Nickname.validate，再 client.setNickname；成功更新 state + store
      public func lookup(handle: String) async throws -> DirectoryEntry?
      public func refreshFromServer() async
      public func deleteAccount() async throws              // client.deleteAccount → store.clear → state = .idle 再 registerIfNeeded
  }
  ```
- `ConnectionManager.accountManager: AccountManager`（`lazy`，deps 由 `IdentityKeyManager.shared`、`mailboxManager`、`DeviceIdentity.deviceId`、平台字串組成）。`ScreenshotModeProvider.mockAccount`。

- [ ] **Step 1: 失敗測試**

```swift
import XCTest
@testable import PeerDropAccount

@MainActor
final class AccountManagerTests: XCTestCase {
    struct Deps: AccountRegistrationDependencies {
        var deviceId = "dev-test-0001"; var platform = "ios"; var attestSupported = true
        var mailbox = "mbx1"
        func identityKeys() throws -> (identity: Data, signing: Data) { (Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)) }
        func sign(_ data: Data) throws -> Data { Data(repeating: 9, count: 64) }
        func currentMailboxId() async throws -> String { mailbox }
    }
    private var dir: URL!
    override func setUp() async throws {
        TestURLProtocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    private func makeManager(deps: Deps = Deps(), adopted: @escaping @Sendable (String, Int) -> Void = { _, _ in }) -> AccountManager {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let client = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg),
                                   authProvider: { $0.setValue("Bearer t", forHTTPHeaderField: "Authorization") }, tokenInvalidator: {})
        return AccountManager(client: client, store: AccountStore(storageKey: "am", directory: dir), deps: deps, tokenAdopter: adopted)
    }

    func testBootstrapRegistersAndPersists() async throws {
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8)),
            .init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"acct-tok","expiresInSeconds":900}"#.utf8)),
        ]
        var adopted: (String, Int)?
        let m = makeManager(adopted: { adopted = ($0, $1) })
        await m.bootstrap()
        XCTAssertEqual(m.account?.accountId.raw, "7K3MQ2ZD")
        XCTAssertEqual(adopted?.0, "acct-tok")
        XCTAssertEqual(AccountStore(storageKey: "am", directory: dir).load()?.accountId.raw, "7K3MQ2ZD")
        // second bootstrap uses the store, no network
        TestURLProtocol.reset()
        let m2 = makeManager()
        await m2.bootstrap()
        XCTAssertEqual(m2.account?.accountId.raw, "7K3MQ2ZD")
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }
    func testAttestUnsupportedIsTerminal() async {
        let m = makeManager(deps: Deps(attestSupported: false))
        await m.bootstrap()
        XCTAssertEqual(m.state, .unavailable(.attestUnsupported))
        XCTAssertTrue(TestURLProtocol.requests.isEmpty)
    }
    func testServerErrorBecomesFailedAndRetryable() async {
        TestURLProtocol.queue = [.init(status: 500, body: Data())]
        let m = makeManager()
        await m.bootstrap()
        guard case .unavailable(.failed) = m.state else { return XCTFail("expected failed, got \(m.state)") }
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8)),
            .init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"t","expiresInSeconds":900}"#.utf8)),
        ]
        await m.registerIfNeeded()
        XCTAssertNotNil(m.account)
    }
    func testSetNicknameValidatesLocallyThenPersists() async throws {
        TestURLProtocol.queue = [
            .init(status: 201, body: Data(#"{"nonce":"\#(Data(repeating: 5, count: 32).base64EncodedString())"}"#.utf8)),
            .init(status: 201, body: Data(#"{"accountId":"7K3MQ2ZD","nickname":null,"token":"t","expiresInSeconds":900}"#.utf8)),
            .init(status: 200, body: Data(#"{"nickname":"mochi"}"#.utf8)),
        ]
        let m = makeManager()
        await m.bootstrap()
        await XCTAssertThrowsErrorAsync(try await m.setNickname("mo")) { XCTAssertEqual($0 as? AccountManager.NicknameError, .tooShort) }
        try await m.setNickname("mochi")
        XCTAssertEqual(m.account?.nickname, "mochi")
        XCTAssertEqual(AccountStore(storageKey: "am", directory: dir).load()?.nickname, "mochi")
    }
}
```
（`AccountManager.NicknameError: Error, Equatable { case tooShort, tooLong, invalidCharacters, reserved }` 由 `Nickname.validate` 映射。）

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd PeerDropKit && swift test --filter AccountManagerTests 2>&1 | tail -5`
Expected: 編譯失敗。

- [ ] **Step 3: 實作 `AccountManager.swift`**

```swift
import Foundation
import os

public protocol AccountRegistrationDependencies: Sendable {
    var deviceId: String { get }
    var platform: String { get }
    var attestSupported: Bool { get }
    func identityKeys() throws -> (identity: Data, signing: Data)
    func sign(_ data: Data) throws -> Data
    func currentMailboxId() async throws -> String
}

@MainActor
public final class AccountManager: ObservableObject {
    public enum Unavailable: Equatable { case attestUnsupported, offline, failed(String) }
    public enum State: Equatable { case idle, registering, ready(Account), unavailable(Unavailable) }
    public enum NicknameError: Error, Equatable { case tooShort, tooLong, invalidCharacters, reserved }

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "AccountManager")
    @Published public private(set) var state: State = .idle
    private let client: AccountClient
    private let store: AccountStore
    private let deps: AccountRegistrationDependencies
    private let tokenAdopter: @Sendable (String, Int) async -> Void
    private var didBootstrap = false

    public init(client: AccountClient, store: AccountStore, deps: AccountRegistrationDependencies,
                tokenAdopter: @escaping @Sendable (String, Int) async -> Void) {
        self.client = client; self.store = store; self.deps = deps; self.tokenAdopter = tokenAdopter
    }

    public var account: Account? { if case .ready(let a) = state { return a } else { return nil } }

    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        if let saved = store.load() { state = .ready(saved); return }
        await registerIfNeeded()
    }

    public func registerIfNeeded() async {
        if case .ready = state { return }
        if case .registering = state { return }
        guard deps.attestSupported else { state = .unavailable(.attestUnsupported); return }
        state = .registering
        do {
            let mailboxId = try await deps.currentMailboxId()
            let keys = try deps.identityKeys()
            let nonce = try await client.challenge(deviceId: deps.deviceId)
            let message = Data("peerdrop-account-v1".utf8) + nonce + Data(deps.deviceId.utf8)
            let signature = try deps.sign(message)
            let resp = try await client.register(RegisterRequest(deviceId: deps.deviceId, platform: deps.platform,
                identityKey: keys.identity, signingKey: keys.signing, mailboxId: mailboxId, nonce: nonce, signature: signature))
            await tokenAdopter(resp.token, resp.expiresInSeconds)
            let account = Account(accountId: resp.accountId, nickname: resp.nickname, mailboxId: mailboxId, createdAt: Date())
            try store.save(account)
            state = .ready(account)
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .timedOut {
            state = .unavailable(.offline)
        } catch {
            Self.logger.error("registration failed: \(String(describing: error), privacy: .public)")
            state = .unavailable(.failed(String(describing: error)))
        }
    }

    public func setNickname(_ raw: String?) async throws {
        guard var account = account else { return }
        var value: String? = nil
        if let raw {
            switch Nickname.validate(raw) {
            case .ok(let v): value = v
            case .tooShort: throw NicknameError.tooShort
            case .tooLong: throw NicknameError.tooLong
            case .invalidCharacters: throw NicknameError.invalidCharacters
            case .reserved: throw NicknameError.reserved
            }
        }
        let confirmed = try await client.setNickname(value)
        account.nickname = confirmed
        try store.save(account)
        state = .ready(account)
    }

    public func lookup(handle: String) async throws -> DirectoryEntry? { try await client.lookup(handle: handle, includeBundle: false) }

    public func refreshFromServer() async {
        guard var account = account, let me = try? await client.me() else { return }
        account.nickname = me.nickname; account.mailboxId = me.mailboxId
        try? store.save(account)   // best-effort cache refresh; failures surface on next explicit save
        state = .ready(account)
    }

    public func deleteAccount() async throws {
        try await client.deleteAccount()
        try store.clear()
        state = .idle
        didBootstrap = false
    }
}
```

- [ ] **Step 4: ConnectionManager、TrustedContact、ScreenshotModeProvider**

- `ConnectionManager`：`import PeerDropAccount`；在 `mailboxManager` 宣告後加
```swift
    public private(set) lazy var accountManager = AccountManager(
        client: AccountClient(),
        store: AccountStore(storageKey: PeerDropPersistence.scopedKey("account")),
        deps: LiveAccountDependencies(mailboxManager: mailboxManager),
        tokenAdopter: { token, ttl in if #available(iOS 14.0, macOS 11.0, *) { await DeviceTokenManager.shared.adopt(token: token, expiresInSeconds: ttl) } })
```
並新增 `PeerDropCore/LiveAccountDependencies.swift`：
```swift
import Foundation
import DeviceCheck
import PeerDropAccount
import PeerDropPlatform
import PeerDropSecurity
import PeerDropTransport

struct LiveAccountDependencies: AccountRegistrationDependencies {
    let mailboxManager: MailboxManager
    var deviceId: String { DeviceIdentity.deviceId }
    var platform: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }
    var attestSupported: Bool { if #available(iOS 14.0, macOS 11.0, *) { return DCAppAttestService.shared.isSupported } else { return false } }
    func identityKeys() throws -> (identity: Data, signing: Data) {
        (IdentityKeyManager.shared.publicKey.rawRepresentation, IdentityKeyManager.shared.signingPublicKey.rawRepresentation)
    }
    func sign(_ data: Data) throws -> Data { try IdentityKeyManager.shared.sign(data) }
    func currentMailboxId() async throws -> String {
        try await mailboxManager.registerIfNeeded()
        guard let id = await mailboxManager.mailboxId else { throw AccountClientError.invalidResponse }
        return id
    }
}
```
（`MailboxManager` 是 `@MainActor`，`Sendable` 需求以 `@unchecked Sendable` 或把 `mailboxManager` 存為 `@MainActor` 閉包解決 — 實作時選擇最少警告的方式並註明。）
- `handleScenePhaseChange(.active)`：在 `mailboxManager.startPolling()` 之後加 `Task { await accountManager.bootstrap() }`（`ScreenshotModeProvider.shared.isActive` 時改為 `accountManager` 不啟動；UI 讀 `mockAccount`）。
- `TrustedContact`：`public var userId: String?` → `public var accountId: String?`，`init` 參數同名改，`init(from:)` 以 `CodingKeys.accountId` 解碼；加 `enum CodingKeys: String, CodingKey { case id, deviceId, displayName, identityPublicKey, trustLevel, firstConnected, lastVerified, mailboxId, accountId = "userId", isBlocked, keyHistory, peerProtocolVersion }`（磁碟鍵沿用 `userId`）。全 repo `grep -rn "userId" PeerDropKit PeerDrop PeerDropMac` 修正呼叫點。
- `ScreenshotModeProvider`：`import PeerDropAccount`；`public var mockAccount: Account { Account(accountId: AccountID(raw: "PDRPDEM0")!, nickname: localizedName(("mochi", "麻糬", "麻薯", "もち", "모찌")), mailboxId: "screenshotmailbox", createdAt: Date().addingTimeInterval(-86400 * 30)) }`。

- [ ] **Step 5: 建置與測試**

Run: `cd PeerDropKit && swift build && swift test --filter "AccountManagerTests|TrustedContact" 2>&1 | tail -5 && cd .. && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && xcodebuild build -scheme PeerDropMac -destination 'platform=macOS,arch=arm64' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -quiet; echo "exit=$?"`
Expected: 4 + 既有 TrustedContact 測試 pass；兩平台建置成功。

- [ ] **Step 6: Commit**

```bash
git add PeerDropKit
git commit -m "feat(account): AccountManager state machine wired into ConnectionManager; TrustedContact.accountId"
```

---

### Task 10: iOS UI — 引導頁帳號頁、設定頁帳號區段、字串

**Files:**
- Modify: `PeerDrop/UI/OnboardingView.swift`、`PeerDrop/UI/SettingsView.swift`、`PeerDrop/App/Localizable.xcstrings`
- Create: `PeerDrop/UI/Account/AccountSectionView.swift`、`PeerDrop/UI/Account/NicknameEditorView.swift`、`PeerDrop/UI/Onboarding/OnboardingAccountPage.swift`

**Interfaces:**
- Produces: `struct AccountSectionView: View`（`@ObservedObject var accountManager: AccountManager`；跨平台，無 UIKit）；`struct NicknameEditorView: View`；`OnboardingView` 以 `[OnboardingPageModel]` 驅動，第 4 頁為 `OnboardingAccountPage`。
- 字串鍵（en 為鍵本身；四語值如下，逐字）：

| key | zh-Hant | zh-Hans | ja | ko |
|---|---|---|---|---|
| `Account` | 帳號 | 账号 | アカウント | 계정 |
| `Your PeerDrop ID` | 你的 PeerDrop ID | 你的 PeerDrop ID | あなたの PeerDrop ID | 내 PeerDrop ID |
| `Friends can send you notes with this ID or your nickname.` | 朋友可以用這個 ID 或你的暱稱傳紙條給你。 | 朋友可以用这个 ID 或你的昵称传纸条给你。 | 友だちはこの ID かニックネームであなたにメモを送れます。 | 친구는 이 ID나 닉네임으로 당신에게 쪽지를 보낼 수 있어요. |
| `Copy ID` | 複製 ID | 复制 ID | ID をコピー | ID 복사 |
| `Copied` | 已複製 | 已复制 | コピーしました | 복사됨 |
| `Nickname` | 暱稱 | 昵称 | ニックネーム | 닉네임 |
| `Optional. 3–20 letters, numbers or underscores.` | 選填。3 到 20 個字母、數字或底線。 | 选填。3 到 20 个字母、数字或下划线。 | 任意。3〜20 文字の英数字、文字、またはアンダースコア。 | 선택. 3~20자의 문자, 숫자 또는 밑줄. |
| `Nickname too short` | 暱稱太短 | 昵称太短 | ニックネームが短すぎます | 닉네임이 너무 짧습니다 |
| `Nickname too long` | 暱稱太長 | 昵称太长 | ニックネームが長すぎます | 닉네임이 너무 깁니다 |
| `Only letters, numbers and underscores` | 只能用字母、數字與底線 | 只能用字母、数字与下划线 | 文字・数字・アンダースコアのみ使えます | 문자, 숫자, 밑줄만 사용할 수 있습니다 |
| `This nickname is reserved` | 這個暱稱是保留字 | 这个昵称是保留字 | このニックネームは予約されています | 이 닉네임은 예약되어 있습니다 |
| `This nickname is already taken` | 這個暱稱已被使用 | 这个昵称已被使用 | このニックネームは既に使われています | 이 닉네임은 이미 사용 중입니다 |
| `Too many changes today. Try again tomorrow.` | 今天修改次數已達上限，明天再試。 | 今天修改次数已达上限，明天再试。 | 本日の変更回数の上限に達しました。明日もう一度お試しください。 | 오늘 변경 횟수를 초과했습니다. 내일 다시 시도하세요. |
| `Setting up your account…` | 正在建立帳號… | 正在创建账号… | アカウントを作成しています… | 계정을 만드는 중… |
| `Account not ready` | 帳號尚未就緒 | 账号尚未就绪 | アカウントの準備ができていません | 계정이 아직 준비되지 않았습니다 |
| `This Mac can't create an account (no Secure Enclave). Nearby sharing still works.` | 這台 Mac 無法建立帳號（沒有 Secure Enclave）。附近分享仍可使用。 | 这台 Mac 无法创建账号（没有 Secure Enclave）。附近分享仍可使用。 | この Mac ではアカウントを作成できません（Secure Enclave 非搭載）。近くの共有は引き続き使えます。 | 이 Mac에서는 계정을 만들 수 없습니다(Secure Enclave 없음). 근처 공유는 계속 사용할 수 있습니다. |
| `You're offline. We'll retry automatically.` | 目前離線，稍後會自動重試。 | 当前离线，稍后会自动重试。 | オフラインです。自動的に再試行します。 | 오프라인 상태입니다. 자동으로 다시 시도합니다. |
| `Retry` | 重試 | 重试 | 再試行 | 다시 시도 |
| `Delete Account` | 刪除帳號 | 删除账号 | アカウントを削除 | 계정 삭제 |
| `Delete your account?` | 要刪除帳號嗎？ | 要删除账号吗？ | アカウントを削除しますか？ | 계정을 삭제할까요? |
| `Your ID and nickname will be released. Notes and diaries tied to this account will be lost. Nearby sharing keeps working.` | 你的 ID 與暱稱將被釋放，與此帳號相關的紙條與日記會遺失。附近分享仍可使用。 | 你的 ID 与昵称将被释放，与此账号相关的纸条与日记会丢失。附近分享仍可使用。 | ID とニックネームは解放され、このアカウントに紐づくメモと日記は失われます。近くの共有は引き続き使えます。 | ID와 닉네임이 해제되고 이 계정에 연결된 쪽지와 일기는 사라집니다. 근처 공유는 계속 사용할 수 있습니다. |
| `Changing devices creates a new account. There is no account recovery yet.` | 換裝置會建立新帳號，目前尚無帳號還原功能。 | 换设备会创建新账号，目前尚无账号恢复功能。 | 端末を変えると新しいアカウントになります。アカウントの復元はまだできません。 | 기기를 바꾸면 새 계정이 만들어집니다. 아직 계정 복구 기능은 없습니다. |

- [ ] **Step 1: 字串**

腳本 `.superpowers/xcstrings_add.py`（不進 repo）以文字方式在 `"strings" : {` 之後插入每個鍵的區塊，格式：
```
    "<key>" : {
      "localizations" : {
        "ja" : { "stringUnit" : { "state" : "translated", "value" : "<ja>" } },
        "ko" : { "stringUnit" : { "state" : "translated", "value" : "<ko>" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "<zh-Hans>" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "<zh-Hant>" } }
      }
    },
```
（值以 `json.dumps` 逃逸；`'` 與 `…` 直接保留。）驗證：`python3 -c 'import json;d=json.load(open("PeerDrop/App/Localizable.xcstrings"))["strings"];print(len(d))'` 較之前多 22。

- [ ] **Step 2: `AccountSectionView` 與 `NicknameEditorView`**

`PeerDrop/UI/Account/AccountSectionView.swift`：
```swift
import SwiftUI
import PeerDropAccount
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Account rows shared by iOS Settings and Mac Profile tab (platform imports guarded; lint only scans PeerDropKit/Sources).
struct AccountSectionView: View {
    @ObservedObject var accountManager: AccountManager
    @State private var copied = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?

    var body: some View {
        Section {
            switch accountManager.state {
            case .ready(let account):
                LabeledContent("Your PeerDrop ID") {
                    HStack(spacing: 8) {
                        Text(account.accountId.display).font(.body.monospaced()).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy ID") { copy(account.accountId.display) }.buttonStyle(.borderless)
                    }
                }
                NavigationLink { NicknameEditorView(accountManager: accountManager) } label: {
                    LabeledContent("Nickname", value: account.nickname ?? "—")
                }
                Button(role: .destructive) { showDeleteConfirm = true } label: { Text("Delete Account") }
            case .registering, .idle:
                HStack { ProgressView(); Text("Setting up your account…") }
            case .unavailable(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account not ready").font(.headline)
                    Text(message(for: reason)).font(.caption).foregroundStyle(.secondary)
                    if reason != .attestUnsupported {
                        Button("Retry") { Task { await accountManager.registerIfNeeded() } }
                    }
                }
            }
        } header: { Text("Account") } footer: {
            Text("Changing devices creates a new account. There is no account recovery yet.")
        }
        .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await delete() } }
        } message: { Text("Your ID and nickname will be released. Notes and diaries tied to this account will be lost. Nearby sharing keeps working.") }
        .alert("Account not ready", isPresented: .constant(deleteError != nil)) { Button("OK") { deleteError = nil } } message: { Text(deleteError ?? "") }
    }

    private func message(for reason: AccountManager.Unavailable) -> LocalizedStringKey {
        switch reason {
        case .attestUnsupported: return "This Mac can't create an account (no Secure Enclave). Nearby sharing still works."
        case .offline: return "You're offline. We'll retry automatically."
        case .failed(let s): return LocalizedStringKey(s)
        }
    }
    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }
    private func delete() async {
        do { try await accountManager.deleteAccount(); await accountManager.registerIfNeeded() }
        catch { deleteError = String(describing: error) }
    }
}
```
`NicknameEditorView.swift`：
```swift
import SwiftUI
import PeerDropAccount

struct NicknameEditorView: View {
    @ObservedObject var accountManager: AccountManager
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var error: LocalizedStringKey?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("Nickname", text: $text).autocorrectionDisabled()
                    .onChange(of: text) { _ in error = localError() }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: { Text("Optional. 3–20 letters, numbers or underscores.") }
        }
        .navigationTitle("Nickname")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { Task { await save() } }.disabled(saving || error != nil) } }
        .onAppear { text = accountManager.account?.nickname ?? "" }
    }
    private func localError() -> LocalizedStringKey? {
        if text.isEmpty { return nil }
        switch Nickname.validate(text) {
        case .ok: return nil
        case .tooShort: return "Nickname too short"
        case .tooLong: return "Nickname too long"
        case .invalidCharacters: return "Only letters, numbers and underscores"
        case .reserved: return "This nickname is reserved"
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do { try await accountManager.setNickname(text.isEmpty ? nil : text); dismiss() }
        catch AccountClientError.conflict("nickname_taken") { error = "This nickname is already taken" }
        catch AccountClientError.rateLimited { error = "Too many changes today. Try again tomorrow." }
        catch AccountManager.NicknameError.reserved { error = "This nickname is reserved" }
        catch { error = LocalizedStringKey(String(describing: error)) }
    }
}
```

- [ ] **Step 3: 引導頁**

`OnboardingView` 重構：新增 `private struct OnboardingPageModel { let id: Int; let content: AnyView }`；`pages` 陣列由原五頁（保留原文案與圖示）+ 在索引 4 插入 `OnboardingAccountPage(accountManager:)`（總 6 頁，「You're All Set」最後）。`TabView` 用 `ForEach(pages, id: \.id) { $0.content.tag($0.id) }`；按鈕邏輯用 `pages.count - 1` 取代魔數。`OnboardingView` 加 `@EnvironmentObject var connectionManager: ConnectionManager` 並傳 `connectionManager.accountManager`。

`PeerDrop/UI/Onboarding/OnboardingAccountPage.swift`：
```swift
import SwiftUI
import PeerDropAccount

struct OnboardingAccountPage: View {
    @ObservedObject var accountManager: AccountManager
    @State private var nickname = ""
    @State private var nicknameError: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.text.rectangle").font(.system(size: 60)).foregroundStyle(.white)
            Text("Your PeerDrop ID").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
            switch accountManager.state {
            case .ready(let account):
                Text(account.accountId.display).font(.system(size: 34, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                Text("Friends can send you notes with this ID or your nickname.").font(.body).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 40)
                TextField("Nickname", text: $nickname).textFieldStyle(.roundedBorder).padding(.horizontal, 40)
                    .onSubmit { Task { await saveNickname() } }
                if let nicknameError { Text(nicknameError).font(.caption).foregroundStyle(.yellow) }
            case .registering, .idle:
                ProgressView().tint(.white); Text("Setting up your account…").foregroundStyle(.white.opacity(0.8))
            case .unavailable(.attestUnsupported):
                Text("This Mac can't create an account (no Secure Enclave). Nearby sharing still works.").foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 40)
            case .unavailable:
                Text("Account not ready").foregroundStyle(.white)
                Button("Retry") { Task { await accountManager.registerIfNeeded() } }.foregroundStyle(.white)
            }
            Spacer(); Spacer()
        }
        .task { await accountManager.bootstrap() }
    }
    private func saveNickname() async {
        guard !nickname.isEmpty else { return }
        do { try await accountManager.setNickname(nickname); nicknameError = nil }
        catch AccountClientError.conflict("nickname_taken") { nicknameError = "This nickname is already taken" }
        catch { nicknameError = "Only letters, numbers and underscores" }
    }
}
```

- [ ] **Step 4: 設定頁**

`SettingsView`：在 `Section("Profile")` 之後加 `AccountSectionView(accountManager: connectionManager.accountManager)`。

- [ ] **Step 5: 建置**

Run: `xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet && xcodebuild build -scheme PeerDropMac -destination 'platform=macOS,arch=arm64' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -quiet; echo "exit=$?"; python3 -c 'import json;d=json.load(open("PeerDrop/App/Localizable.xcstrings"))["strings"];print(len(d))'`
Expected: 兩平台建置成功（`PeerDrop/UI/Account` 與 `Onboarding` 自動進 Mac target；`OnboardingAccountPage` 若含 iOS-only API 則加進 project.yml Mac excludes）；鍵數 = 前值 + 22。

- [ ] **Step 6: Commit**

```bash
git add -A PeerDrop project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): onboarding account page, Settings account section, nickname editor, 22 strings in 5 languages"
```

---

### Task 11: Mac UI 與截圖模式

**Files:**
- Modify: `PeerDropMac/Views/MacSettingsView.swift:63-100`（Profile tab）、`PeerDropMac/App/PeerDropMacApp.swift`（screenshot mode 不 bootstrap）、`PeerDrop/App/PeerDropApp.swift`（同）
- Modify: `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift`（screenshot mode 時 `accountManager` 以 mock 狀態初始化）

**Interfaces:**
- Produces: Mac Profile tab 顯示 `AccountSectionView`；`AccountManager.init(mock:)`（`public convenience init(mock account: Account)` → `state = .ready(account)`，`didBootstrap = true`）。

- [ ] **Step 1: 實作**

- `AccountManager` 加 `public convenience init(mock account: Account)`（client 用 `AccountClient(baseURL: URL(string: "https://screenshot.invalid")!)`，store 用臨時目錄）。
- `ConnectionManager` 的 `accountManager` lazy 初始化：`ScreenshotModeProvider.shared.isActive ? AccountManager(mock: ScreenshotModeProvider.shared.mockAccount) : AccountManager(...)`。
- `ProfileSettingsTab`：在既有 Identity `Section` 之後加 `AccountSectionView(accountManager: connectionManager.accountManager)`。
- `PeerDropMacApp` 與 `PeerDropApp` 不需額外呼叫（`handleScenePhaseChange(.active)` 已 bootstrap）。

- [ ] **Step 2: 建置與 Mac 手動驗證**

Run: `xcodebuild build -scheme PeerDropMac -destination 'platform=macOS,arch=arm64' -derivedDataPath .superpowers/mac-dd CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=UK48R5KWLV CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES -quiet && open -n .superpowers/mac-dd/Build/Products/Debug/PeerDropMac.app --args -SCREENSHOT_MODE 1`
Expected: 建置成功；⌘, → Profile 分頁顯示帳號 `PDRP-DEM0` 與暱稱 `mochi`（截圖模式）。關閉 app。

- [ ] **Step 3: Commit**

```bash
git add -A PeerDropMac PeerDropKit PeerDrop
git commit -m "feat(mac): account section in Profile settings; screenshot-mode mock account"
```

---

### Task 12: 本機端到端驗證與 PR

> **已被最終修正波取代（2026-09-15，見規格 §7「2026-09-15 spike 結果」）**：本任務當時 BLOCKED
> （Mac 無 App Attest，且 `wrangler dev` 因 `src/index.ts` 的 `export const` 常數無法啟動）。兩個阻礙
> 都已在最終修正波處理，端到端驗證已於 2026-09-15 通過。

**Files:** 無新增；驗證。

- [ ] **Step 1: 本機 worker**

Run（背景）: `cd cloudflare-worker && npm run d1:migrate:local && npx wrangler dev --local --port 8787 --var APP_ATTEST_ALLOW_DEV:true > /tmp/claude-501/wrangler-dev.log 2>&1 &`
Expected: log 出現 `Ready on http://localhost:8787`。

- [ ] **Step 2: Mac dev build 指到本機 worker 並註冊**

Run: `defaults write com.hanfour.peerdrop.mac peerDropWorkerURL "http://localhost:8787" && open -n .superpowers/mac-dd/Build/Products/Debug/PeerDropMac.app`（先用 T11 的 build 重新建一次含 T11 之後的程式碼）。開啟 ⌘, → Profile。
Expected：
- Apple Silicon Mac：帳號區段在數秒內顯示 8 碼 ID；`npx wrangler d1 execute ACCOUNTS_DB --local --command "SELECT account_id, platform FROM accounts JOIN account_devices USING(account_id)"` 顯示一列 `macos`。
- 若顯示「This Mac can't create an account」：記錄 `DCAppAttestService.isSupported == false` 的事實，**回報 BLOCKED**，由 controller 依規格 §7 決定回退。
- 若 attest 對本機 worker 失敗（Apple 的 attestation 需連 Apple 伺服器驗證憑證鏈；`APP_ATTEST_ALLOW_DEV` 只放寬 AAGUID）：改用 iOS 模擬器？模擬器不支援 App Attest。改為：以真機 iPhone 走同一流程（Settings → Advanced Relay → Worker URL 設為區網 IP:8787）。記錄結果。

- [ ] **Step 3: 暱稱與目錄**

在 Mac Profile 設暱稱 `e2e_mac`；`curl -s http://localhost:8787/v3/directory/e2e_mac -H "Authorization: Bearer <從 log 或 keychain 取得的 token>"` 或直接用 D1 查 `nickname`。
Expected: D1 `nickname = 'e2e_mac'`。

- [ ] **Step 4: 清理與全量測試**

Run: `defaults delete com.hanfour.peerdrop.mac peerDropWorkerURL; kill %1 2>/dev/null; cd cloudflare-worker && npm test 2>&1 | tail -3 && cd ../PeerDropKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1 && cd .. && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -2`
Expected: worker 全過；Kit 只有已知 keychain 失敗；PeerDropTests 全過。

- [ ] **Step 5: 推送與 PR**

```bash
git push -u origin feat/account-foundation
gh pr create --base main --title "feat: account foundation (sub-project 1 of the notes/diary pivot)" --body "$(cat <<'EOF'
## Summary
- Worker: D1 `ACCOUNTS_DB` + migrations tooling; `/v3/account/{challenge,register,me,nickname}` + `DELETE /v3/account`; `/v3/directory/:handle` (optional pre-key bundle, 30/min); account-scoped device tokens issued by attest/assert based on device binding; App Attest accepts iOS + Mac bundle IDs; `/v2/inbox/:deviceId` now bound to the token's device.
- Client: new `PeerDropAccount` module (AccountID / Nickname / Account / AccountStore / AccountClient / AccountManager); `ConnectionManager.accountManager` bootstraps on `.active`; `DeviceTokenManager` on macOS 11+; Mac uses a dedicated client key + X-Device-Id (App Attest unsupported on native macOS); worker URL key unified.
- UI: onboarding "Your PeerDrop ID" page, Settings account section (iOS) and Profile tab (Mac) with nickname editor and account deletion; 22 strings × 5 languages.

Spec: `docs/superpowers/specs/2026-09-14-account-foundation-design.md`. Plan: `docs/superpowers/plans/2026-09-14-account-foundation.md`.

## Operator before merge
- `wrangler d1 create peerdrop-accounts` and set `database_id` in `cloudflare-worker/wrangler.toml` (if still the placeholder).
- After merge (auto-deploy): confirm `wrangler d1 migrations apply` ran in the deploy job.
- App privacy labels (iOS + Mac ASC): add User ID + Name (nickname), linked to user, app functionality; update `PrivacyInfo.xcprivacy`.

## Test plan
- [x] worker vitest (D1, /v3, auth, multi-bundle)
- [x] PeerDropKit `swift test` (Account module + transport)
- [x] iOS + Mac builds; PeerDropTests
- [ ] Local E2E: Mac dev build → local wrangler → account row in D1 (see Task 12 report)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01WwzkHxSjp7ou9MgGct5irQ
EOF
)"
```

---

## 併入後 operator 清單

1. 若 `database_id` 仍為佔位值：`wrangler d1 create peerdrop-accounts` → 填入 → 併入前 commit。
2. ASC 隱私標籤（iOS 6759594513、Mac 6793812911）：新增「使用者 ID」與「名稱」，連結使用者、用途 App 功能；`PrivacyInfo.xcprivacy` 同步（`NSPrivacyCollectedDataTypes`）。
3. Mac 版 release notes（子專案 2 出貨時）說明無 Secure Enclave 的 Mac 無法建帳號。
4. **Mac 金鑰通道（2026-09-15 取代原本的「Mac 走 App Attest」）**：`wrangler secret put MAC_CLIENT_KEY`
   設一把跟 `API_KEY` 不同的新值，並把同一個值填進 `Secrets.xcconfig` 的 `PEERDROP_MAC_CLIENT_KEY`
   後再出 Mac 版（兩邊不一致 = Mac 每條 relay 路由都 401）。未設定時 worker 會退回 `API_KEY`，
   所以先出 Mac 版再設 secret 不會斷線，但在設好之前 Mac 拿的是 operator 等級的金鑰——別這樣做。
   iOS 端不受影響（照舊 App Attest，Release 不帶金鑰）。
