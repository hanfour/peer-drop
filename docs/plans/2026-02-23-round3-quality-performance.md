# Round 3: Code Quality + Performance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve observability (Logger consolidation + try? error logging) and runtime performance (image caching, chat pagination, I/O debouncing) without architectural changes.

**Architecture:** Replace all `print()` with structured `os.Logger`, add error logging to silent `try?` blocks, introduce `NSCache`-based image caching, add chat message pagination, debounce frequent I/O writes, and migrate `DispatchSemaphore` to async/await.

**Tech Stack:** Swift, SwiftUI, os.Logger, NSCache, async/await

---

## Task 1: Logger Consolidation — Files Without Logger

Replace all `print()` statements with `os.Logger` in files that don't yet have a Logger.

**Files:**
- Modify: `PeerDrop/Voice/CallKitManager.swift` (lines 39, 76, 96)
- Modify: `PeerDrop/Voice/VoicePlayer.swift` (lines 39, 64)
- Modify: `PeerDrop/Security/CertificateManager.swift` (lines 44, 52, 59)
- Modify: `PeerDrop/Transport/FileTransfer.swift` (lines 250, 259, 269, 293, 307)
- Modify: `PeerDrop/Security/TLSConfiguration.swift` (line 13)
- Modify: `PeerDrop/Transport/MessageFramer.swift` (line 47)
- Modify: `PeerDrop/UI/Chat/ChatView.swift` (line 465)

**Step 1: Add Logger to CallKitManager.swift**

Add `import os` and Logger declaration at the top, then replace 3 print statements:

```swift
// Add after existing imports (line 3):
import os

// Add after class declaration:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "CallKitManager")

// Line 39: print("[CallKit] Failed to start call: \(error)")
// → logger.error("Failed to start call: \(error.localizedDescription)")

// Line 76: print("[CallKit] Failed to end call: \(error)")
// → logger.error("Failed to end call: \(error.localizedDescription)")

// Line 96: print("[CallKit] Audio session error: \(error)")
// → logger.error("Audio session error: \(error.localizedDescription)")
```

**Step 2: Add Logger to VoicePlayer.swift**

```swift
// Add import os after AVFoundation
import os

// Add after class/struct declaration:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "VoicePlayer")

// Line 39: print("[VoicePlayer] Failed to play: \(error)")
// → logger.error("Failed to play: \(error.localizedDescription)")

// Line 64: print("[VoicePlayer] Failed to play data: \(error)")
// → logger.error("Failed to play data: \(error.localizedDescription)")
```

**Step 3: Add Logger to CertificateManager.swift**

```swift
// Add import os
import os

// Add after class declaration:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "CertificateManager")

// Line 44: print("[CertificateManager] \(msg)")
// → logger.info("\(msg)")

// Line 52: print("[CertificateManager] \(msg)")
// → logger.warning("\(msg)")

// Line 59: print("[CertificateManager] \(msg)")
// → logger.error("\(msg)")
```

Note: Check the context of each print to determine the correct log level (info/warning/error). The three calls likely correspond to different severity levels based on the function they're in.

**Step 4: Add Logger to FileTransfer.swift**

```swift
// Add import os
import os

// Add at file level:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "FileTransfer")

// Line 250: print("[FileTransfer] File offer has no payload")
// → logger.error("File offer has no payload")

// Line 259: print("[FileTransfer] Failed to decode file offer metadata: \(error.localizedDescription)")
// → logger.error("Failed to decode file offer metadata: \(error.localizedDescription)")

// Line 269: print("[FileTransfer] Insufficient disk space: ...")
// → logger.error("Insufficient disk space: need \(metadata.fileSize) bytes, available \(availableBytes)")

// Line 293: print("[FileTransfer] Failed to create file handle for receiving: ...")
// → logger.error("Failed to create file handle: \(error.localizedDescription)")

// Line 307: print("[FileTransfer] Failed to send file accept: ...")
// → logger.error("Failed to send file accept: \(error.localizedDescription)")
```

**Step 5: Add Logger to TLSConfiguration.swift**

```swift
// Add import os
import os

// Add at file level:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "TLSConfiguration")

// Line 13: print("[TLSConfiguration] Failed to create sec_identity for server")
// → logger.error("Failed to create sec_identity for server")
```

**Step 6: Add Logger to MessageFramer.swift**

```swift
// Add import os
import os

// Add at file level:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "MessageFramer")

// Line 47: print("[PeerDropFramer] Rejecting message with invalid size: \(length) bytes")
// → logger.warning("Rejecting message with invalid size: \(length) bytes")
```

