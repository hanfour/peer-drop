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

The `SnapshotTests` class captures 13 screenshots:

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

## Output

Screenshots are saved to `~/Library/Caches/tools.fastlane/` organized by device name:
- `iPhone 17 Pro Max-01_NearbyTab.png`
- `iPhone 17 Pro-01_NearbyTab.png`

## Localization

Mock data automatically adapts to the device's language setting:
- **English (en-US)**: Names like "Sarah's MacBook Pro", "James's iPhone"
- **Traditional Chinese (zh-Hant)**: Names like "小美的 MacBook Pro", "阿傑的 iPhone"

## Troubleshooting

1. **xcodegen required**: Run `xcodegen generate` after adding new Swift files.

2. **Simulator names**: Update `Snapfile` if your available simulators differ.

3. **Build errors**: Ensure code signing is set up or use `CODE_SIGNING_REQUIRED=NO` for simulator builds.

4. **Scheme not found**: Ensure shared schemes exist in `PeerDrop.xcodeproj/xcshareddata/xcschemes/`.
