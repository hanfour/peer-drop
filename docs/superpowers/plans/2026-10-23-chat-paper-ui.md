# 聊天「紙感」改版（第一階段）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 iPhone 與 Mac 的聊天畫面（1 對 1 與群組）改成暖色、圓潤的「紙感」外觀，保留所有既有機制，只換外觀與文案。

**Architecture:** 新增一層共用主題（`PaperTheme`，色票＋淺色／夜間自適應）與兩個可單元測試的純邏輯（連發分組、名字退路），其餘都是把既有聊天元件改用主題。不改通訊協定、加密、儲存格式。

**Tech Stack:** SwiftUI（iOS 16+／macOS 14+，`PeerDrop/UI` 兩平台共用）、XCTest、XcodeGen（新增 Swift 檔後要 `xcodegen generate`）、`Localizable.xcstrings`（en／zh-Hant／zh-Hans／ja／ko）。

**Spec:** `docs/superpowers/specs/2026-10-23-chat-paper-ui-design.md`（執行者必須先讀，本計畫的色票、文案、決定都出自它）

**Base:** 從 `main` 切新分支 `feat/chat-paper-ui`。**PR #182（`fix/reconnect-feedback`）必須先合併**，因為它改了 `ChatView` 的橫幅按鈕與 `MacChatWindow`，與本計畫的檔案重疊。

## Global Constraints

