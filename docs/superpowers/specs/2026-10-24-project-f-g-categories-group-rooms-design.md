# 專案 F＋G：朋友「分類」與「群組聊天室」— 設計規格

日期：2026-10-24
狀態：**草稿，待使用者核可**（核可前不實作；§0.2 列出需要明確核可的產品定位修改）
前置：UI 改版 A+B、專案 C（紙條進對話串）、專案 E（一直連線）已併入 main；主頁 Kakao 風格改版在 PR #190（草稿）。
參考：`docs/superpowers/specs/2026-09-23-diary-design.md`（`DiaryRoom`、邀請、金鑰、檢舉的既有做法，群組聊天室沿用其骨架）、專案 E 規格（一直連線、逐人同意的在線狀態）。

---

## 0. 目標、定案與產品檢查

**使用者要的東西（2026-10-24，Kakao 好友頁為藍本）**

1. **分類**（取代主頁現在的「群組」區）：朋友可放進分類。每個分類可單獨設定名稱、**對該分類顯示的狀態**（上線／離線／定時離線，例如每天幾點到幾點離線）、**通知開關**、**狀態消息的顯示設定**。
2. **群組**（保留）：清單裡是「群組聊天室」。每個人可建立多個、邀請不同人。每個聊天室有：顯示照片、聊天室背景、名稱、說明、主題類別、**參與設定**（只能用帳號名稱，或允許匿名參加）、**是否公開讓任何用戶搜尋**。
3. 主頁各清單的項目之間不畫分隔線（已在 PR #190）；聯絡人好友清單（已在 PR #190）。

**使用者已定案（本次對話）**

| 問題 | 決定 |
|---|---|
| 群聊訊息怎麼傳 | **經 Worker 轉送密文**；成員不必同網路，離線用推播與補抓 |
| 公開搜尋 | **第一版不做**；設定頁保留「公開」開關的位置，標示「即將推出」且停用 |
| 分類的「離線」 | **真的對該分類的朋友顯示離線**（不接受連線、退出一直連線房間）；通知與狀態消息也依分類設定，狀態消息隨連線傳給該分類的朋友 |

### 0.1 產品檢查清單（`product-goals.md` §6.1）

1. **服務哪根支柱**：分類服務「私」（對不同的人顯示不同的自己）；群組聊天室服務「留」（圈內人持續有地方聊）。不服務「慢」，見下。
2. **是否違反第 3 節原則**
   - 原則 1（私密優先）：群組聊天室內容為端對端加密，伺服器只看到密文；但伺服器必須知道**成員名單與房間設定**才能轉送與授權（§3.2 列出完整清單，與日記相同等級）。**不新增**寄收件關係記錄之外的行為資料。公開搜尋會讓伺服器保存房間的名稱／說明／類別，與原則 1 衝突，所以第一版不做。
   - 原則 2（慢優先於即時）：**群聊本質是即時聊天，與此原則衝突。** 緩解：預設不做已讀回條、正在輸入、在線人數；推播內容空白（「有新訊息」，不含群名、不含發話者）；分類的「離線／定時離線」讓使用者自己控制被看見的時段。
   - 原則 3（圈內優先於擴散）：群組只能靠邀請連結／邀請碼加入；不做探索、推薦、熱門榜。**匿名參加提高被濫用的風險**，見 §3.7。
3. **是否碰到 3.1 非目標**：**是。** 「**取代 LINE／IG：不做即時群聊**」直接衝突；「不做公開內容」「不做陌生人社交」在公開搜尋延後後不碰，但匿名參加仍擦邊。
4. **推動哪個指標**：輔助指標「圈內人互動頻率」。

### 0.2 需要使用者明確核可的定位修改（`product-goals.md` §6.2）

核可後我會在 `product-goals.md` 變更紀錄加一行：

- **§3.1「不做即時群聊」改為**：「不做**公開**即時群聊；允許**邀請制**群組聊天室（端對端加密、無已讀回條、無正在輸入、無在線人數）」。
- **§3 原則 2 補一句**：「群組聊天室是即時的例外，只在邀請制、內容空白推播、預設不暴露行為的前提下提供」。
- 公開搜尋維持非目標，不核可。

### 0.3 Builder 檢查後的決定（2026-10-25）

