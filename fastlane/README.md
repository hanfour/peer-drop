# Fastlane Screenshot Automation

This directory contains Fastlane configuration for automated App Store screenshot capture.

## Setup

1. Install dependencies:
   ```bash
   cd /Users/hanfourmini/Projects/applications/peer-drop
   bundle install
   ```

2. Run screenshots:
   ```bash
   # Using xcodebuild directly (recommended)
   xcodebuild test -scheme PeerDropUITests \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
     -only-testing:PeerDropUITests/SnapshotTests \
     CODE_SIGNING_REQUIRED=NO

   # Using Fastlane
   bundle exec fastlane screenshots
   ```

## How It Works

Since iOS simulators cannot perform real P2P connections, the app includes a **Screenshot Mode** that injects mock data when launched with the `-SCREENSHOT_MODE 1` argument.

### Screenshot Mode Components

- **ScreenshotModeProvider** (`PeerDrop/Core/ScreenshotModeProvider.swift`): Provides localized mock data for discovered peers, connections, chat messages, and contacts.

- **ConnectionManager** modifications: Automatically injects mock discovered peers and creates mock connections in screenshot mode.

- **ChatManager** modifications: Returns mock chat messages for mock peer IDs.

### Test Coverage

The screenshot tests capture **23 screenshots** (13 Light + 10 Dark mode):

#### Light Mode (`SnapshotTests`)

| # | Screenshot | Description |
|---|------------|-------------|
| 01 | NearbyTab | Device discovery list view |
| 02 | NearbyTabGrid | Device discovery grid view |
| 03 | ConnectedTab | Active connections and contacts |
| 04 | ConnectionView | Connection detail with action buttons |
| 05 | ChatView | Chat conversation |
| 06 | VoiceCallView | Voice call interface |
| 07 | LibraryTab | Device library and groups |
| 08 | Settings | App settings screen |
| 09 | QuickConnect | Manual connect sheet |
| 10 | FileTransfer | File picker/transfer UI |
| 11 | TransferHistory | Transfer history view |
| 12 | UserProfile | User profile settings |
| 13 | GroupDetail | Group detail view |

#### Dark Mode (`SnapshotTestsDark`)

| # | Screenshot | Description |
|---|------------|-------------|
| 01 | NearbyTab_Dark | Device discovery (dark) |
| 02 | NearbyTabGrid_Dark | Grid view (dark) |
| 03 | ConnectedTab_Dark | Connections (dark) |
| 04 | ConnectionView_Dark | Connection detail (dark) |
| 05 | ChatView_Dark | Chat conversation (dark) |
| 06 | VoiceCallView_Dark | Voice call (dark) |
| 07 | LibraryTab_Dark | Library (dark) |
| 08 | Settings_Dark | Settings (dark) |
| 09 | QuickConnect_Dark | Manual connect (dark) |
| 10 | FileTransfer_Dark | File transfer (dark) |

## Output

Screenshots are saved to `~/Library/Caches/tools.fastlane/` organized by device name:
- `iPhone 17 Pro Max-01_NearbyTab.png`
- `iPhone 17 Pro-01_NearbyTab.png`
- `iPad Pro 13-inch (M5)-01_NearbyTab.png`

## Device Support

The app supports both iPhone and iPad (Universal app). Screenshots are captured for:

| Device | Screen Size | Required |
|--------|------------|----------|
| iPhone 17 Pro Max | 6.9" | Yes |
| iPhone 17 Pro | 6.7" | Yes |
| iPad Pro 13-inch | 12.9" | Yes |

## Localization

Mock data automatically adapts to the device's language setting:

| Language | Code | Example Names |
|----------|------|---------------|
| English | en-US | "Sarah's MacBook Pro", "James's iPhone" |
| Traditional Chinese | zh-Hant | "小美的 MacBook Pro", "阿傑的 iPhone" |
| Simplified Chinese | zh-Hans | "小美的 MacBook Pro", "阿杰的 iPhone" |
| Japanese | ja | "さくらの MacBook Pro", "健太の iPhone" |
| Korean | ko | "서연의 MacBook Pro", "민준의 iPhone" |

Chat messages are also fully localized for natural-sounding conversations in each language.

## Troubleshooting

1. **xcodegen required**: Run `xcodegen generate` after adding new Swift files.

2. **Simulator names**: Update `Snapfile` if your available simulators differ.

3. **Build errors**: Ensure code signing is set up or use `CODE_SIGNING_REQUIRED=NO` for simulator builds.

4. **Scheme not found**: Ensure shared schemes exist in `PeerDrop.xcodeproj/xcshareddata/xcschemes/`.

## App Store Connect Upload

### Setup API Key

1. Go to [App Store Connect API Keys](https://appstoreconnect.apple.com/access/api)
2. Create a new key with "App Manager" role
3. Download the `.p8` file
4. Create `fastlane/AuthKey.json`:
   ```json
   {
     "key_id": "YOUR_KEY_ID",
     "issuer_id": "YOUR_ISSUER_ID",
     "key_filepath": "./AuthKey_YOUR_KEY_ID.p8"
   }
   ```
5. Update `fastlane/Appfile` with your team IDs

### Upload Screenshots

```bash
# Upload screenshots only
bundle exec fastlane upload_screenshots

# Capture and upload in one step
bundle exec fastlane screenshots_and_upload
```

### Available Lanes

| Lane | Description |
|------|-------------|
| `screenshots` | Capture screenshots locally |
| `upload_screenshots` | Upload screenshots to ASC |
| `screenshots_and_upload` | Capture and upload |
| `download_metadata` | Download existing metadata |
| `upload_metadata` | Upload metadata to ASC |