- 不改通訊協定、加密、儲存格式；**勾勾的判斷邏輯、訊息行為（回覆、反應、編輯、刪除、已讀回條、正在輸入）完全不變**，只換外觀。
- 淺色與夜間跟隨系統外觀，不另設開關；夜間是**暖棕**，不是墨藍。
- 起始色票（淺色／夜間）：底 `#FBF6EE`／`#2A221C`；邊框 `#EFE4D3`／`#3A2F27`；對方泡泡 `#FFFFFF`（加 1pt 邊框）／`#3A3029`；自己泡泡 `#F6C9A8`／`#B97A52`；泡泡文字 `#4A3B2E`（淺色，對方與自己）、夜間對方 `#EADBC8`、自己 `#1F1610`；日期藥丸 底 `#F1E6D4`／`#3A3029`、字 `#8A7561`／`#B7A58F`；輸入列 底白／`#3A3029`、提示字 `#B3A391`／`#8F7D69`；送出鈕 `#F0A878`／`#D89268`。**起始值可為通過對比檢查而調整。**
- 一般文字對比 ≥ 4.5:1（WCAG AA）；輸入框提示字 ≥ 3:1。
- 勾勾**不用藍色或青色**；「已送達」與「已讀」必須一眼可分。
- 泡泡全圓角（18pt），說話者那一側的下角收小到 6pt；系統圓體（`.rounded` design），不引入字體檔；不加紙紋理、陰影、擬物裝飾。
- 輸入框提示固定寫 `Aa`（五種語言相同，不翻譯）；`accessibilityLabel` 仍用既有的 `Message`。
- 連發：**1 對 1 與群組一律只在連發的第一則顯示頭像與名字**，之後的訊息保留頭像縮排；連發在說話者改變、跨日、與上一則相隔超過 300 秒時中斷；自己的訊息不顯示頭像與名字。
- 頭像本階段用 `PeerAvatar`（依名字自動產生），位置是固定寬度欄位，第二階段才換真實照片。
- 導覽列保留系統結構，只套暖色背景與圓體標題；強調色（tint）只在聊天畫面內局部設定，**不改全域 accent／tint**。
- 保留所有既有的 `accessibilityLabel`／`accessibilityHint`；最大 Dynamic Type 仍可讀。
- **不要編輯 `docs/product/product-goals.md`**；只在 PR 說明標註與其第 2 條的差異，交給使用者。
- 專案慣例：commit 格式 `type: short description`，結尾 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`；永遠不用 `git commit -a`，只 `git add` 指定檔案；新增 Swift 檔後執行 `xcodegen generate`；字串 key 若只差標點會產生相同 Swift 符號，要避免。
- `Localizable.xcstrings` **不可用 JSON 工具整檔重寫**（檔內格式不一致，會產生巨大無關 diff），一律以文字插入或就地修改條目，改完用 `python3 -c "import json;json.load(open(...))"` 確認仍是合法 JSON，並確認 `git diff --stat` 只有預期的行數。
- 沒有自動化 UI 測試，**不要假裝有**；視覺項目靠 T10 的實際畫面檢查。

## Review Focus

1. 名字為 nil、空字串、純空白、極長 → 輔助函式回 nil 走退路字串，極長名字截斷不換行爆版（T3 測試、T5 視覺）。
2. 連發邊界：剛好 300 秒仍同一連發、301 秒中斷；跨午夜；舊版訊息 `senderID == nil`（T2 測試）。
3. 已刪除、已編輯的訊息仍正常參與連發分組，不改變其行為（T2 測試）。
4. 往前載入更早訊息時，陣列最前面那一則視為連發第一則（分頁邊界）（T2 測試）。
5. 夜間與淺色、最大字級下的對比：所有文字配色組合通過 4.5:1（T1 測試）、提示字 3:1（T1 測試）、最大字級實機檢查（T10）。

## File Structure

| 檔案 | 責任 |
|---|---|
| Create `PeerDrop/UI/Components/PaperTheme.swift` | 色票 token、淺色／夜間數值、對比計算、自適應 `Color` |
| Create `PeerDropKit/Sources/PeerDropCore/ChatMessageRuns.swift` | 純邏輯：哪些訊息是連發第一則、哪些是當天第一則 |
| Create `PeerDropKit/Sources/PeerDropCore/ChatDisplayName.swift` | 純邏輯：名字去空白、缺失回 nil |
| Create `PeerDrop/UI/Chat/ChatAvatarSlot.swift` | 固定寬度頭像欄位（顯示 `PeerAvatar` 或留白） |
| Create `PeerDrop/UI/Chat/ChatDatePill.swift` | 日期藥丸分隔（新） |
| Create `PeerDrop/UI/Chat/EmptyChatView.swift` | 空對話畫面（新） |
| Modify `PeerDrop/UI/Components/PeerAvatar.swift` | 加 `size` 參數（預設 40，不影響既有呼叫） |
| Modify `PeerDrop/UI/Chat/ChatBubbleView.swift` | 泡泡外觀、勾勾、連發標頭 |
| Modify `PeerDrop/UI/Chat/ChatView.swift` | 背景、輸入列、附件選單、橫幅、日期藥丸、空狀態、連發計算 |
| Modify `PeerDrop/UI/Chat/GroupChatView.swift` | 群組泡泡（獨立的 `GroupChatBubbleView`）與輸入列、連發、日期、空狀態 |
| Modify `TypingIndicatorView.swift`、`DecryptFailureBannerView.swift`、`ReactionPickerView.swift`、`GroupReadReceiptView.swift`、`ChatSearchView.swift`、`MediaPreviewView.swift`、`PeerDrop/UI/Components/StatusToastView.swift` | 只換色與字體 |
| Modify `PeerDropMac/Views/MacChatWindow.swift` | 視窗背景 |
| Modify `PeerDrop/App/Localizable.xcstrings` | 文案（T8） |
| Test `PeerDropTests/PaperThemeTests.swift`、`PeerDropKit/Tests/PeerDropCoreTests/ChatMessageRunsTests.swift`、`ChatDisplayNameTests.swift` | 新測試 |

> 注意：**群組聊天有自己獨立的 `GroupChatBubbleView` 與輸入列**（在 `GroupChatView.swift`），不與 `ChatBubbleView` 共用，所以要各自改（T6）。群組泡泡只有文字，沒有媒體、反應、回覆。

---

### Task 1: PaperTheme（色票與對比測試）

**Files:**
- Create: `PeerDrop/UI/Components/PaperTheme.swift`
- Test: `PeerDropTests/PaperThemeTests.swift`

**Interfaces:**
- Produces:
  - `enum PaperToken { case background, border, incomingBubble, outgoingBubble, incomingText, outgoingText, datePillFill, datePillText, inputFill, inputPlaceholder, sendButton, tickSent, tickDelivered, tickRead, tickFailed, quoteBar, typingDot }`
  - `enum PaperPalette { static func hex(_ token: PaperToken, dark: Bool) -> UInt32; static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double }`（WCAG 相對亮度公式）
  - `enum PaperTheme { static func color(_ token: PaperToken) -> Color; static func tick(for status: MessageStatus) -> PaperToken }`（`color` 依系統外觀自適應：iOS 用動態 `UIColor`，macOS 用 `NSColor(name:dynamicProvider:)`；`tick` 的 `.sending` 回 `.tickSent`、`.sent` 回 `.tickSent`、`.delivered` 回 `.tickDelivered`、`.read` 回 `.tickRead`、`.failed` 回 `.tickFailed`）

- [ ] **Step 1: Write the failing tests** in `PeerDropTests/PaperThemeTests.swift`（`@testable import PeerDrop`、`@testable import PeerDropCore`）
  - `testTextPairsMeetAA`：對 `dark in [false, true]`，下列組合 `contrastRatio >= 4.5`：(incomingText, incomingBubble)、(outgoingText, outgoingBubble)、(incomingText, background)、(datePillText, datePillFill)。
  - `testPlaceholderMeets3to1`：(inputPlaceholder, inputFill) 兩種模式 `>= 3.0`。
  - `testDeliveredAndReadTicksAreDistinctAndNotBlue`：兩種模式下 `hex(.tickDelivered) != hex(.tickRead)`，且 `.tickRead` 的色**不是藍色系**（`b > r && b > g` 為 false，其中 r、g、b 取自 hex 的三個分量）。
  - `testTickTokenMapping`：`tick(for: .delivered) != tick(for: .read)`、`tick(for: .failed) == .tickFailed`。
  - `testContrastRatioKnownValues`：`contrastRatio(0x000000, 0xFFFFFF)` 約 21.0（誤差 0.01）、`contrastRatio(0x777777, 0xFFFFFF)` 約 4.48（誤差 0.05）。
- [ ] **Step 2: Run to verify it fails** — `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PaperThemeTests`；Expected: 編譯失敗（`PaperPalette` 未定義）。
- [ ] **Step 3: Implement** `PaperPalette`、`PaperTheme`。數值取 Global Constraints 的起始色票；`tickSent`／`tickDelivered`／`tickRead`／`tickFailed`／`quoteBar`／`typingDot` 是新 token，起始值由實作者選（暖色系；`tickRead` 用比泡泡更深或更飽和的暖色，`tickFailed` 用暖紅），並確保它們在 `outgoingBubble` 上的對比 ≥ 3:1。
- [ ] **Step 4: Run tests until they pass** — 同 Step 2 的指令；Expected: PASS。若對比測試失敗，**調整色票數值**（保持暖色），不要放寬測試門檻；把調整後的值與原因寫進 commit 說明。
- [ ] **Step 5: Commit** — `git add PeerDrop/UI/Components/PaperTheme.swift PeerDropTests/PaperThemeTests.swift PeerDrop.xcodeproj/project.pbxproj && git commit -m "feat(chat): PaperTheme palette with contrast tests"`

### Task 2: 連發分組邏輯

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/ChatMessageRuns.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/ChatMessageRunsTests.swift`