**我的決定（可推翻）**
- **「朋友」的定義**：`PresencePolicy` 與分類以**已釘選的身分公鑰**為鍵（`TrustedContact`），同一把公鑰底下的所有 `DeviceRecord`（區網、中繼）一併受規範，避免對方從另一筆紀錄連進來。
- **第二台裝置**：分類與設定**每台裝置獨立、不同步**（第一版）。群組聊天室的房內金鑰只在建立／加入它的那台裝置上，同帳號的另一台裝置在清單上**不顯示**該群組（D1 `group_members` 只用來做伺服器端授權與配額，不拿來決定客戶端清單）；要在另一台使用，需在那台以邀請碼重新加入。
- 已在等待金鑰的成員**不能發言**；換 `epoch` 後舊事件保持用舊 `epoch` 加密，持有舊金鑰者仍可解（成員會保留自己加入以來的所有世代金鑰）。
- 建立者自己的訊息與已關閉的房間：不推播給自己；`closed` 的房間仍可讀、可離開。

**需要使用者決定（見 §0.4）**：成員房內公鑰由誰擔保；匿名成員要對誰匿名；匿名成員怎麼收推播與檢舉。

### 0.4 待決安全問題與我的建議

1. **房內公鑰的真實性**：若伺服器被攻破或惡意，可以替換成員的房內公鑰而讀到訊息。**建議**：帳號成員的房內公鑰用其目錄簽章金鑰簽名、建立者對每次封裝簽名，客戶端驗章（同日記的 `verifySender`）；匿名成員無法驗證，介面標示「匿名」，並說明「匿名成員的身分由伺服器擔保」。
2. **匿名要對誰匿名**：目前實際行為是——`authorizeDevice` 只給 `deviceId`，但 `account_devices` 把裝置對到帳號，所以**伺服器能把匿名成員連回帳號**。**建議第一版：匿名＝對其他成員隱藏**，並誠實寫明伺服器仍可關聯；要對伺服器也匿名需要一種每個房間一次性的新授權通道，列為後置。
3. **匿名成員的推播與檢舉**：`fanOutPush` 只認 `accountId`，`reports.reporter_account_id` 是 NOT NULL。**建議**：依第 2 點，DO 內保存匿名成員的 `deviceId` 作推播收件者；`reports` 新增 `reporter_device_id`、`reporter_account_id` 改可空。

---

## 1. 範圍與分期

| 期 | 內容 | 伺服器 |
|---|---|---|
| **F1** | 分類：資料模型、取代主頁「群組」區、分類詳細頁（改名、移入移出朋友、通知開關、狀態消息）、現有 `DeviceGroup` 遷移 | 否 |
| **F2** | 狀態：上線／離線／定時離線的**強制**（連線與一直連線）、狀態消息隨連線送出與顯示 | 否（新增一個協定訊框） |
| **G1** | 群組聊天室後端與核心：`GroupRoom` DO、建立／邀請／加入／離開／踢出、金鑰與輪換、文字訊息、補抓、推播 | 是（migration v7、D1 0005） |
| **G2** | 群組聊天室介面：主頁「群組」清單、聊天室畫面、設定頁（照片、背景、名稱、說明、類別、參與設定）、檢舉與封鎖 | 否 |
| **後置** | 公開搜尋、圖片／檔案訊息、反應、訊息刪除與編輯、通知服務擴充（依分類過濾遠端推播）、多裝置 | — |

F1→F2→G1→G2 依序；F 與 G 互不依賴，可平行但建議先 F（風險低、立即可見）。

**非目標**（本規格不做）：公開搜尋與探索、圖片／影片／檔案訊息、訊息編輯與刪除、貼圖、已讀回條、正在輸入、在線人數、語音／視訊群通話、同帳號多裝置、成員角色細分（只有「建立者」與「成員」）、依分類過濾**遠端推播**（需要通知服務擴充，見 §2.6）。

---

## 2. 專案 F：分類

### 2.1 資料模型（本機，`ChatDataEncryptor` 加密落盤，仿 `DiaryStore` 的檔案存放；**不是** `DeviceGroupStore`——它把明文 JSON 存在 `UserDefaults`，分類不可沿用）