**Step 7: Add Logger to ChatView.swift**

```swift
// Add import os (after existing imports)
import os

// Add at file level:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "ChatView")

// Line 465: print("[ChatView] Failed to start recording: \(error)")
// → logger.error("Failed to start recording: \(error.localizedDescription)")
```

**Step 8: Verify — grep for remaining print() in production code**

Run: `grep -rn 'print(' PeerDrop/ --include='*.swift' | grep -v 'Tests/' | grep -v '#Preview'`

Expected: Only print() in files that already have Logger (handled in Task 2).

**Step 9: Commit**

```bash
git add PeerDrop/Voice/CallKitManager.swift PeerDrop/Voice/VoicePlayer.swift PeerDrop/Security/CertificateManager.swift PeerDrop/Transport/FileTransfer.swift PeerDrop/Security/TLSConfiguration.swift PeerDrop/Transport/MessageFramer.swift PeerDrop/UI/Chat/ChatView.swift
git commit -m "refactor: replace print() with os.Logger in 7 files"
```

---

## Task 2: Logger Consolidation — Files With Existing Logger

Replace remaining `print()` in files that already have `os.Logger`.

**Files:**
- Modify: `PeerDrop/Voice/VoiceCallManager.swift` (5 prints, Logger at line 6)
- Modify: `PeerDrop/Voice/VoiceCallSession.swift` (1 print, Logger at line 6)
- Modify: `PeerDrop/Discovery/BonjourDiscovery.swift` (3 prints, Logger at line 6)
- Modify: `PeerDrop/Connection/ConnectionManager.swift` (1 print, Logger at line 8)

**Step 1: Replace prints in VoiceCallManager.swift**

```swift
// Line 86: print("[VoiceCallManager] connectionManager is nil when creating signaling")
// → logger.error("connectionManager is nil when creating signaling")

// Line 199: print("[VoiceCallManager] Failed to report incoming call: \(error)")
// → logger.error("Failed to report incoming call: \(error.localizedDescription)")

// Line 258: print("[VoiceCallManager] Failed to create offer: \(error)")
// → logger.error("Failed to create offer: \(error.localizedDescription)")

// Line 329: print("[VoiceCallManager] Signaling error: \(error)")
// → logger.error("Signaling error: \(error.localizedDescription)")

// Line 383: print("[VoiceCallManager] Audio output error: \(error)")
// → logger.error("Audio output error: \(error.localizedDescription)")
```

**Step 2: Replace prints in VoiceCallSession.swift**

```swift
// Line 135: print("[VoiceCallSession] Audio output error: \(error)")
// → logger.error("Audio output error: \(error.localizedDescription)")
```

**Step 3: Replace prints in BonjourDiscovery.swift**

```swift
// Line 66: print("[BonjourDiscovery] Listener failed: \(error), restarting...")
// → logger.error("Listener failed: \(error.localizedDescription), restarting...")

// Line 86: print("[BonjourDiscovery] Failed to create listener: \(error)")
// → logger.error("Failed to create listener: \(error.localizedDescription)")

// Line 114: print("[BonjourDiscovery] Browser failed: \(error), restarting...")
// → logger.error("Browser failed: \(error.localizedDescription), restarting...")
```

**Step 4: Replace print in ConnectionManager.swift**

```swift
// Line 350: print("[ConnectionManager] Invalid transition: \(state) → \(newState)")
// → logger.warning("Invalid transition: \(String(describing: state)) → \(String(describing: newState))")
```

**Step 5: Verify — grep for zero remaining print() in production**

Run: `grep -rn 'print(' PeerDrop/ --include='*.swift' | grep -v 'Tests/' | grep -v '#Preview'`

Expected: Zero results (or only in test helpers / preview providers).

**Step 6: Commit**

```bash
git add PeerDrop/Voice/VoiceCallManager.swift PeerDrop/Voice/VoiceCallSession.swift PeerDrop/Discovery/BonjourDiscovery.swift PeerDrop/Connection/ConnectionManager.swift
git commit -m "refactor: replace remaining print() with logger in 4 files"
```

---

## Task 3: try? Error Logging — P0 Critical Path

Convert critical `try?` blocks to `do/catch` with `logger.error()` in file transfer and data persistence paths.

**Files:**
- Modify: `PeerDrop/Transport/FileTransfer.swift`
- Modify: `PeerDrop/Transport/FileTransferSession.swift`
- Modify: `PeerDrop/Core/ChatManager.swift` (needs Logger added first)