**Interfaces:**
- Produces: `public enum ChatMessageRuns { public static let defaultGap: TimeInterval = 300; public static func firstInRunIDs(in messages: [ChatMessage], gap: TimeInterval = defaultGap, calendar: Calendar = .current) -> Set<String>; public static func dayStartIDs(in messages: [ChatMessage], calendar: Calendar = .current) -> Set<String> }`
- 說話者 key：`message.senderID ?? (message.isOutgoing ? "\u{0}me" : "\u{0}peer")`（舊版 1 對 1 訊息沒有 `senderID`）。
- 第一則訊息永遠是連發第一則、也永遠是當天第一則；與前一則相隔**大於** `gap` 秒、說話者 key 不同、或 `calendar` 判定跨日，都是新連發；`dayStartIDs` 只看是否跨日。

- [ ] **Step 1: Write the failing tests** in `ChatMessageRunsTests`（測試內自建 `ChatMessage` 的 helper，可指定 `timestamp`、`senderID`、`isOutgoing`、`isDeleted`；用固定的 `Calendar(identifier: .gregorian)` 與 UTC 時區）：
  - `testEmptyReturnsEmpty`
  - `testFirstMessageIsAlwaysRunStart`（也涵蓋「往前載入更早訊息後，陣列最前面一則是連發第一則」）
  - `testSameSenderWithinGapIsOneRun`：同人連 3 則各隔 60 秒 → 只有第 1 則在集合內。
  - `testSenderChangeStartsNewRun`
  - `testExactly300SecondsStaysInRun`、`test301SecondsStartsNewRun`
  - `testCrossingMidnightStartsNewRunAndNewDay`：同人 23:59 與隔日 00:01（只隔 2 分鐘）→ 第二則同時在 `firstInRunIDs` 與 `dayStartIDs`。
  - `testGroupSendersDistinguishedBySenderID`：兩個不同 `senderID` 的訊息（皆非自己）相鄰 → 各自連發第一則。
  - `testLegacyMessagesWithoutSenderIDFallBackToIsOutgoing`：`senderID == nil` 且 `isOutgoing` 不同 → 分成兩個連發；相同 → 同一連發。
  - `testDeletedMessagesStillParticipate`：中間一則 `isDeleted == true`，不改變前後訊息的連發判定。
