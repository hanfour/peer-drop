# Round 3: Code Quality + Performance Design

## Goal
Improve observability (logging/error handling) and runtime performance (image caching, chat pagination, I/O debouncing) without architectural changes.

## Scope

### 1. Logger Consolidation
Replace all 39 `print()` statements with `os.Logger`.

- Each module gets its own Logger: `Logger(subsystem: "com.peerdrop", category: "<module>")`
- Categories: `transport`, `discovery`, `security`, `voice`, `chat`, `connection`
- Files already using Logger: remove duplicate `print()` calls
- Files without Logger: add `import os` + `private let logger`
- Mapping: `print("[prefix] debug")` → `logger.debug(...)`, errors → `logger.error(...)`
- ~12 files affected

### 2. try? Error Logging
Add error logging to 51+ silent `try?` blocks, prioritized in three tiers.

**P0 — Critical path** (must fix): File transfer, data persistence
- Convert to `do { try ... } catch { logger.error(...) }`
- Files: FileTransfer, FileTransferSession, ChatManager, ArchiveManager

**P1 — Important but non-fatal**: Media loading, thumbnail generation
- Convert to `do { try ... } catch { logger.warning(...) }`
- Files: ChatView, ChatBubbleView, ConnectionManager

**P2 — Acceptable silent failures**: `Task.sleep`, temp file cleanup
- Keep `try?` but add inline comment explaining why
- No code change needed, just documentation

~15 files affected.

### 3. Image Caching
New `ImageCache` class using `NSCache<NSString, UIImage>`.

- Limits: 50 images, 50 MB
- Key strategies:
  - Avatar: name hash
  - Chat thumbnail: message ID
  - Media preview: file path hash
- New file: `PeerDrop/Core/ImageCache.swift` (~40 lines)
- Modified files: PeerAvatar, ChatBubbleView, MediaPreviewView, UserProfileView

### 4. Chat Message Pagination
Load messages incrementally (50 at a time) instead of all at once.

- ChatManager: add `loadMessages(before:limit:)` method
- ChatView: detect scroll-to-top with `.onAppear`, load more
- Initial load: latest 50 messages
- ~30 lines of changes in ChatManager + ChatView

### 5. I/O Debouncing + URL+Zip Fix
**Debouncing**: ChatManager and DeviceRecordStore `save()` with 500ms debounce using `Task` cancellation pattern.

**URL+Zip**: Replace `DispatchSemaphore` with `withCheckedContinuation` for async/await compatibility.

Files: ChatManager, DeviceRecordStore, URL+Zip.swift

## Execution Order
1. Logger consolidation (foundation for all other debugging)
2. try? error logging (depends on Logger being in place)
3. Image caching (independent, new file)
4. Chat pagination (independent)
5. I/O debouncing + URL+Zip (independent)
6. Build verification

## Verification
- `xcodebuild build` — zero errors
- `xcodebuild test` — 219+ tests pass
- Grep confirms zero remaining `print()` in production code
- Grep confirms all P0 `try?` blocks converted to `do/catch`

## Future Rounds
- Round 4: Test coverage (Voice, Library, Archive) + architecture refactoring (ConnectionManager split)