**Step 1: Add Logger to ChatManager.swift**

```swift
// Add at top:
import os

// Add inside class, after properties:
private let logger = Logger(subsystem: "com.peerdrop.app", category: "ChatManager")
```

**Step 2: Convert P0 try? in FileTransfer.swift**

Critical file operations that silently fail:

```swift
// Line 265: disk space check
// if let availableBytes = try? URL(fileURLWithPath: NSTemporaryDirectory())
// → do {
//     let availableBytes = try URL(fileURLWithPath: NSTemporaryDirectory())
//       .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
//       .volumeAvailableCapacityForImportantUsage
//   } catch {
//     logger.error("Failed to check disk space: \(error.localizedDescription)")
//   }

// Line 273: try? await connectionManager?.sendMessage(reject)
// → do { try await connectionManager?.sendMessage(reject) }
//   catch { logger.error("Failed to send rejection: \(error.localizedDescription)") }

// Line 387-388: file move operations
// try? FileManager.default.removeItem(at: destURL)
// try? FileManager.default.moveItem(at: tempURL, to: destURL)
// → do {
//     if FileManager.default.fileExists(atPath: destURL.path) {
//         try FileManager.default.removeItem(at: destURL)
//     }
//     try FileManager.default.moveItem(at: tempURL, to: destURL)
//   } catch {
//     logger.error("Failed to finalize file transfer: \(error.localizedDescription)")
//   }

// Line 391: try? destURL.unzipFile()
// → do { let unzippedURL = try destURL.unzipFile(); ... }
//   catch { logger.error("Failed to unzip: \(error.localizedDescription)") }
```

Keep as `try?` (P2 — temp file cleanup):
- Line 28, 340, 393, 409: `try? FileManager.default.removeItem(at: tempURL)` — add inline comment: `// P2: temp cleanup, failure is acceptable`

**Step 3: Convert P0 try? in FileTransferSession.swift**

Same pattern as FileTransfer.swift (these files mirror each other):

```swift
// Line 144: disk space check → do/catch with logger.error
// Line 152: try? await sendMessage?(reject) → do/catch with logger.error
// Line 257-258: file move → do/catch with logger.error
// Line 261: unzip → do/catch with logger.error
```

Keep as `try?` with comment:
- Lines 208, 263, 279: temp cleanup

**Step 4: Convert P0 try? in ChatManager.swift — appendMessage**

```swift
// Lines 384-398: appendMessage method
// Convert the chain of try? to proper error handling:
private func appendMessage(_ message: ChatMessage, peerID: String) {
    let file = messagesFile(for: peerID)
    let dir = file.deletingLastPathComponent()
    do {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        logger.error("Failed to create chat directory: \(error.localizedDescription)")
    }
    var existing: [ChatMessage] = []
    do {
        let raw = try Data(contentsOf: file)
        let decrypted = try encryptor.decrypt(raw)
        existing = try JSONDecoder().decode([ChatMessage].self, from: decrypted)
    } catch {
        // File doesn't exist yet or is corrupted — start fresh
        logger.debug("Loading existing messages: \(error.localizedDescription)")
    }
    existing.append(message)
    do {
        let encoded = try JSONEncoder().encode(existing)
        try encryptor.encryptAndWrite(encoded, to: file)
    } catch {
        logger.error("Failed to persist message: \(error.localizedDescription)")
    }
    messages.append(message)
}
```

**Step 5: Convert P0 try? in ChatManager.swift — deleteMessages**

```swift
// Lines 126-128: deleteMessages
// try? fileManager.removeItem(at: file)
// try? fileManager.removeItem(at: mediaDir)
// → do { try fileManager.removeItem(at: file) }
//   catch { logger.warning("Failed to delete messages file: \(error.localizedDescription)") }
//   do { try fileManager.removeItem(at: mediaDir) }
//   catch { logger.warning("Failed to delete media directory: \(error.localizedDescription)") }
```