```swift
struct FriendCategory: Identifiable, Codable {
    let id: String                       // UUID
    var name: String                     // ≤ 20 字
    var order: Int
    var friendIDs: [String]              // DeviceRecord.id（同一位朋友最多出現在一個分類）
    var notificationsEnabled: Bool       // 預設 true
    var presence: CategoryPresence       // 預設 .online
    var statusMessage: String?           // ≤ 60 字
    var showStatusMessage: Bool          // 預設 true
}
enum CategoryPresence: Codable {
    case online
    case offline
    case scheduled(ScheduleWindow)       // 視窗內離線，視窗外上線
}
struct ScheduleWindow: Codable {
    var weekdays: Set<Int>               // 1…7，空集合＝每天
    var startMinute: Int                 // 0…1439，本機時區
    var endMinute: Int                   // 可小於 start（跨午夜）
}
```

未分類的朋友在「朋友」區，行為＝預設值（上線、通知開、狀態消息顯示）。**同一位朋友只能在一個分類**（Kakao 同款），避免設定互相打架；移入新分類即離開舊分類。

### 2.2 與現有 `DeviceGroup` 的關係

`DeviceGroup { id, name, deviceIDs }` 已有「全部連線」「群組聊天」（只能在直連的成員間）。處置：
- 啟動時**一次性遷移**：每個 `DeviceGroup` → 一個 `FriendCategory`（同 id、name、成員；成員同時在多個群組者歸入名稱排序最前的那個）。**遷移來源是 `UserDefaults` 裡的明文 JSON**；寫入新的加密檔後，舊的 `UserDefaults` 鍵保留一個版本以便回退，之後刪除。
- 「全部連線」移到分類詳細頁。
- 舊的 P2P「群組聊天」入口移除（`GroupChatView`、`ChatManager` 的群組訊息保留程式碼但不再有入口，G1 完成後一併刪除）。**這是移除既有功能，請核可**（見 §7）。

### 2.3 介面

主頁區段順序：**已連線**（連著的朋友）→ **分類**（每個分類一列：名稱、人數、狀態圖示；點進去是詳細頁）→ **朋友**（未分類）→ **群組**（G2）→ **聯絡人**（通訊錄邀請）。分類詳細頁：朋友清單（可加入／移出）、名稱、狀態（上線／離線／定時離線＋時段選擇）、通知開關、狀態消息（文字＋顯示開關）。朋友列上長按／左滑「移到分類…」。

### 2.4 狀態的強制（F2）

`PresencePolicy.isVisible(friendID, at: Date) -> Bool`：取朋友所在分類的 `presence`；`.offline` → false；`.scheduled(w)` → 現在在視窗內則 false；未分類或 `.online` → true。**只改變「對方看到我什麼」，不改變我看到對方什麼。**
不可見時：
1. **直連（區網）**：收到來自該朋友的連線，在 HELLO 解出身分（已釘選金鑰）後**不回應地 `cancel()`**（沿用專案 E 降級的做法：不送任何訊框，對方看到的與網路中斷無法區分）；我主動撥號也不撥給他們。
2. **一直連線**：離開該朋友的碰面房間（`RendezvousManager` 對該聯絡人視同關閉，且不得送任何額外訊框）；轉成可見時再加入。
3. **Bonjour 廣播無法逐人隱藏**：對方在同一個區網仍會在「附近」看到我，只是連不上（與專案 E 同樣的已知側信道，文件與說明頁誠實寫出）。
4. 排程在 App 前景時用單一計時器（下一個切換點）重算；背景時一直連線本來就關閉，直連本來就不被喚醒，所以**背景不需要排程**。

### 2.5 狀態消息（F2）

新增一個**加密的點對點訊框** `statusUpdate { text: String?, updatedAt }`（只在安全通道建立後送）。**舊版客戶端不能收到它**：`MessageType` 是封閉列舉，未知類型會讓 `PeerMessage.decoded` 丟錯，`startReceiving` 的 catch 會把連線標成失敗並斷線。所以必須**能力協商**：HELLO 新增 `supportsStatusUpdate`（沿用 `supportsNotesExchange` 的做法，只在安全信封內才採信），對方沒宣告就**完全不送**。送出規則：連線建立時、以及分類的狀態消息／顯示開關變更時，對**當下連線中**的該分類朋友送；`showStatusMessage == false` 時送 `text: nil`（清除對方那邊的顯示）。收到端存進 `DeviceRecord.statusMessage`／`statusUpdatedAt`，朋友列副標題優先顯示（Kakao 同款），離線時顯示最後一次內容。**不經伺服器**，所以沒連線的朋友在下次連線才更新。