- [ ] **Step 2: Run to verify it fails** — `cd PeerDropKit && swift test --filter ChatMessageRunsTests`；Expected: 編譯失敗。
- [ ] **Step 3: Implement** 上述兩個靜態函式。
- [ ] **Step 4: Run tests** — 同上；Expected: 全部 PASS。
- [ ] **Step 5: Commit** — `git add PeerDropKit/Sources/PeerDropCore/ChatMessageRuns.swift PeerDropKit/Tests/PeerDropCoreTests/ChatMessageRunsTests.swift && git commit -m "feat(chat): message run grouping logic"`

### Task 3: 名字退路輔助函式

**Files:**
- Create: `PeerDropKit/Sources/PeerDropCore/ChatDisplayName.swift`
- Test: `PeerDropKit/Tests/PeerDropCoreTests/ChatDisplayNameTests.swift`

**Interfaces:**
- Produces: `public enum ChatDisplayName { public static func trimmed(_ name: String?) -> String? }`：去掉前後空白與換行，結果為空或輸入為 nil 回 `nil`。退路字串（「對方」「這個群組」）由 View 層用 `String(localized:)` 提供（Core 模組沒有在地化）。

- [ ] **Step 1: Write the failing tests**：`testNilReturnsNil`、`testEmptyReturnsNil`、`testWhitespaceOnlyReturnsNil`（含 `"  \n\t "`）、`testNormalNameIsTrimmed`（`"  小安 "` → `"小安"`）、`testLongNameIsNotTruncated`（200 字元原樣返回，截斷是顯示端的事）。
- [ ] **Step 2: Run to verify it fails** — `cd PeerDropKit && swift test --filter ChatDisplayNameTests`；Expected: 編譯失敗。
- [ ] **Step 3: Implement** `trimmed`。
- [ ] **Step 4: Run tests**；Expected: PASS。
- [ ] **Step 5: Commit** — `git add PeerDropKit/Sources/PeerDropCore/ChatDisplayName.swift PeerDropKit/Tests/PeerDropCoreTests/ChatDisplayNameTests.swift && git commit -m "feat(chat): display-name fallback helper"`

### Task 4: 1 對 1 泡泡外觀

