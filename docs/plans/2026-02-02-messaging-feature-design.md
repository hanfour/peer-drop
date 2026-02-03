# Messaging Feature Design

## Summary
Replace Clipboard button with Message in Connected tab. Add iMessage-style real-time chat between peers. Store messages in CoreData with optional iCloud sync.

## Protocol
- New `MessageType.textMessage` — payload: `{ "text": "...", "timestamp": "ISO8601" }`
- Sent via existing `ConnectionManager.sendMessage()` infrastructure

## Data Model (CoreData)
**Entity: ChatMessageEntity**
| Attribute | Type | Description |
|-----------|------|-------------|
| id | UUID | Primary key |
| text | String | Message content |
| timestamp | Date | Send time |
| isOutgoing | Bool | true = sent by me |
| peerID | String | Peer's senderID |
| peerName | String | Peer's display name |
| status | Int16 | 0=sending, 1=sent, 2=read |

## Storage
- Default: `NSPersistentContainer` (local only)
- iCloud: `NSPersistentCloudKitContainer` (auto-sync)
- User chooses in Settings via `@AppStorage("messageStorageMode")`

## UI Changes

### Connected Tab Buttons
Replace wide Label buttons with 3 circular icon buttons:
- Send File (`doc.fill`) — blue
- Message (`message.fill`) — orange
- Voice Call (`phone.fill`) — green

60pt circle background + white icon + small label below.

### ChatView (iMessage style)
- NavigationLink from Message button
- Bubbles: right-aligned blue (self), left-aligned gray (peer)
- Bottom: text input + send button with keyboard avoidance
- Time stamps grouped (>5 min gap)
- History persisted per peer via CoreData

### Settings
New "Message Storage" section: Local Only / Sync to iCloud picker.

## Files

### New
| File | Purpose |
|------|---------|
| `PeerDrop/Core/ChatManager.swift` | Send/receive + CoreData CRUD |
| `PeerDrop/Core/PeerDrop.xcdatamodeld` | CoreData model |
| `PeerDrop/UI/Chat/ChatView.swift` | Chat page |
| `PeerDrop/UI/Chat/ChatBubbleView.swift` | Bubble component |

### Modified
| File | Change |
|------|--------|
| `MessageType.swift` | Add `.textMessage` |
| `PeerMessage.swift` | Add `textMessage()` convenience |
| `ConnectionManager.swift` | Handle `.textMessage` in receive loop |
| `ConnectionView.swift` | Circular icon buttons, Message replaces Clipboard |
| `SettingsView.swift` | Add storage mode picker |
