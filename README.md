# PeerDrop

A peer-to-peer file transfer and communication app for iOS, enabling direct device-to-device connections without requiring internet access.

## Features

- **Device Discovery** - Automatically discover nearby devices using Bonjour/mDNS
- **P2P Connection** - Direct peer-to-peer connections via WebRTC
- **File Transfer** - Send files of any type between devices
- **Chat** - Real-time messaging with support for:
  - Text messages
  - Voice recordings
  - Media sharing (photos, videos)
  - Message reactions
  - Reply threads
  - Read receipts
- **Voice Calls** - High-quality voice calls over P2P connection
- **Device Library** - Save and organize frequently connected devices into groups
- **Transfer History** - Track all file transfers

## Requirements

- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

1. Clone the repository:
   ```bash
   git clone git@github.com:hanfour/peer-drop.git
   cd peer-drop
   ```

2. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```

3. Open the project:
   ```bash
   open PeerDrop.xcodeproj
   ```

4. Build and run on your device or simulator.

## Project Structure

```
PeerDrop/
├── App/                    # App entry point and configuration
├── Core/                   # Core functionality
│   ├── ConnectionManager   # P2P connection handling
│   ├── ChatManager         # Messaging functionality
│   ├── TransferManager     # File transfer logic
│   └── VoiceCallManager    # Voice call handling
├── UI/                     # SwiftUI views
│   ├── Discovery/          # Device discovery views
│   ├── Connection/         # Connection management views
│   ├── Chat/               # Chat interface
│   ├── Library/            # Device library views
│   ├── Transfer/           # File transfer views
│   └── Settings/           # App settings
└── Extensions/             # Swift extensions
```

## Screenshots

Screenshots are automatically captured using Fastlane. See [fastlane/README.md](fastlane/README.md) for details.

To capture screenshots:
```bash
xcodebuild test -scheme PeerDropUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:PeerDropUITests/SnapshotTests \
  CODE_SIGNING_REQUIRED=NO
```

## Testing

### Unit Tests
```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

### UI Tests
```bash
xcodebuild test -scheme PeerDropUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

### E2E Tests
The project includes comprehensive end-to-end tests for multi-device scenarios. See `PeerDropUITests/E2E/` for details.

## Dependencies

- [WebRTC](https://github.com/stasel/WebRTC) - Real-time communication

## License

This project is proprietary software. All rights reserved.

## Author

Han Four