**Files:**
- Modify: `PeerDrop/UI/Chat/ChatBubbleView.swift`（`MessageBubbleShape.tailR`、`bubbleColor`、`statusView`、`replyPreview`、文字與時間的 `foregroundStyle`、字體）

**Interfaces:**
- Consumes: `PaperTheme.color(_:)`、`PaperTheme.tick(for:)`（T1）。
- Produces: 無新公開介面（泡泡外觀改變）。

- [ ] **Step 1: Implement** — `MessageBubbleShape` 的 `tailR` 由 2 改為 6；`bubbleColor` 改用 `incomingBubble`／`outgoingBubble`（現在外送是寫死的綠色 `Color(red: 0.21, green: 0.78, blue: 0.35)`）；對方泡泡加 1pt `border` 描邊；所有文字、時間、「edited」、刪除訊息的顏色改用 `incomingText`／`outgoingText`（含透明度版本）；字體加 `design: .rounded`；`statusView` 的各狀態顏色改用 `PaperTheme.tick(for:)`（**保留 switch 的結構與條件不動**，只換色；青色 `.cyan` 與白色移除）；`replyPreview` 的藍色改 `quoteBar`。
- [ ] **Step 2: Build both targets** — iOS：`xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`；macOS：`xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet`；Expected: BUILD SUCCEEDED。
- [ ] **Step 3: Run existing app tests** — `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'`；Expected: 全過（不得有既有測試失敗）。
- [ ] **Step 4: Commit** — `git add PeerDrop/UI/Chat/ChatBubbleView.swift && git commit -m "feat(chat): paper-style bubbles and status ticks"`

### Task 5: 1 對 1 的連發、頭像與日期

**Files:**
- Create: `PeerDrop/UI/Chat/ChatAvatarSlot.swift`、`PeerDrop/UI/Chat/ChatDatePill.swift`
- Modify: `PeerDrop/UI/Components/PeerAvatar.swift`、`PeerDrop/UI/Chat/ChatBubbleView.swift`、`PeerDrop/UI/Chat/ChatView.swift`（訊息 `ForEach`）

**Interfaces:**
- Consumes: `ChatMessageRuns`（T2）、`ChatDisplayName.trimmed`（T3）、`PaperTheme`（T1）。
- Produces:
  - `PeerAvatar.init(name: String, size: CGFloat = 40)`（字體隨 size 等比縮放；既有呼叫不受影響）
  - `struct ChatAvatarSlot: View { let name: String; let visible: Bool; static let width: CGFloat }`：`visible` 為 true 顯示 `PeerAvatar(name:size:)`（`width` 取 32），否則留同寬的空白。
  - `struct ChatDatePill: View { let date: Date }`：藥丸形，字用 `date.formatted(.dateTime.month().day().weekday())`（跟隨語系），色用 `datePillFill`／`datePillText`。
  - `ChatBubbleView` 新增參數 `runStart: Bool = true`（預設值讓既有呼叫與預覽不用改）與 `senderFallbackName: String = String(localized: "Other person")`（key 與翻譯在 T8）。

- [ ] **Step 1: Implement** — `ChatView` 在 `ForEach` 外算 `let runStarts = ChatMessageRuns.firstInRunIDs(in: chatManager.messages)` 與 `dayStarts = ChatMessageRuns.dayStartIDs(in: chatManager.messages)`；`dayStarts.contains(message.id)` 時，在該訊息前插入 `ChatDatePill(date: message.timestamp)`；`ChatBubbleView` 傳入 `runStart: runStarts.contains(message.id)`。`ChatBubbleView` 對**對方**訊息：左側放 `ChatAvatarSlot(name:visible: runStart)`，`runStart` 時在泡泡上方顯示名字（`ChatDisplayName.trimmed(message.peerName) ?? senderFallbackName`，`lineLimit(1)`、尾端省略、`.caption` 圓體）；自己的訊息不顯示頭像與名字。泡泡最大寬度要把頭像欄位的寬度扣掉，避免擠出畫面。
- [ ] **Step 2: Build both targets**（指令同 T4 Step 2）；Expected: BUILD SUCCEEDED。
- [ ] **Step 3: Run existing app tests**；Expected: 全過。
- [ ] **Step 4: Visual check on simulator** — 在 iPhone 16 模擬器開聊天（用 `-SCREENSHOT_MODE` 的假資料或測試訊息），確認：連發只有第一則有頭像與名字、其餘留縮排且泡泡左緣對齊、跨日有日期藥丸、長名字（自行塞 60 字的名字）被截斷成一行。
- [ ] **Step 5: Commit** — `git add PeerDrop/UI/Chat/ChatAvatarSlot.swift PeerDrop/UI/Chat/ChatDatePill.swift PeerDrop/UI/Components/PeerAvatar.swift PeerDrop/UI/Chat/ChatBubbleView.swift PeerDrop/UI/Chat/ChatView.swift PeerDrop.xcodeproj/project.pbxproj && git commit -m "feat(chat): run grouping, avatar slot and date separators"`

