# PeerDrop Code Signing & App Store Submission Guide

This guide walks through setting up code signing for PeerDrop and submitting the app to the App Store.

**App details:**

| Field | Value |
|---|---|
| Bundle ID | `com.peerdrop.app` |
| Version | 1.0.0 (build 1) |
| Deployment target | iOS 16.0 |
| Apple ID | `hanfour.huang@icloud.com` |

---

## 1. Prerequisites

Before you begin, make sure the following are in place:

- **Apple Developer Program membership** ($99/year). Enroll at [developer.apple.com/programs](https://developer.apple.com/programs/).
- **Xcode** installed from the Mac App Store (version 15.0 or later, matching `project.yml`).
- **XcodeGen** installed (`brew install xcodegen`) to generate the Xcode project from `project.yml`.
- **Fastlane** installed (`brew install fastlane` or `gem install fastlane`) for automated uploads.

Generate the Xcode project before proceeding:

```bash
cd /path/to/peer-drop
xcodegen generate
```

---

## 2. App Store Connect Setup

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com/).
2. Go to **My Apps** and click the **+** button, then select **New App**.
3. Fill in the required fields:
   - **Platform:** iOS
   - **Name:** PeerDrop
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** Select `com.peerdrop.app` (it must already be registered in the Developer portal -- see step 2a below).
   - **SKU:** `com.peerdrop.app` (or any unique identifier you prefer)
   - **User Access:** Full Access
4. Click **Create**.

### 2a. Register the Bundle ID (if not already done)

1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list).
2. Click the **+** button next to **Identifiers**.
3. Select **App IDs**, then **App**.
4. Enter:
   - **Description:** PeerDrop
   - **Bundle ID:** Explicit -- `com.peerdrop.app`
5. Under **Capabilities**, enable:
   - **Background Modes**
6. Click **Continue**, then **Register**.

---

## 3. Xcode Signing Configuration

1. Open the generated `PeerDrop.xcodeproj` in Xcode.
2. In the project navigator, select the **PeerDrop** project.
3. Select the **PeerDrop** target.
4. Go to the **Signing & Capabilities** tab.
5. Check **Automatically manage signing**.
6. Under **Team**, select your Apple Developer team from the dropdown.
7. Xcode will automatically:
   - Create an App ID if needed.
   - Generate development and distribution provisioning profiles.
   - Download and install the signing certificate.

If you see a signing error, ensure your Apple Developer Program membership is active and your Apple ID is added in **Xcode > Settings > Accounts**.

### Verify signing settings in project.yml

The bundle identifier is already configured in `project.yml`:

```yaml
targets:
  PeerDrop:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.peerdrop.app
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
```

If you need to set the team ID explicitly (for CI or headless builds), add:

```yaml
targets:
  PeerDrop:
    settings:
      base:
        DEVELOPMENT_TEAM: "YOUR_TEAM_ID"
```

---

## 4. Required Capabilities

PeerDrop declares the following capabilities in `PeerDrop/App/Info.plist` and `project.yml`. Ensure these are enabled in Xcode under **Signing & Capabilities**.

### Background Modes

Declared in Info.plist under `UIBackgroundModes`:

- **Audio** -- keeps audio sessions alive during voice calls.
- **Voice over IP (VoIP)** -- enables incoming call notifications while backgrounded.

In Xcode: click **+ Capability**, add **Background Modes**, and check **Audio, AirPlay, and Picture in Picture** and **Voice over IP**.

### Bonjour Services

Declared in Info.plist under `NSBonjourServices`:

- `_peerdrop._tcp` -- used for local peer discovery via Multipeer Connectivity / Network framework.

In Xcode: under **Signing & Capabilities**, add **Bonjour** capability (if not auto-added) and ensure `_peerdrop._tcp` is listed.

### Privacy Usage Descriptions

These are already set in `Info.plist` and `project.yml`. Apple requires these strings to explain why the app needs each permission. They appear in the system permission dialogs.

| Key | Description |
|---|---|
| `NSLocalNetworkUsageDescription` | PeerDrop uses the local network to discover and connect to nearby devices for file transfer and voice calls. |
| `NSMicrophoneUsageDescription` | PeerDrop needs microphone access for voice calls. |
| `NSCameraUsageDescription` | PeerDrop needs camera access to capture photos for sharing in chats. |
| `NSPhotoLibraryUsageDescription` | PeerDrop needs photo library access to share photos and videos in chats. |

---

## 5. Archive & Upload

### Option A: Xcode (Manual)

1. In Xcode, select **Any iOS Device (arm64)** as the build destination (not a simulator).
2. Go to **Product > Archive**.
3. Wait for the archive to build. When complete, the **Organizer** window opens automatically.
4. Select the newly created archive.
5. Click **Distribute App**.
6. Select **App Store Connect** as the distribution method.
7. Choose **Upload** (to send directly to App Store Connect).
8. Select your distribution certificate and provisioning profile (or let Xcode manage them automatically).
9. Click **Upload**.

After upload completes, the build appears in App Store Connect under **TestFlight** and **App Store** tabs (once processing finishes, typically within 15-30 minutes).

### Option B: Fastlane (Automated)