**Step 6: Build verification**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add PeerDrop/Transport/FileTransfer.swift PeerDrop/Transport/FileTransferSession.swift PeerDrop/Core/ChatManager.swift
git commit -m "fix: add error logging to P0 try? blocks in file transfer and chat persistence"
```

---

## Task 4: try? Error Logging — P1 Important Non-Fatal

Add warning-level logging to media loading and message decoding `try?` blocks.

**Files:**
- Modify: `PeerDrop/Connection/ConnectionManager.swift`
- Modify: `PeerDrop/Core/ChatManager.swift`

**Step 1: Convert P1 try? in ConnectionManager.swift — message decoding**

These are message payload decoding try? blocks. They are non-fatal (message is just ignored if unparseable) but should log warnings for debugging:

```swift
// Pattern for all payload decoding (lines 1504, 1531, 1542, 1563, 1568, 1615, 1738, 1759, 1780, 1819, 1840, 1845):
// if let payload = try? message.decodePayload(TextMessagePayload.self) {
// → guard let payload = try? message.decodePayload(TextMessagePayload.self) else {
//     logger.warning("Failed to decode TextMessagePayload")
//     return
//   }

// For rejection reason decoding (lines 1454, 1486, 1578, 1696, 1720):
// let reason = (try? message.decodePayload(RejectionPayload.self))?.reason
// These are fine as try? since reason is optional — add comment:
// // P1: rejection reason is optional, nil is acceptable

// For PeerMessage factory calls (lines 1904, 1922, 1945, 1969, 2006, 2036, 2060, 2079, 2170):
// guard let msg = try? PeerMessage.textMessage(payload, senderID: ...)
// → keep try? but add else clause logging:
// guard let msg = try? PeerMessage.textMessage(payload, senderID: localIdentity.id) else {
//     logger.warning("Failed to create PeerMessage for text")
//     return
//   }
```

Note: Be selective — only add logging where it aids debugging without creating noise. The `guard/else` pattern is cleanest.

**Step 2: Convert P1 try? in ConnectionManager.swift — transfer history**

```swift
// Line 2243: let decoded = try? JSONDecoder().decode([TransferRecord].self, from: data)
// → do { let decoded = try JSONDecoder().decode(...) }
//   catch { logger.warning("Failed to decode transfer history: \(error.localizedDescription)") }

// Line 2248: guard let data = try? JSONEncoder().encode(transferHistory)
// → do { let data = try JSONEncoder().encode(transferHistory); ... }
//   catch { logger.warning("Failed to encode transfer history: \(error.localizedDescription)") }
```

**Step 3: Convert P1 try? in ChatManager.swift — unread counts + migration**

```swift
// Line 373: let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
// → guard let decoded = try? ... else {
//     logger.warning("Failed to decode unread counts")
//     return
//   }

// Line 378: guard let data = try? JSONEncoder().encode(unreadCounts)
// → do { let data = try JSONEncoder().encode(unreadCounts); ... }
//   catch { logger.warning("Failed to save unread counts: \(error.localizedDescription)") }

// Same for group unread (lines 491, 496)
```

Keep as P2 (add comments only):
- `try? Task.sleep` lines (268, etc.) — add `// P2: sleep interruption is acceptable`
- `try? fileManager.removeItem(at: file)` for temp cleanup — add `// P2: cleanup failure is acceptable`

**Step 4: Build verification**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add PeerDrop/Connection/ConnectionManager.swift PeerDrop/Core/ChatManager.swift
git commit -m "fix: add warning logging to P1 try? blocks in message decoding and persistence"
```

---

## Task 5: Image Caching

Create an `ImageCache` class using `NSCache` and integrate it into views that load images.

**Files:**
- Create: `PeerDrop/Core/ImageCache.swift`
- Modify: `PeerDrop/UI/Chat/ChatBubbleView.swift`

**Step 1: Create ImageCache.swift**

```swift
import UIKit
import os

private let logger = Logger(subsystem: "com.peerdrop.app", category: "ImageCache")

final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        let cost = image.jpegData(compressionQuality: 1.0)?.count ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
        logger.debug("Image cache cleared")
    }
}
```

**Step 2: Integrate ImageCache into ChatBubbleView.swift**

Modify the image loading section (around lines 261-280) to check cache first:

```swift
// Before creating UIImage from thumbnailData or mediaData:
// 1. Check cache using message.id as key
// 2. If cache miss, create UIImage and store in cache
// 3. Display cached image