### Task 6: 群組聊天（獨立的泡泡與輸入列）

**Files:**
- Modify: `PeerDrop/UI/Chat/GroupChatView.swift`（`GroupChatView` 的訊息迴圈與 `inputBar`；`GroupChatBubbleView` 的色、形狀、`statusIcon`）

**Interfaces:**
- Consumes: T1、T2、T3、T5 的 `ChatAvatarSlot`／`ChatDatePill`。
- Produces: `GroupChatBubbleView` 新增參數 `runStart: Bool = true`。

- [ ] **Step 1: Implement** — `GroupChatBubbleView`：泡泡色、文字色、形狀改用 `PaperTheme` 與 `MessageBubbleShape`（把 `RoundedRectangle(cornerRadius: 16)` 換掉）；對方訊息比照 T5：`ChatAvatarSlot` ＋ `runStart` 時顯示名字（`ChatDisplayName.trimmed(message.senderName) ?? String(localized: "Other person")`，取代現在的藍色 `.blue` 名字）；`statusIcon` 的顏色改 `PaperTheme.tick(for:)`，**保留 `readCount`／`totalMembers` 的判斷與計數顯示不動**（現況：已讀人數 > 0 才用「已讀」色）。`GroupChatView`：比照 T5 計算 `runStarts`／`dayStarts`（以 `chatManager.groupMessages`），插入 `ChatDatePill`；`inputBar` 的 `TextField` 提示改 `Aa`（`accessibilityLabel("Message")` 保留）、底色與送出鈕色改 `PaperTheme`（現在送出鈕是 `.green`）。
- [ ] **Step 2: Build both targets**；Expected: BUILD SUCCEEDED。
- [ ] **Step 3: Run existing app tests**；Expected: 全過。
- [ ] **Step 4: Commit** — `git add PeerDrop/UI/Chat/GroupChatView.swift && git commit -m "feat(chat): paper style for group chat"`

### Task 7: 聊天外框（輸入列、附件、橫幅、提示、輸入中）

**Files:**
- Modify: `PeerDrop/UI/Chat/ChatView.swift`（根背景、`inputBar`、`AttachmentMenuSheet`、`replyPreviewBar`、`.swipeActions` 的 `.tint(.blue)`、導覽列標題字）、`TypingIndicatorView.swift`、`DecryptFailureBannerView.swift`、`PeerDrop/UI/Components/StatusToastView.swift`、`PeerDropMac/Views/MacChatWindow.swift`

**Interfaces:**
- Consumes: `PaperTheme`（T1）。