The project already has Fastlane configured. To upload a binary:

```bash
# Build and archive
xcodebuild archive \
  -project PeerDrop.xcodeproj \
  -scheme PeerDrop \
  -configuration Release \
  -archivePath build/PeerDrop.xcarchive \
  -destination "generic/platform=iOS"

# Export the IPA
xcodebuild -exportArchive \
  -archivePath build/PeerDrop.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist

# Upload metadata and screenshots (skip binary)
fastlane upload_metadata
fastlane upload_screenshots

# Upload binary using deliver
fastlane deliver --ipa build/export/PeerDrop.ipa --skip_metadata --skip_screenshots
```

Or use `fastlane deliver` to upload everything (binary, metadata, and screenshots) at once:

```bash
fastlane deliver --ipa build/export/PeerDrop.ipa
```

### Existing Fastlane Lanes

The project's `fastlane/Fastfile` already defines these lanes:

| Lane | Command | Purpose |
|---|---|---|
| `screenshots` | `fastlane screenshots` | Capture App Store screenshots via UI tests |
| `upload_screenshots` | `fastlane upload_screenshots` | Upload screenshots to App Store Connect |
| `screenshots_and_upload` | `fastlane screenshots_and_upload` | Capture and upload in one step |
| `add_frames` | `fastlane add_frames` | Add device frames/titles to screenshots |
| `upload_metadata` | `fastlane upload_metadata` | Upload metadata to App Store Connect |

---

## 6. Fastlane API Key Setup (Optional)

Using an App Store Connect API key is recommended over Apple ID authentication, especially for CI/CD environments. It avoids 2FA prompts and session expiration issues.

### Generate the API Key

1. Go to [App Store Connect > Users and Access > Integrations > App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **Generate API Key** (or the **+** button).
3. Enter a name (e.g., "PeerDrop CI") and select the **App Manager** role.
4. Click **Generate**.
5. Download the `.p8` private key file. **Save it securely -- you can only download it once.**
6. Note the **Key ID** and **Issuer ID** displayed on the page.

### Configure in Fastlane

Create a JSON key file at `fastlane/AuthKey.json`:

```json
{
  "key_id": "YOUR_KEY_ID",
  "issuer_id": "YOUR_ISSUER_ID",
  "key": "-----BEGIN PRIVATE KEY-----\nYOUR_P8_KEY_CONTENT_HERE\n-----END PRIVATE KEY-----",
  "in_house": false
}
```

Then uncomment the relevant line in `fastlane/Appfile`:

```ruby
app_store_connect_api_key_path("./fastlane/AuthKey.json")
```

Alternatively, set environment variables (useful for CI):

```bash
export APP_STORE_CONNECT_API_KEY_ID="YOUR_KEY_ID"
export APP_STORE_CONNECT_API_ISSUER_ID="YOUR_ISSUER_ID"
export APP_STORE_CONNECT_API_KEY="$(cat /path/to/AuthKey_XXXXXX.p8 | base64)"
```

**Important:** Never commit the `.p8` key or `AuthKey.json` to version control. Add them to `.gitignore`.

---

## 7. Pre-Submission Checklist

Before submitting for App Review, verify the following:

### Screenshots

- [ ] Screenshots uploaded for all required device sizes (iPhone 6.9", iPhone 6.7", iPad 13").
- [ ] Screenshots provided for all 5 localized languages (en-US, zh-Hant, zh-Hans, ja, ko).
- [ ] The project already has 72+ screenshots in `fastlane/screenshots/` across all locales and device types.
- [ ] Upload via: `fastlane upload_screenshots`

### Metadata

- [ ] App name, subtitle, description, and keywords are complete for all 5 languages.
- [ ] Metadata files are in `fastlane/metadata/` with per-locale directories.
- [ ] Upload via: `fastlane upload_metadata`

### Privacy

- [ ] Privacy policy URL is set: `https://hanfour.github.io/peer-drop/privacy-policy.html`
- [ ] Privacy policy is also available locally at `docs/privacy-policy.html`.
- [ ] App Privacy (data collection declarations) completed in App Store Connect under **App Privacy**.
  - Declare data types collected (if any): local network usage, microphone audio (not stored), camera (not stored), photo library access.

### App Review Information

- [ ] Contact information filled in (first name, last name, phone, email).
- [ ] Demo account credentials provided (if the app requires login -- PeerDrop does not).
- [ ] Notes for reviewer explaining that the app requires two devices on the same local network to demonstrate peer-to-peer functionality.

### Build & Version

- [ ] Version number is `1.0.0` (`MARKETING_VERSION` in `project.yml`).
- [ ] Build number is `1` (`CURRENT_PROJECT_VERSION` in `project.yml`).
- [ ] App category is set to **Social Networking** (configured in `fastlane/metadata/primary_category.txt`).

### Final Steps

1. In App Store Connect, select the uploaded build under **App Store > iOS App > Build**.
2. Fill in all required fields on the **App Information**, **Pricing and Availability**, and **App Review** pages.
3. Click **Add for Review**.
4. Click **Submit to App Review**.

Review typically takes 24-48 hours. You will receive an email notification when the review is complete.