### 2.6 通知（F1）

分類 `notificationsEnabled == false`：該分類朋友的**本機呈現**不響不震不顯示橫幅（直連聊天、已綁定朋友的紙條在 App 內的提示）。**限制（誠實寫進說明）**：紙條與日記的遠端推播是內容空白的通用推播（為了隱私），App 收到時還不知道是誰寄的，所以**遠端推播無法依分類過濾**；要做到需要通知服務擴充（Notification Service Extension＋共用鑰匙圈群組），列為後置。

### 2.7 F 的測試重點

遷移（多群組成員歸屬、空群組、id 保留）；`PresencePolicy` 表格測試（跨午夜、星期、時區、整點邊界）；離線時直連來電不送任何訊框；一直連線房間退出且不送額外訊框；狀態消息清除；舊版客戶端對 `statusUpdate` 的反應；Mac 同步設定視窗。

---

## 3. 專案 G：群組聊天室

### 3.1 概念

一個聊天室＝一個由建立者擁有的邀請制房間，成員 ≤ 50（第一版），每個帳號最多參與 20 個。內容端對端加密；伺服器轉送密文並保存最近的密文供補抓。**沿用 `DiaryRoom` 的骨架**（邀請連結＋短碼、`diary_members`／`diary_invites` 式 D1 索引、`fanOutPush`、檢舉表），差異是：即時（WebSocket）、無輪流、金鑰要能**輪換**（有人被踢或離開）、**可匿名成員**。

### 3.2 伺服器看得到什麼（隱私清單，與日記同級）

明文：`roomId`、建立者帳號 ID、成員清單（帳號成員＝accountId；匿名成員＝房內隨機 `memberId`，**不連到帳號**）、`joinPolicy`（`accountOnly`／`anonymousAllowed`，必須明文因為伺服器要在加入時強制）、`discoverability`（第一版固定 `private`，欄位保留）、狀態（open／closed）、成員數、金鑰世代 `epoch`、每筆事件的 seq／作者 memberId／大小／時間。
密文（伺服器讀不到）：名稱、說明、主題類別、照片、背景、所有訊息、各成員在房內的顯示名稱。

### 3.3 伺服器

`GroupRoom` Durable Object（`[[migrations]] tag = "v7" new_sqlite_classes = ["GroupRoom"]`，名稱＝客戶端產生的 ULID `roomId`）。key/value：

```
meta  → { roomId, ownerMemberId, members: [{memberId, kind: "account"|"anon", accountId?, joinedAt, pubKey}],
          joinPolicy, discoverability: "private", state: "open"|"closed", epoch, seq, inviteCode, metaCipher, createdAt, bytesUsed }
ev:<seq 補零 12 碼> → { seq, eventId, type: "msg"|"join"|"leave"|"kick"|"meta", authorMemberId, epoch, payloadCipher?, createdAt }
key:<epoch>:<memberId> → 以該成員 pubKey 封裝的 roomKey（建立者上傳）
eid:<eventId> → seq
```

- **認證**：帳號成員用 `authorizeV3`；**匿名成員用 `authorizeDevice`（裝置權杖，不需帳號）**，伺服器只看到裝置 ID，且該對應只存在 DO 內、不寫 D1 帳號表。`joinPolicy == accountOnly` 的房間拒絕 `authorizeDevice` 加入（403 `account_required`）。
- **WebSocket**：`GET /v3/groups/:id/ws`（Hibernation API）。連線＝這位成員正在看這個房間；伺服器把新事件廣播給所有已連線成員，並對**未連線**成員送內容空白的推播。心跳、單一 IP／帳號上限、2 小時硬上限沿用專案 E 的規矩。
- **補抓**：`GET /v3/groups/:id/events?since=&limit=100`，與日記相同；保留最近 5,000 筆或 90 天（先到者），更舊的刪除，客戶端本機保存自己的歷史。
- **事件**：`msg`（`payloadCipher` ≤ 8 KB，明文文字 ≤ 4,000 字）、`join`／`leave`／`kick`（無 payload）、`meta`（建立者更新 `metaCipher`＋可選的新 `epoch`）。冪等 `eventId`，與日記相同。
- **成員**：`POST /v3/groups`（建立）、`POST /v3/groups/:id/join`（連結）、`POST /v3/groups/join`（短碼）、`POST /v3/groups/:id/leave`、`POST /v3/groups/:id/kick {memberId}`（建立者）、`POST /v3/groups/:id/close`、`POST /v3/groups/:id/invite/reset`。上限與錯誤碼沿用日記（`group_full_members`、`group_limit`、錯碼每小時 10 次）。
- **金鑰與輪換**：見 §3.4。
- **D1（`0005_groups.sql`）**：`group_members(account_id, group_id, joined_at)`（只放帳號成員，供「我的群組」清單）、`group_invites(invite_code, group_id)`、`reports` 加 `group_id`、`group_seq`（SQLite 重建，仿 `0003_diary.sql`）。
- **推播**：`fanOutPush` 送 `{type:"groupMessage", groupId}`，alert 文字固定「有新訊息」，不含群名與發話者；同一房間 60 秒內合併（節流）。