- [ ] **Step 1: Implement** — 根 view 背景 `PaperTheme.color(.background)`；導覽列保留系統結構，標題字改圓體；在**聊天根 view 上**加局部 `.tint(PaperTheme.color(.sendButton))`（不動全域）；`inputBar` 的 `TextField("Message", …)` 改為 `TextField("Aa", …)` 並加 `.accessibilityLabel("Message")`；輸入框底色 `inputFill`、1pt `border`、提示字色 `inputPlaceholder`（用 `prompt:`）；`+`／麥克風／送出圖示的灰、紅、綠改用主題（錄音中的紅色維持紅，因為是警示）；`replyPreviewBar`、`swipeActions` 的藍色改主題；`TypingIndicatorView` 的灰點改 `typingDot`、底色改 `datePillFill`；`DecryptFailureBannerView`、`StatusToastView`、`AttachmentMenuSheet` 的背景與強調色改主題；`MacChatWindow` 的視窗背景用 `PaperTheme.color(.background)`。
- [ ] **Step 2: Build both targets**；Expected: BUILD SUCCEEDED。
- [ ] **Step 3: Run existing app tests**；Expected: 全過。
- [ ] **Step 4: Commit** — `git add PeerDrop/UI/Chat/ChatView.swift PeerDrop/UI/Chat/TypingIndicatorView.swift PeerDrop/UI/Chat/DecryptFailureBannerView.swift PeerDrop/UI/Components/StatusToastView.swift PeerDropMac/Views/MacChatWindow.swift && git commit -m "feat(chat): paper style for input bar, banners, toasts and typing"`

### Task 8: 文案、空對話畫面與在地化

**Files:**
- Create: `PeerDrop/UI/Chat/EmptyChatView.swift`
- Modify: `PeerDrop/UI/Chat/ChatView.swift`（橫幅文字、toast 文字、空狀態）、`PeerDrop/UI/Chat/GroupChatView.swift`（空狀態，**只有它真的有對應介面時**才加其他字串）、`PeerDrop/App/Localizable.xcstrings`

**Interfaces:**
- Produces: `struct EmptyChatView: View { let message: String }`（置中、圓體、`.secondary` 以外的暖色小字，不加動畫）。
- 新字串（key → 繁體中文；`%@` 是名字）：
  - `Connection to %@ lost` → 和%@的連線中斷了
  - `Back to Nearby` → 回到附近（**修改既有條目**的 zh-Hant）
  - `Recording too short` → 錄音太短，再多說幾句吧（修改既有）
  - `Voice message failed` → 語音沒有送出去，再試一次吧（修改既有）
  - `File too large to send in chat (max %lld MB)` → 檔案太大了，聊天裡最多可以傳 %lld MB（新；數字從 `MediaMessagePayload.maxInlineFileSize / (1024 * 1024)` 帶入，**取代** PR #182 加的 `File too large to send in chat`，ChatView 改用新 key，舊 key 條目刪除）
  - `Can't find %@ nearby. Make sure they have PeerDrop open.` → 附近找不到%@，請確認對方已打開 PeerDrop（新，**取代** `Device not found nearby`，同樣刪舊條目）
  - `No messages yet. Say hello to %@.` → 還沒有訊息，跟%@打聲招呼吧（新）
  - `No messages yet. Say hello to everyone.` → 還沒有訊息，跟大家打聲招呼吧（新）
  - `Other person` → 對方；`This group` → 這個群組（新，名字缺失的退路）
- 其他三種語言（zh-Hans、ja、ko）由實作者翻譯，**狀態標為 `needs_review`**（zh-Hant 為 `translated`），並在 PR 說明列出待校對的 key。

- [ ] **Step 1: Implement** — 橫幅文字改 `Text("Connection to \(name) lost")`（`name = ChatDisplayName.trimmed(peerName) ?? String(localized: "Other person")`；群組版本退路用 `"This group"`），保留 `disconnectReason ?? ...` 的原有分支結構；`sendFile` 的檔案太大 toast 改新 key；`Reconnect` 失敗 toast 改新 key 並帶名字；`ChatView` 與 `GroupChatView` 在訊息為空時顯示 `EmptyChatView`。
- [ ] **Step 2: Edit `Localizable.xcstrings` by text insertion／in-place edits** — 完成後 `python3 -c "import json;json.load(open('PeerDrop/App/Localizable.xcstrings',encoding='utf-8'))"` 無錯誤；`git diff --stat PeerDrop/App/Localizable.xcstrings` 只有預期條目的增刪。
- [ ] **Step 3: Build both targets and run existing app tests**；Expected: BUILD SUCCEEDED、測試全過。
- [ ] **Step 4: Visual check** — 在模擬器把語言切到 zh-Hant 與 en，確認空對話、橫幅、三個 toast 的文字與名字代入正確（名字為空時顯示「對方」）。
- [ ] **Step 5: Commit** — `git add PeerDrop/UI/Chat/EmptyChatView.swift PeerDrop/UI/Chat/ChatView.swift PeerDrop/UI/Chat/GroupChatView.swift PeerDrop/App/Localizable.xcstrings PeerDrop.xcodeproj/project.pbxproj && git commit -m "feat(chat): friendlier copy, empty chat state and localization"`