// Example pattern:
let cacheKey = message.id.uuidString
if let cached = ImageCache.shared.image(forKey: cacheKey) {
    Image(uiImage: cached)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 220, maxHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
} else if let thumbData = message.thumbnailData, let uiImage = UIImage(data: thumbData) {
    ImageCache.shared.setImage(uiImage, forKey: cacheKey)
    Image(uiImage: uiImage)
        // ... same modifiers
} else if let localPath = message.localFileURL,
          let chatManager,
          let mediaData = chatManager.loadMediaData(relativePath: localPath),
          let uiImage = UIImage(data: mediaData) {
    ImageCache.shared.setImage(uiImage, forKey: cacheKey)
    Image(uiImage: uiImage)
        // ... same modifiers
} else {
    // fallback label
}
```

Note: PeerAvatar uses text-based rendering (initials + color hash), not image loading — no caching needed there.

**Step 3: Add ImageCache.swift to Xcode project**

The file needs to be registered in the Xcode project. Since the project uses a flat structure, placing it in `PeerDrop/Core/` should be picked up automatically if using "folder references." If not, manually add to `project.pbxproj`.

**Step 4: Build verification**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add PeerDrop/Core/ImageCache.swift PeerDrop/UI/Chat/ChatBubbleView.swift PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat: add NSCache-based image caching for chat thumbnails"
```

---

## Task 6: Chat Message Pagination

Load messages incrementally (50 at a time) instead of all at once.

**Files:**
- Modify: `PeerDrop/Core/ChatManager.swift`
- Modify: `PeerDrop/UI/Chat/ChatView.swift`

**Step 1: Add pagination support to ChatManager**

Add a `loadMessages(forPeer:before:limit:)` method and modify the existing `loadMessages(forPeer:)`:

```swift
// Add property:
private var allMessagesForCurrentPeer: [ChatMessage] = []
private let pageSize = 50
var hasMoreMessages: Bool { messages.count < allMessagesForCurrentPeer.count }

// Modify loadMessages(forPeer:) to load all but only show last 50:
func loadMessages(forPeer peerID: String) {
    // Screenshot mode check stays the same
    if ScreenshotModeProvider.shared.isActive && ScreenshotModeProvider.isMockPeer(peerID) {
        messages = ScreenshotModeProvider.shared.mockChatMessages
        allMessagesForCurrentPeer = messages
        return
    }

    let file = messagesFile(for: peerID)
    guard fileManager.fileExists(atPath: file.path) else {
        messages = []
        allMessagesForCurrentPeer = []
        markAsRead(peerID: peerID)
        return
    }
    do {
        let raw = try Data(contentsOf: file)
        let data = try encryptor.decrypt(raw)
        allMessagesForCurrentPeer = try JSONDecoder().decode([ChatMessage].self, from: data)
    } catch {
        allMessagesForCurrentPeer = []
        logger.warning("Failed to load messages: \(error.localizedDescription)")
    }
    // Show last pageSize messages
    messages = Array(allMessagesForCurrentPeer.suffix(pageSize))
    markAsRead(peerID: peerID)
}

// Add new method:
func loadMoreMessages() {
    let currentCount = messages.count
    guard currentCount < allMessagesForCurrentPeer.count else { return }
    let startIndex = max(0, allMessagesForCurrentPeer.count - currentCount - pageSize)
    let endIndex = allMessagesForCurrentPeer.count - currentCount
    let olderMessages = Array(allMessagesForCurrentPeer[startIndex..<endIndex])
    messages.insert(contentsOf: olderMessages, at: 0)
}
```

**Step 2: Add scroll-to-top detection in ChatView**

Add a "Load More" indicator at the top of the message list:

```swift
// Inside the ScrollView's LazyVStack, before ForEach:
if chatManager.hasMoreMessages {
    Button("Load earlier messages") {
        chatManager.loadMoreMessages()
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
}
```

**Step 3: Build verification**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add PeerDrop/Core/ChatManager.swift PeerDrop/UI/Chat/ChatView.swift
git commit -m "feat: add chat message pagination (50 messages per page)"
```

---

## Task 7: I/O Debouncing

Debounce `save()` calls in `ChatManager` and `DeviceRecordStore` with 500ms delay using Task cancellation pattern.

**Files:**
- Modify: `PeerDrop/Core/ChatManager.swift`
- Modify: `PeerDrop/Core/DeviceRecordStore.swift`

**Step 1: Add debounced save to DeviceRecordStore**

```swift
// Add property:
private var saveTask: Task<Void, Never>?

// Replace save() implementation:
func save() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
        do {
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
        } catch {
            return // Task cancelled
        }
        guard let self else { return }
        guard let data = try? JSONEncoder().encode(self.records) else { return }
        UserDefaults.standard.set(data, forKey: self.key)
    }
}

// Add immediate save for when the app goes to background:
func saveImmediately() {
    saveTask?.cancel()
    guard let data = try? JSONEncoder().encode(records) else { return }
    UserDefaults.standard.set(data, forKey: key)
}
```

**Step 2: Add debounced persistence to ChatManager appendMessage**

The `appendMessage` method writes to disk on every message. Add debouncing:

```swift
// Add property:
private var persistTasks: [String: Task<Void, Never>] = [:]