### 3.4 金鑰（沿用日記的邀請，新增輪換）

- 每個成員**加入時**產生一把**房內專用 X25519 金鑰對**，公鑰隨 join 送給伺服器（匿名與帳號成員一視同仁，所以不依賴紙條信箱）。
- `roomKey`（AES-256-GCM，32 B）由建立者產生；建立者用**每位成員的房內公鑰**封裝（ECDH＋HKDF＋AES-GCM，AAD 含 `roomId‖epoch‖memberId`）後上傳 `key:<epoch>:<memberId>`；成員用自己的房內私鑰取回解開。新成員加入時，**任何持有現行金鑰的成員**的客戶端都可以補封裝（成員端 sync 看到 `join` 事件驅動，同日記 `DiaryKeyRelay`：任何持金鑰的成員、`keyRequest` 推給所有成員），所以建立者離線不會卡住新成員；**只有建立者能輪換**（產生新 `epoch`）。
- **邀請連結** `peerdrop://group/<roomId>?code=<inviteCode>`，**不帶金鑰**（與日記不同：因為金鑰會輪換，不能把當下的金鑰放進長期存在的連結）。
- **輪換**：成員離開或被踢 → 建立者客戶端產生新 `epoch` 的 `roomKey`、重新封裝給剩下的成員、更新 `metaCipher`（用新金鑰重新加密）；新訊息用新 `epoch`。被踢者無法解新訊息；舊訊息他本來就看過。**建立者離線時成員離開或被踢不立即輪換**（下次建立者上線時補），這個延遲風險寫進說明頁。
- 訊息加密：AAD = `roomId ‖ memberId ‖ eventId ‖ epoch(UInt32 BE)`；`payloadCipher` = nonce(12) ‖ ciphertext ‖ tag(16)。`DiaryCrypto` 的向量測試方法照搬。

### 3.5 聊天室設定（`metaCipher` 內，建立者可改）

| 項目 | 規格 |
|---|---|
| 名稱 | ≤ 30 字，必填 |
| 說明 | ≤ 200 字 |
| 主題類別 | 固定列舉：聊天／家人／朋友／興趣／學習／工作／旅行／其他（可擴充） |
| 照片 | JPEG ≤ 128 KB（客戶端縮到 512×512） |
| 背景 | 預設圖樣 id，或自訂 JPEG ≤ 256 KB（客戶端縮到 1080 寬） |
| **參與設定** | `accountOnly`／`anonymousAllowed`（**明文**在 meta，伺服器強制）。改成 `accountOnly` 時，既有匿名成員保留還是移除由建立者選（預設保留，避免突然踢人） |
| **公開** | 開關**停用**，標示「即將推出」；`discoverability` 固定 `private` |

照片與背景放在 `metaCipher` 內（一次更新≤ 400 KB，DO 單值上限內；超過回 413）。每個成員自己可在本機覆寫背景（只影響自己）。

### 3.6 匿名參加

- 加入時選「用帳號名稱」或「匿名」（只在 `anonymousAllowed` 的房間出現選項）。匿名成員在房內顯示一個**房內暱稱**（自己取，或隨機形容詞＋動物），名稱放在加密的 join 後第一則「身分」訊息／成員表，伺服器看不到。
- 匿名成員的 `memberId` 是隨機值，伺服器不存帳號；他不能建立房間、不能邀請（只有建立者的連結／短碼可以用，且是否允許轉傳不另限制）。
- **濫用緩解**：建立者可踢任何成員（匿名以 `memberId`）；任何成員可**檢舉**（客戶端解密、附上下文摘要，進 `reports`，與日記同機制）與**本機封鎖**某 `memberId`；被踢的匿名裝置（裝置權杖）進入該房的黑名單（DO 內存裝置 ID 雜湊，無法重新加入同一房）。`anonymousAllowed` 預設**關閉**。