### Task 9: 其餘聊天周邊元件

**Files:**
- Modify: `PeerDrop/UI/Chat/ReactionPickerView.swift`、`GroupReadReceiptView.swift`、`ChatSearchView.swift`、`MediaPreviewView.swift`

- [ ] **Step 1: Find leftovers** — `grep -n "\.blue\|\.cyan\|\.green\|Color\.gray\|Color\.green" PeerDrop/UI/Chat/*.swift`；列出仍在用冷色或舊綠色的位置。
- [ ] **Step 2: Implement** — 這四個檔案只換色與字體（改 `PaperTheme`／圓體）；`MediaPreviewView` 維持黑底全螢幕（圖片預覽需要），只把資訊列的字體改圓體；不動手勢與行為。
- [ ] **Step 3: Build both targets and run existing app tests**；Expected: 全過。
- [ ] **Step 4: Commit** — `git add PeerDrop/UI/Chat/ReactionPickerView.swift PeerDrop/UI/Chat/GroupReadReceiptView.swift PeerDrop/UI/Chat/ChatSearchView.swift PeerDrop/UI/Chat/MediaPreviewView.swift && git commit -m "feat(chat): paper style for reactions, read receipts, search and preview"`

### Task 10: 實際畫面驗證（iPhone、Mac、淺色、夜間、最大字級）

**Files:** 無程式碼；若發現缺陷，回到對應任務修正並補測試（可測的邏輯）。

- [ ] **Step 1: Full suites** — `cd PeerDropKit && swift test`（Expected: 只剩既有失敗 `IdentityKeyManagerTests.testKeyPersistsAcrossInstances`）；app 層 `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'`（Expected: 全過）。
- [ ] **Step 2: Simulator matrix** — 在 iPhone 16 模擬器，淺色與夜間（`xcrun simctl ui booted appearance light|dark`）、一般與最大字級（`xcrun simctl ui booted content_size accessibility-extra-extra-extra-large`），各用 `xcrun simctl io booted screenshot <檔名>` 截圖：文字／圖片／檔案／語音泡泡、五種勾勾狀態、日期藥丸、連發與頭像縮排、正在輸入、回覆引用、反應、中斷橫幅、三個 toast、空對話、附件選單、群組聊天。
- [ ] **Step 3: Real devices** — 把 iPhone 版與 Mac 開發版（用 Apple Development 憑證簽署）裝到實機，兩台互傳一組訊息、照片、PDF、語音，確認畫面與模擬器一致；Mac 檢查輸入框焦點環沒被裁切、滑鼠 hover 正常、視窗最小尺寸（480×480）內版面不破。**這一步要請使用者在手機上操作並回報。**
- [ ] **Step 4: 對照 spec 第 2 節的反目標** — 逐項確認沒有出現：幼稚／卡通、紙紋理或陰影、對比不足、兩平台差異過大、行為被改動。
- [ ] **Step 5: Open the PR** — PR 說明列出：分兩階段（本 PR 只含第一階段）、與 `product-goals.md` 第 2 條的差異（**未修改該文件，請使用者決定**）、待校對的 ja／ko／zh-Hans 字串 key、附截圖、未涵蓋項目（未讀紅點在入口畫面、頭像交換、紙條與日記）。