// In appendMessage, replace the immediate write with debounced write:
// messages.append(message) stays immediate (in-memory)
// File write is debounced:
private func schedulePersist(peerID: String) {
    persistTasks[peerID]?.cancel()
    persistTasks[peerID] = Task { [weak self] in
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            return
        }
        guard let self else { return }
        self.persistMessages(peerID: peerID)
    }
}

private func persistMessages(peerID: String) {
    let file = messagesFile(for: peerID)
    let dir = file.deletingLastPathComponent()
    do {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        logger.error("Failed to create chat directory: \(error.localizedDescription)")
    }
    // Write current allMessagesForCurrentPeer + any appended messages
    do {
        let encoded = try JSONEncoder().encode(allMessagesForCurrentPeer)
        try encryptor.encryptAndWrite(encoded, to: file)
    } catch {
        logger.error("Failed to persist messages: \(error.localizedDescription)")
    }
}
```

Note: Carefully integrate with the pagination changes from Task 6. The `appendMessage` should add to both `messages` (display) and `allMessagesForCurrentPeer` (full list), then schedule debounced persist.

**Step 3: Build verification**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add PeerDrop/Core/DeviceRecordStore.swift PeerDrop/Core/ChatManager.swift
git commit -m "perf: debounce save() with 500ms delay in DeviceRecordStore and ChatManager"
```

---

## Task 8: URL+Zip Async Migration

Replace `DispatchSemaphore` in `URL+Zip.swift` with `withCheckedThrowingContinuation` for async/await compatibility.

**Files:**
- Modify: `PeerDrop/Extensions/URL+Zip.swift`

**Step 1: Convert zipDirectory() to async**

```swift
func zipDirectory() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
        let coordinator = NSFileCoordinator()
        let intent = NSFileAccessIntent.readingIntent(with: self, options: .forUploading)

        coordinator.coordinate(with: [intent], queue: OperationQueue()) { err in
            if let err = err {
                continuation.resume(throwing: err)
                return
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(self.lastPathComponent + ".zip")

            try? FileManager.default.removeItem(at: tempURL)

            do {
                try FileManager.default.copyItem(at: intent.url, to: tempURL)
                continuation.resume(returning: tempURL)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

**Step 2: Update callers of zipDirectory()**

Search for all call sites and add `await`:

Run: `grep -rn 'zipDirectory()' PeerDrop/ --include='*.swift'`

Update each caller to use `await try zipDirectory()` instead of `try zipDirectory()`.

**Step 3: Build verification**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add PeerDrop/Extensions/URL+Zip.swift
# Also add any modified callers
git commit -m "refactor: replace DispatchSemaphore with async/await in URL+Zip"
```

---

## Task 9: Final Build + Test Verification

**Step 1: Full build**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: BUILD SUCCEEDED

**Step 2: Run tests**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16' -quiet`

Expected: 219+ tests pass, 0 failures

**Step 3: Verify zero remaining print()**

Run: `grep -rn 'print(' PeerDrop/ --include='*.swift' | grep -v 'Tests/' | grep -v '#Preview'`

Expected: Zero results

**Step 4: Verify P0 try? converted**

Run: `grep -rn 'try?' PeerDrop/Transport/FileTransfer.swift PeerDrop/Transport/FileTransferSession.swift`

Expected: Only P2 temp cleanup try? remaining (with comments)

**Step 5: Merge commit**

```bash
git add -A
git commit -m "Round 3 complete: Logger consolidation, error logging, image cache, pagination, debouncing"
```

---

## Execution Summary

| Task | Description | Files | Est. Changes |
|------|-------------|-------|-------------|
| 1 | Logger — new files | 7 files | ~30 lines |
| 2 | Logger — existing files | 4 files | ~15 lines |
| 3 | try? P0 — critical path | 3 files | ~60 lines |
| 4 | try? P1 — important | 2 files | ~40 lines |
| 5 | Image caching | 2 files (1 new) | ~40 lines |
| 6 | Chat pagination | 2 files | ~30 lines |
| 7 | I/O debouncing | 2 files | ~30 lines |
| 8 | URL+Zip async | 1+ files | ~20 lines |
| 9 | Build + test verification | — | — |

**Total: ~265 lines across ~15 files**

## Future Rounds
- Round 4: Test coverage (Voice, Library, Archive) + architecture refactoring (ConnectionManager split)