### 3.7 App Review 與合規

- 多人聊天＋匿名＝使用者生成內容：**必須**有檢舉、封鎖、可聯絡開發者、對不當內容的處置流程（App Store 審查指南 1.2）。檢舉與封鎖在 G2 一併做，不能延後。
- **年齡分級**：群聊與匿名可能使分級問卷的答案改變（目前 4+，Mac 版也是 4+）；送審前重填問卷並可能升到 12+。**這會影響上架，須使用者決定是否接受。**
- **隱私標籤**：伺服器新保存「群組成員關係」與「事件中介資料」；標籤與隱私政策頁要更新（與日記同級，標籤已列「User ID、Name、產品互動」）。
- **Worker 成本**：每個正在看聊天室的成員一條 WebSocket；需要 Workers 付費方案或證實免費額度足夠，沿用專案 E 的 2 小時實測與用量警示。

### 3.8 客戶端

- 模組 `PeerDropKit/Sources/PeerDropGroups`（依賴 Security、Transport、Account；`PeerDropCore` 依賴 Groups）：`GroupStore`（清單、事件日誌落盤 `Documents/Groups/<roomId>/…`，仿 `DiaryStore`）、`GroupClient`（HTTP＋WebSocket）、`GroupCrypto`（訊息與金鑰封裝，共用測試向量放 `cloudflare-worker/test-vectors/`）、`GroupKeyRelay`（建立者補封裝／輪換）。
- UI（`PeerDrop/UI/Groups/`，無 UIKit/AppKit）：主頁「群組」區（每列：照片、名稱、最後一則的預覽**只顯示在本機解密後**、未讀數）、`GroupChatView`（沿用聊天氣泡元件，背景用房間背景）、`GroupSettingsView`（§3.5）、建立精靈、邀請（連結／短碼／分享）、成員清單（檢舉、封鎖、踢出）。
- Mac：同樣的視窗與鍵盤路徑；通知設定沿用。

### 3.9 G 的測試重點

伺服器：加入政策強制（匿名被 `accountOnly` 擋）、冪等、金鑰世代與被踢者拿不到新金鑰、WebSocket 廣播與離線推播節流、5,000 筆保留、`reports` 重建、DO 不被任意 id 建出空房間。客戶端：加解密向量、輪換、等待金鑰狀態、離線補抓排序與去重、匿名房內暱稱不洩漏帳號、檢舉摘要。端到端：本機 Worker＋三個獨立程序（沿用專案 E 的 harness）。

---

## 4. 建議的實作拆分（每個都是一個可獨立審查的 SDD 任務序列）

F1（分類資料模型＋遷移＋介面）→ F2（狀態強制＋狀態消息訊框）→ G1a（伺服器 `GroupRoom`＋D1＋路由＋測試向量）→ G1b（客戶端 `PeerDropGroups` 與金鑰／輪換）→ G2a（聊天室與主頁清單介面）→ G2b（設定頁、檢舉封鎖、匿名）→ 整體審查與本機三程序 E2E → 實機驗證。

## 5. 風險與未決

1. **產品定位**：§0.2 的修改需要使用者核可；否則 G 整個不做，只做 F。
2. 年齡分級升級（§3.7）。
3. 建立者離線期間無法輪換金鑰（§3.4）——若要避免，需要「多位管理員」，已列為非目標。
4. WebSocket 成本與 Workers 方案。
5. 區網 Bonjour 無法逐人隱藏（§2.4）。
6. 遠端推播無法依分類過濾（§2.6）。
7. 移除舊 P2P 群組聊天入口（§2.2）。
8. 遷移 `DeviceGroup` 時成員同屬多組的歸屬規則是我的預設。

## 6. 實作者自行決定的部分

UI 的視覺細節與動畫；DO 內部的索引與清理排程；`PresencePolicy` 的計時器實作；房內暱稱的隨機詞庫；各字串的五語系翻譯（ja／ko／zh-Hans 需母語者審稿）。
