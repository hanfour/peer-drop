# App Store Release Preparation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prepare PeerDrop v1.0.0 for App Store submission — complete UI localisation (5 languages), add onboarding flow, verify app icon, and create code signing guide.

**Architecture:** Localisation uses Apple String Catalog (xcstrings) with SwiftUI's automatic LocalizedStringKey resolution. Onboarding is a fullScreenCover gated by @AppStorage. No new dependencies.

**Tech Stack:** SwiftUI, Apple String Catalog (.xcstrings), @AppStorage, TabView (PageTabViewStyle)

---

### Task 1: Verify App Icon Configuration

**Files:**
- Check: `PeerDrop/App/Assets.xcassets/AppIcon.appiconset/Contents.json`

**Step 1: Verify Contents.json format**

The current Contents.json uses `"idiom": "universal"` with `"platform": "ios"` and a single 1024x1024 image. This is the Xcode 15+ single-size format that auto-generates all required sizes at build time. This works for iOS 16+ deployment target.

Read the file and confirm it matches:
```json
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

**Step 2: Verify the icon file exists and is valid**

Run: `file PeerDrop/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
Expected: PNG image, 1024x1024

**Step 3: Build to confirm no icon warnings**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | grep -i icon`
Expected: No icon-related warnings

No commit needed — verification only.

---

### Task 2: Scan and Collect Missing Localisation Strings

**Files:**
- Read: All `.swift` files under `PeerDrop/UI/`
- Read: `PeerDrop/App/Localizable.xcstrings`

**Step 1: Extract all hardcoded user-facing strings from SwiftUI views**

Search all UI .swift files for these patterns and identify strings NOT present in Localizable.xcstrings:
- `Text("...")`
- `Button("...")`
- `Label("...", systemImage:)`
- `.navigationTitle("...")`
- `.alert("...",`
- `.confirmationDialog("...",`
- `.accessibilityLabel("...")`
- `.accessibilityHint("...")`
- Inline string literals used in `.searchable(text:, prompt:)`

**Step 2: Create a complete list of missing strings**

Document each missing string with:
- The English text
- Which file and line it appears in
- Suggested translations for zh-Hant, zh-Hans, ja, ko

**Step 3: Verify which strings are already in xcstrings**

Cross-reference against existing 120 entries in Localizable.xcstrings.

No commit — research task for Task 3.

---

### Task 3: Add Missing Strings to Localizable.xcstrings

**Files:**
- Modify: `PeerDrop/App/Localizable.xcstrings`

**Step 1: Add all missing strings identified in Task 2**

For each missing string, add an entry in this format to the `"strings"` object:

```json
"English text here" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "English text here" } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "Japanese translation" } },
    "ko" : { "stringUnit" : { "state" : "translated", "value" : "Korean translation" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "Simplified Chinese translation" } },
    "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "Traditional Chinese translation" } }
  }
}
```

Known missing strings from research (non-exhaustive — Task 2 will find the complete list):

| English | zh-Hant | zh-Hans | ja | ko |
|---------|---------|---------|----|----|
| Load earlier messages | 載入更早的訊息 | 加载更早的消息 | 以前のメッセージを読み込む | 이전 메시지 불러오기 |
| An unknown error occurred. | 發生未知錯誤。 | 发生未知错误。 | 不明なエラーが発生しました。 | 알 수 없는 오류가 발생했습니다. |
| The peer declined your connection request. | 對方拒絕了你的連線請求。 | 对方拒绝了你的连接请求。 | 相手が接続リクエストを拒否しました。 | 상대방이 연결 요청을 거부했습니다. |
| Messages are stored on this device only. | 訊息僅儲存在此裝置上。 | 消息仅存储在此设备上。 | メッセージはこのデバイスにのみ保存されます。 | 메시지는 이 기기에만 저장됩니다. |
| Export or import your device records, transfer history, and chat data. | 匯出或匯入裝置記錄、傳輸歷史和聊天資料。 | 导出或导入设备记录、传输历史和聊天数据。 | デバイス記録、転送履歴、チャットデータをエクスポートまたはインポートします。 | 기기 기록, 전송 기록, 채팅 데이터를 내보내거나 가져옵니다. |
| Archive Error | 封存錯誤 | 归档错误 | アーカイブエラー | 아카이브 오류 |
| Secure peer-to-peer sharing | 安全的點對點分享 | 安全的点对点分享 | セキュアなピアツーピア共有 | 안전한 P2P 공유 |

**Step 2: Build to verify no localisation warnings**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: Clean build, no warnings

**Step 3: Commit**

```bash
git add PeerDrop/App/Localizable.xcstrings
git commit -m "i18n: add missing UI strings for all 5 languages"
```

---

### Task 4: Create OnboardingView

**Files:**
- Create: `PeerDrop/UI/OnboardingView.swift`

**Step 1: Write the OnboardingView**

Create a 4-page TabView with PageTabViewStyle. Must match LaunchScreen.swift design:
- Blue gradient background (adapts to dark mode)
- White text, bold rounded font for titles
- PhoneChatWifiShape as brand element on page 1
- SF Symbols for pages 2-3
- "Get Started" button on page 4

```swift
import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    @Environment(\.colorScheme) private var colorScheme

    private var gradientColors: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.12, green: 0.32, blue: 0.78), Color(red: 0.16, green: 0.24, blue: 0.72)]
            : [Color(red: 0.22, green: 0.49, blue: 0.98), Color(red: 0.28, green: 0.38, blue: 0.95)]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack {
                TabView(selection: $currentPage) {
                    // Page 1: Welcome
                    OnboardingPage(
                        icon: { AnyView(PhoneChatWifiShape().fill(.white).frame(width: 80, height: 80)) },
                        title: "Welcome to PeerDrop",
                        subtitle: "Secure peer-to-peer sharing"
                    ).tag(0)

                    // Page 2: Discover
                    OnboardingPage(
                        icon: { AnyView(Image(systemName: "wifi").font(.system(size: 60)).foregroundStyle(.white)) },
                        title: "Discover Nearby Devices",
                        subtitle: "Find devices on your local network automatically"
                    ).tag(1)

                    // Page 3: Transfer
                    OnboardingPage(
                        icon: { AnyView(Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 60)).foregroundStyle(.white)) },
                        title: "Share Anything",
                        subtitle: "Send files, photos, videos, and messages securely"
                    ).tag(2)

                    // Page 4: Get Started
                    OnboardingPage(
                        icon: { AnyView(Image(systemName: "checkmark.circle").font(.system(size: 60)).foregroundStyle(.white)) },
                        title: "You're All Set",
                        subtitle: "Start sharing with nearby devices"
                    ).tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                // Bottom button area
                Button {
                    if currentPage < 3 {
                        withAnimation { currentPage += 1 }
                    } else {
                        hasCompletedOnboarding = true
                    }
                } label: {
                    Text(currentPage < 3 ? "Next" : "Get Started")
                        .font(.headline)
                        .foregroundStyle(gradientColors[0])
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

                if currentPage < 3 {
                    Button("Skip") {
                        hasCompletedOnboarding = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 24)
                } else {
                    Spacer().frame(height: 48)
                }
            }
        }
    }
}

private struct OnboardingPage: View {
    let icon: () -> AnyView
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            icon()
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: Clean build

**Step 3: Commit**

```bash
git add PeerDrop/UI/OnboardingView.swift
git commit -m "feat: add onboarding view with 4-page welcome flow"
```

---

### Task 5: Integrate Onboarding into ContentView

**Files:**
- Modify: `PeerDrop/UI/ContentView.swift:14-24`

**Step 1: Add onboarding gate to ContentView**

Add `@AppStorage` property and `.fullScreenCover` to ContentView:

```swift
// Add after line 22 (after statusToastMessage state):
@AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
```

Add `.fullScreenCover` after the `.alert` block (after line 88), before `.onChange`:

```swift
.fullScreenCover(isPresented: Binding(
    get: { !hasCompletedOnboarding },
    set: { if !$0 { hasCompletedOnboarding = true } }
)) {
    OnboardingView()
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: Clean build

**Step 3: Commit**

```bash
git add PeerDrop/UI/ContentView.swift
git commit -m "feat: integrate onboarding gate into ContentView"
```

---

### Task 6: Add Onboarding Strings to Localizable.xcstrings

**Files:**
- Modify: `PeerDrop/App/Localizable.xcstrings`

**Step 1: Add all onboarding strings**

Add these entries to xcstrings:

| English | zh-Hant | zh-Hans | ja | ko |
|---------|---------|---------|----|----|
| Welcome to PeerDrop | 歡迎使用 PeerDrop | 欢迎使用 PeerDrop | PeerDrop へようこそ | PeerDrop에 오신 것을 환영합니다 |
| Secure peer-to-peer sharing | 安全的點對點分享 | 安全的点对点分享 | セキュアなピアツーピア共有 | 안전한 P2P 공유 |
| Discover Nearby Devices | 發現附近裝置 | 发现附近设备 | 近くのデバイスを検出 | 주변 기기 검색 |
| Find devices on your local network automatically | 自動尋找同一網路上的裝置 | 自动查找同一网络上的设备 | ローカルネットワーク上のデバイスを自動検出 | 로컬 네트워크의 기기를 자동으로 찾습니다 |
| Share Anything | 分享一切 | 分享一切 | なんでも共有 | 무엇이든 공유 |
| Send files, photos, videos, and messages securely | 安全傳送檔案、照片、影片和訊息 | 安全发送文件、照片、视频和消息 | ファイル、写真、動画、メッセージを安全に送信 | 파일, 사진, 영상, 메시지를 안전하게 전송 |
| You're All Set | 準備就緒 | 准备就绪 | 準備完了 | 준비 완료 |
| Start sharing with nearby devices | 開始與附近裝置分享 | 开始与附近设备分享 | 近くのデバイスとの共有を開始 | 주변 기기와 공유를 시작하세요 |
| Next | 下一步 | 下一步 | 次へ | 다음 |
| Get Started | 開始使用 | 开始使用 | 始める | 시작하기 |
| Skip | 略過 | 跳过 | スキップ | 건너뛰기 |

**Step 2: Build to verify**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`

**Step 3: Commit**

```bash
git add PeerDrop/App/Localizable.xcstrings
git commit -m "i18n: add onboarding strings for all 5 languages"
```

---

### Task 7: Add OnboardingView to Xcode Project

**Files:**
- Modify: `project.yml` (if XcodeGen is used to manage file references)
- OR verify file is auto-included via directory-based target

**Step 1: Check if XcodeGen auto-includes new files**

Read `project.yml` and check if PeerDrop target uses directory-based sources (e.g., `sources: PeerDrop/`). If so, running `xcodegen generate` will pick up OnboardingView.swift automatically.

**Step 2: Regenerate project if needed**

Run: `xcodegen generate` (if project uses XcodeGen)
OR verify the file is already included in the Xcode project.

**Step 3: Full build verification**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`

**Step 4: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: All 169+ tests pass

No commit needed — verification only.

---

### Task 8: Write Code Signing Guide

**Files:**
- Create: `docs/code-signing-guide.md`

**Step 1: Write the guide**

Create a step-by-step document covering:

1. **Apple Developer Program** — Enroll at developer.apple.com ($99/year)
2. **App Store Connect Setup** — Create the app record with bundle ID `com.hanfour.peerdrop`
3. **Xcode Signing Configuration**:
   - Open project in Xcode
   - Select PeerDrop target > Signing & Capabilities
   - Check "Automatically manage signing"
   - Select your team
   - Xcode auto-creates provisioning profiles
4. **Required Capabilities** (already declared in Info.plist):
   - Background Modes: audio, voip
   - Bonjour Services: _peerdrop._tcp
   - Local Network Usage
   - Microphone, Camera, Photo Library access
5. **Archive & Upload**:
   - Product > Archive
   - Organizer > Distribute App > App Store Connect
   - OR use Fastlane: `fastlane deliver`
6. **Fastlane API Key Setup** (optional):
   - Generate App Store Connect API key
   - Configure in `fastlane/Appfile`

**Step 2: Commit**

```bash
git add docs/code-signing-guide.md
git commit -m "docs: add code signing and App Store submission guide"
```

---

### Task 9: Final Verification

**Files:** None — verification only

**Step 1: Clean build**

Run: `xcodebuild clean build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
Expected: Build succeeds with no warnings

**Step 2: Full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'`
Expected: All tests pass (169+)

**Step 3: Verify localisation coverage**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep -i "localiz"`
Expected: No missing localisation warnings

**Step 4: Verify app icon**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep -i "icon"`
Expected: No icon warnings

**Step 5: Push all changes**

```bash
git push origin main
```
