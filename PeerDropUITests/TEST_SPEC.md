# PeerDrop Comprehensive Test Specification

> **Single source of truth** for all functional test scenarios.
> Update this document with every feature change.

## Simulator Configuration

| Role | Device | UUID |
|------|--------|------|
| Sim1 (Initiator) | iPhone 17 Pro | `080C1B81-FD68-4ED7-8CE3-A3F40559211D` |
| Sim2 (Acceptor) | iPhone 17 Pro Max | `DA3E4A31-66A4-41AA-89A6-99A85679ED26` |

## Run Instructions

```bash
SIM1="080C1B81-FD68-4ED7-8CE3-A3F40559211D"
SIM2="DA3E4A31-66A4-41AA-89A6-99A85679ED26"
PROJECT="/Users/hanfourmini/Projects/applications/peer-drop/PeerDrop.xcodeproj"
DERIVED="/Users/hanfourmini/Library/Developer/Xcode/DerivedData/PeerDrop-bmoowreufjcrbncwgxryqpcaaaqh"

# Build once:
xcodebuild -project $PROJECT -scheme PeerDrop build-for-testing \
  -destination "id=$SIM1" -derivedDataPath $DERIVED

# Full suite (both in parallel):
xcodebuild test-without-building -project $PROJECT -scheme PeerDrop \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests' \
  -destination "id=$SIM1" -derivedDataPath $DERIVED &
xcodebuild test-without-building -project $PROJECT -scheme PeerDrop \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests' \
  -destination "id=$SIM2" -derivedDataPath $DERIVED

# Smoke test (8 core scenarios):
xcodebuild test-without-building -project $PROJECT -scheme PeerDrop \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_DISC01_BonjourDiscovery' \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_CONN01_FullConnectionFlow' \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_CONN02_ConnectionRejection' \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_CHAT01_TextRoundTrip' \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_CONN06_Reconnect' \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_FEAT01_AllDisabled' \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_UI01_TabNavigation' \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_SET01_SettingsUI' \
  -destination "id=$SIM1" -derivedDataPath $DERIVED &
xcodebuild test-without-building -project $PROJECT -scheme PeerDrop \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_DISC01_BonjourDiscovery' \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_CONN01_FullConnectionFlow' \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_CONN02_ConnectionRejection' \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_CHAT01_TextRoundTrip' \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_CONN06_Reconnect' \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_FEAT01_AllDisabled' \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_UI05_StatusToast' \
  -destination "id=$SIM2" -derivedDataPath $DERIVED

# Single test pair:
xcodebuild test-without-building -project $PROJECT -scheme PeerDrop \
  -only-testing:'PeerDropUITests/ComprehensiveInitiatorTests/testA_CONN03_RequestTimeout' \
  -destination "id=$SIM1" -derivedDataPath $DERIVED &
xcodebuild test-without-building -project $PROJECT -scheme PeerDrop \
  -only-testing:'PeerDropUITests/ComprehensiveAcceptorTests/testB_CONN03_ConsentAutoDismiss' \
  -destination "id=$SIM2" -derivedDataPath $DERIVED
```

---

## Smoke Test Subset (8 tests)

Quick regression check covering the critical path:

| # | ID | Description |
|---|-----|-------------|
| 1 | DISC-01 | Bonjour peer discovery |
| 2 | CONN-01 | Full connection flow |
| 3 | CONN-02 | Connection rejection |
| 4 | CHAT-01 | Text round trip |
| 5 | CONN-06 | Reconnect after disconnect |
| 6 | FEAT-01 | All features disabled alerts |
| 7 | UI-01 | Tab navigation |
| 8 | SET-01 | Settings UI sections |

---

## Test Scenarios (47 total)

### Summary

| Category | ID Prefix | Total | Dual | Single | Positive | Negative |
|----------|-----------|-------|------|--------|----------|----------|
| Discovery | DISC | 5 | 2 | 3 | 4 | 1 |
| Connection | CONN | 8 | 8 | 0 | 6 | 2 |
| Chat | CHAT | 7 | 5 | 2 | 5 | 2 |
| File Transfer | FILE | 5 | 3 | 2 | 3 | 2 |
| Voice Call | VOICE | 4 | 3 | 1 | 3 | 1 |
| Feature Toggle | FEAT | 5 | 4 | 1 | 2 | 3 |
| Settings | SET | 4 | 1 | 3 | 4 | 0 |
| Library | LIB | 4 | 2 | 2 | 3 | 1 |
| UI | UI | 5 | 3 | 2 | 5 | 0 |
| **Total** | | **47** | **31** | **16** | **35** | **12** |

---

### Discovery (DISC)

#### DISC-01: Bonjour Discovery
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_DISC01_BonjourDiscovery`
- **Acceptor:** `testB_DISC01_BonjourDiscovery`
- **Preconditions:** Both sims online, PeerDrop running
- **Steps:**
  1. Launch both apps
  2. Ensure both are online
  3. Wait for peer to appear in Nearby tab
- **Expected:** Both sims see each other in the Nearby tab within 30s
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario1` (partial)

#### DISC-02: Manual Connect
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_DISC02_ManualConnect`
- **Preconditions:** App online
- **Steps:**
  1. Tap "Quick Connect" button
  2. Verify IP/port input fields appear
  3. Cancel
- **Expected:** Manual connect form opens with input fields
- **Existing Coverage:** None

#### DISC-03: Online/Offline Toggle
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_DISC03_OnlineOfflineToggle`
- **Acceptor:** `testB_DISC03_OnlineOfflineToggle`
- **Preconditions:** Both sims online, peer visible
- **Steps:**
  1. Initiator goes offline
  2. Acceptor checks peer disappears
  3. Initiator goes back online
  4. Acceptor checks peer reappears
- **Expected:** Peer visibility tracks online/offline state
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario4`, `FullFeatureVerificationTests/test01`

#### DISC-04: Invalid Manual Connect
- **Type:** Single | **Polarity:** Negative
- **Initiator:** `testA_DISC04_InvalidManualConnect`
- **Preconditions:** App online
- **Steps:**
  1. Open Quick Connect
  2. Enter invalid IP `999.999.999.999`
  3. Tap Connect
- **Expected:** Graceful error, no crash
- **Existing Coverage:** None

#### DISC-05: Grid/List Toggle
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_DISC05_GridListToggle`
- **Preconditions:** App online
- **Steps:**
  1. Check for view mode toggle
  2. Switch between grid and list view
  3. Toggle back
- **Expected:** View mode switches without crash
- **Existing Coverage:** None

---

### Connection (CONN)

#### CONN-01: Full Connection Flow
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CONN01_FullConnectionFlow`
- **Acceptor:** `testB_CONN01_FullConnectionFlow`
- **Preconditions:** Both online, peer visible
- **Steps:**
  1. Initiator taps peer
  2. Acceptor sees consent sheet with "wants to connect"
  3. Acceptor taps Accept
  4. Both transition to Connected tab
  5. Initiator verifies 3 action icons (Send File, Chat, Voice Call)
- **Expected:** Connected state with all 3 feature buttons visible
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario1` (partial)

#### CONN-02: Connection Rejection + Recovery
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_CONN02_ConnectionRejection`
- **Acceptor:** `testB_CONN02_ConnectionRejection`
- **Preconditions:** Both online, peer visible
- **Steps:**
  1. Initiator taps peer → connection request sent
  2. Acceptor taps Decline
  3. Initiator sees "Connection Error" alert with "declined" message
  4. Acceptor does NOT see any error alert (shows toast "Connection declined" instead)
  5. Initiator taps "Back to Discovery", rediscovers peer
  6. Initiator sends second connection request
  7. Acceptor receives and accepts second request
  8. Both devices connect successfully
- **Expected:** Rejection only shows alert on initiator side; both devices recover and can reconnect
- **Bug Fixed:** Acceptor previously showed "Connection Error" alert after declining (wrong `.rejected` state) and `activeConnection` was not cleared, blocking all future incoming connections
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario2` (partial, did not verify recovery)

#### CONN-03: Request Timeout
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_CONN03_RequestTimeout`
- **Acceptor:** `testB_CONN03_ConsentAutoDismiss`
- **Preconditions:** Both online, peer visible
- **Steps:**
  1. Initiator taps peer
  2. Acceptor does NOT accept (waits)
  3. After 15s, initiator sees "Connection Error" with "timed out"
  4. Acceptor consent sheet auto-dismisses
- **Expected:** Timeout error on initiator, auto-dismiss on acceptor
- **Existing Coverage:** `TimeoutInitiatorTests/testA4`, `TimeoutAcceptorTests/testB4`

#### CONN-04: Consent Fingerprint
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CONN04_ConsentFingerprint`
- **Acceptor:** `testB_CONN04_ConsentFingerprint`
- **Preconditions:** Both online, peer visible
- **Steps:**
  1. Initiator taps peer
  2. Acceptor checks consent sheet for "Certificate Fingerprint" label
  3. Acceptor accepts
- **Expected:** Fingerprint displayed in consent sheet
- **Existing Coverage:** None

#### CONN-05: Disconnect Flow
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CONN05_DisconnectFlow`
- **Acceptor:** `testB_CONN05_DisconnectFlow`
- **Preconditions:** Connected
- **Steps:**
  1. Initiator taps Disconnect button
  2. DisconnectSheet appears with confirmation
  3. Initiator confirms disconnect
- **Expected:** Clean disconnect, both return to discovery state
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario1` (partial)

#### CONN-06: Reconnect
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CONN06_Reconnect`
- **Acceptor:** `testB_CONN06_Reconnect`
- **Preconditions:** Both online
- **Steps:**
  1. Connect, send message, disconnect
  2. Reconnect via button or Nearby discovery
  3. Verify chat works after reconnect
- **Expected:** Reconnection succeeds, chat functional
- **Existing Coverage:** `ReconnectInitiatorTests/testA1`

#### CONN-07: Remote Disconnect
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CONN07_RemoteDisconnect`
- **Acceptor:** `testB_CONN07_RemoteDisconnect`
- **Preconditions:** Connected
- **Steps:**
  1. Acceptor disconnects from their side
  2. Initiator detects failed state
  3. Initiator reconnects
  4. Chat verified after reconnect
- **Expected:** Remote disconnect detected, reconnect succeeds
- **Existing Coverage:** `ReconnectInitiatorTests/testA2`

#### CONN-08: Consent Cancel Message
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CONN08_ConsentCancelMessage`
- **Acceptor:** `testB_CONN08_ConsentCancelMessage`
- **Preconditions:** Both online
- **Steps:**
  1. Initiator requests connection
  2. Initiator navigates away (cancels)
  3. Acceptor consent sheet auto-dismisses
- **Expected:** Consent auto-dismissed on acceptor after cancel
- **Existing Coverage:** None

---

### Chat (CHAT)

#### CHAT-01: Text Round Trip
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CHAT01_TextRoundTrip`
- **Acceptor:** `testB_CHAT01_TextRoundTrip`
- **Preconditions:** Connected
- **Steps:**
  1. Initiator opens chat, sends "Hello from Sim1!"
  2. Acceptor receives, replies "Hello back from Sim2!"
  3. Initiator verifies reply
- **Expected:** Messages delivered bidirectionally
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario1` (embedded)

#### CHAT-02: Rapid Messages
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CHAT02_RapidMessages`
- **Acceptor:** `testB_CHAT02_RapidMessages`
- **Preconditions:** Connected
- **Steps:**
  1. Initiator sends 5 messages rapidly
  2. Acceptor verifies all 5 received
  3. Acceptor sends batch reply
- **Expected:** All 5 messages arrive, reply received
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario7` (partial)

#### CHAT-03: Unread Badge
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CHAT03_UnreadBadge`
- **Acceptor:** `testB_CHAT03_UnreadBadge`
- **Preconditions:** Connected
- **Steps:**
  1. Initiator sends message, leaves chat
  2. Acceptor sends 3 messages while initiator is away
  3. Initiator checks for unread badge on peer row
  4. Initiator re-enters chat to clear unread
- **Expected:** Unread badge appears, cleared on re-entry
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario7` (partial)

#### CHAT-04: History After Reconnect
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_CHAT04_HistoryAfterReconnect`
- **Acceptor:** `testB_CHAT04_HistoryAfterReconnect`
- **Preconditions:** Both online
- **Steps:**
  1. Connect, send message
  2. Disconnect, reconnect
  3. Verify old messages visible
- **Expected:** Chat history persists across reconnect
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario1` (partial)

#### CHAT-05: Attachment Menu
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_CHAT05_AttachmentMenu`
- **Preconditions:** Connected, in chat
- **Steps:**
  1. Tap attachment (+) button
  2. Verify Camera/Photos/Files options
  3. Cancel
- **Expected:** Attachment menu shows expected options
- **Existing Coverage:** None

#### CHAT-06: Camera Unavailable
- **Type:** Single | **Polarity:** Negative
- **Initiator:** `testA_CHAT06_CameraUnavailable`
- **Preconditions:** Connected, in chat (simulator)
- **Steps:**
  1. Open attachment menu
  2. Tap Camera
  3. Verify error alert (no camera on simulator)
- **Expected:** Graceful error alert
- **Existing Coverage:** None

#### CHAT-07: Chat Rejected By Peer
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_CHAT07_ChatRejectedByPeer`
- **Acceptor:** `testB_CHAT07_ChatRejectedByPeer`
- **Preconditions:** Connected, acceptor has chat disabled
- **Steps:**
  1. Initiator sends message
  2. Acceptor auto-rejects (chat disabled via launch args)
- **Expected:** Message rejected, no crash
- **Existing Coverage:** `DisabledFeatureInitiatorTests/testA3` (partial)

---

### File Transfer (FILE)

#### FILE-01: Send File UI
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_FILE01_SendFileUI`
- **Acceptor:** `testB_FILE01_SendFileUI`
- **Preconditions:** Connected
- **Steps:**
  1. Tap Send File button
  2. File picker opens
  3. Cancel picker
- **Expected:** File picker opens and dismisses cleanly
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario6` (partial)

#### FILE-02: Picker Cancel
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_FILE02_PickerCancel`
- **Preconditions:** Connected
- **Steps:**
  1. Open file picker
  2. Cancel
  3. Verify back on ConnectionView
- **Expected:** Returns to ConnectionView without side effects
- **Existing Coverage:** None

#### FILE-03: Transfer Progress
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_FILE03_TransferProgress`
- **Acceptor:** `testB_FILE03_TransferProgress`
- **Preconditions:** Connected
- **Steps:**
  1. Open file picker
  2. If file selected, verify progress bar appears
- **Expected:** Progress bar shown during transfer
- **Existing Coverage:** None

#### FILE-04: File Reject Disabled
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_FILE04_FileRejectDisabled`
- **Acceptor:** `testB_FILE04_FileRejectDisabled`
- **Preconditions:** Connected, acceptor file transfer disabled
- **Steps:**
  1. Initiator attempts file send
  2. Acceptor auto-rejects
- **Expected:** Transfer rejected, error feedback to initiator
- **Existing Coverage:** None

#### FILE-05: Transfer History
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_FILE05_TransferHistory`
- **Preconditions:** Connected
- **Steps:**
  1. Look for transfer history button
  2. Open history sheet
  3. Verify entries
- **Expected:** History sheet opens with past transfers
- **Existing Coverage:** None

---

### Voice Call (VOICE)

#### VOICE-01: Call Initiation
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_VOICE01_CallInitiation`
- **Acceptor:** `testB_VOICE01_CallInitiation`
- **Preconditions:** Connected
- **Steps:**
  1. Initiator taps Voice Call
  2. Acceptor sees incoming call (CallKit)
- **Expected:** Call initiated, acceptor notified
- **Existing Coverage:** None

#### VOICE-02: Mute/Speaker Toggle
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_VOICE02_MuteSpeakerToggle`
- **Preconditions:** In call
- **Steps:**
  1. Toggle mute on/off
  2. Toggle speaker on/off
  3. End call
- **Expected:** Toggles work without crash
- **Existing Coverage:** None

#### VOICE-03: End Call
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_VOICE03_EndCall`
- **Acceptor:** `testB_VOICE03_EndCall`
- **Preconditions:** In call
- **Steps:**
  1. Initiator ends call
  2. Both return to connected state
- **Expected:** Clean call termination, connection preserved
- **Existing Coverage:** None

#### VOICE-04: Call Reject Disabled
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_VOICE04_CallRejectDisabled`
- **Acceptor:** `testB_VOICE04_CallRejectDisabled`
- **Preconditions:** Connected, acceptor voice disabled
- **Steps:**
  1. Initiator taps Voice Call
  2. Acceptor auto-rejects
- **Expected:** Call rejected, connection preserved
- **Existing Coverage:** None

---

### Feature Toggles (FEAT)

#### FEAT-01: All Disabled
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_FEAT01_AllDisabled`
- **Acceptor:** `testB_FEAT01_AllDisabled`
- **Launch Args (Initiator):** `-peerDropChatEnabled 0 -peerDropFileTransferEnabled 0 -peerDropVoiceCallEnabled 0`
- **Preconditions:** Connected, all features disabled on initiator
- **Steps:**
  1. Tap Chat → alert "Chat is Off"
  2. Tap File → alert "File Transfer is Off"
  3. Tap Voice → alert "Voice Calls is Off"
- **Expected:** All 3 buttons exist (grayed), each shows disabled alert
- **Existing Coverage:** `DisabledFeatureInitiatorTests/testA1`

#### FEAT-02: Re-enable
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_FEAT02_Reenable`
- **Acceptor:** `testB_FEAT02_Reenable`
- **Launch Args (Initiator):** `-peerDropChatEnabled 1 -peerDropFileTransferEnabled 1 -peerDropVoiceCallEnabled 1`
- **Preconditions:** Connected, all features enabled
- **Steps:**
  1. Tap Chat → opens chat view (not alert)
  2. Send message, verify reply
- **Expected:** Features work normally when enabled
- **Existing Coverage:** `DisabledFeatureInitiatorTests/testA2`

#### FEAT-03: Chat Auto-Reject
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_FEAT03_ChatAutoReject`
- **Acceptor:** `testB_FEAT03_ChatAutoReject`
- **Launch Args (Acceptor):** `-peerDropChatEnabled 0`
- **Preconditions:** Connected, acceptor chat disabled
- **Steps:**
  1. Initiator sends message
  2. Acceptor auto-rejects (chatReject)
- **Expected:** Message rejected at protocol level
- **Existing Coverage:** `DisabledFeatureInitiatorTests/testA3` (partial)

#### FEAT-04: File Auto-Reject
- **Type:** Dual | **Polarity:** Negative
- **Initiator:** `testA_FEAT04_FileAutoReject`
- **Acceptor:** `testB_FEAT04_FileAutoReject`
- **Launch Args (Acceptor):** `-peerDropFileTransferEnabled 0`
- **Preconditions:** Connected, acceptor file disabled
- **Steps:**
  1. Initiator attempts file transfer
  2. Acceptor auto-rejects (fileReject)
- **Expected:** Transfer rejected at protocol level
- **Existing Coverage:** None

#### FEAT-05: Persist Via Launch Args
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_FEAT05_PersistViaLaunchArgs`
- **Launch Args:** `-peerDropChatEnabled 0 -peerDropFileTransferEnabled 1 -peerDropVoiceCallEnabled 0`
- **Preconditions:** Connected
- **Steps:**
  1. Chat button → alert (disabled)
  2. File button → opens picker (enabled)
  3. Voice button → alert (disabled)
- **Expected:** Launch args correctly control feature state
- **Existing Coverage:** None

---

### Settings (SET)

#### SET-01: Settings UI
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_SET01_SettingsUI`
- **Preconditions:** App running
- **Steps:**
  1. Open Settings via menu
  2. Verify: File Transfer, Voice Calls, Chat toggles
  3. Verify: Enable Notifications toggle
  4. Scroll down, verify Export/Import Archive buttons
- **Expected:** All settings sections and controls present
- **Existing Coverage:** `FullFeatureVerificationTests/test02`

#### SET-02: Display Name Change
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_SET02_DisplayNameChange`
- **Preconditions:** App running
- **Steps:**
  1. Open Settings
  2. Find Display Name field
  3. Change name
- **Expected:** Name field editable
- **Existing Coverage:** None

#### SET-03: Export While Connected
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_SET03_ExportWhileConnected`
- **Acceptor:** `testB_SET03_ExportWhileConnected`
- **Preconditions:** Connected
- **Steps:**
  1. Send chat message
  2. Open Settings while connected
  3. Tap Export Archive
  4. Dismiss share sheet
  5. Verify connection survived
- **Expected:** Archive exports, connection not interrupted
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario8`

#### SET-04: Import Archive
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_SET04_ImportArchive`
- **Preconditions:** App running
- **Steps:**
  1. Open Settings
  2. Scroll to Import Archive
  3. Tap Import Archive
  4. Verify document picker opens
  5. Cancel
- **Expected:** Document picker opens for import
- **Existing Coverage:** None

---

### Library (LIB)

#### LIB-01: Saved After Connect
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_LIB01_SavedAfterConnect`
- **Acceptor:** `testB_LIB01_SavedAfterConnect`
- **Preconditions:** Both online
- **Steps:**
  1. Connect, then disconnect
  2. Navigate to Library tab
  3. Verify device appears in Library
- **Expected:** Connected device saved to Library
- **Existing Coverage:** None

#### LIB-02: Reconnect From Library
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_LIB02_ReconnectFromLibrary`
- **Acceptor:** `testB_LIB02_ReconnectFromLibrary`
- **Preconditions:** Device in Library, peer online
- **Steps:**
  1. Connect and disconnect to populate Library
  2. Navigate to Library tab
  3. Tap saved device
  4. Verify reconnection
- **Expected:** Reconnect from Library succeeds
- **Existing Coverage:** None

#### LIB-03: Search
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_LIB03_Search`
- **Preconditions:** Library tab
- **Steps:**
  1. Tap search bar
  2. Type "iPhone"
  3. Verify filtered results
  4. Clear search
- **Expected:** Search filters devices
- **Existing Coverage:** None

#### LIB-04: Empty State
- **Type:** Single | **Polarity:** Negative
- **Initiator:** `testA_LIB04_EmptyState`
- **Preconditions:** Fresh launch, no saved devices
- **Steps:**
  1. Navigate to Library tab
  2. Check for empty state message
- **Expected:** "No saved devices" message shown
- **Existing Coverage:** None

---

### UI (UI)

#### UI-01: Tab Navigation
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_UI01_TabNavigation`
- **Preconditions:** App running
- **Steps:**
  1. Switch to each tab: Nearby, Connected, Library
  2. Verify each tab is selected
- **Expected:** All tabs navigable, correct selection state
- **Existing Coverage:** None

#### UI-02: Tab Switch Connected
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_UI02_TabSwitchConnected`
- **Acceptor:** `testB_UI02_TabSwitchConnected`
- **Preconditions:** Connected
- **Steps:**
  1. Rapidly switch all 3 tabs 3 times
  2. Verify still connected
- **Expected:** Connection stable through rapid tab switching
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario6`

#### UI-03: Connected Sections
- **Type:** Single | **Polarity:** Positive
- **Initiator:** `testA_UI03_ConnectedSections`
- **Preconditions:** App running
- **Steps:**
  1. Navigate to Connected tab
  2. Check for Active and Contacts section headers
- **Expected:** Section headers present
- **Existing Coverage:** None

#### UI-04: Stress Test
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_UI04_StressTest`
- **Acceptor:** `testB_UI04_StressTest`
- **Preconditions:** Both online
- **Steps:**
  1. 3 rounds: connect → chat → disconnect
  2. Verify app doesn't crash
- **Expected:** App stable through 3 rapid cycles
- **Existing Coverage:** `TwoDeviceInitiatorTests/testA_Scenario5`

#### UI-05: Status Toast
- **Type:** Dual | **Polarity:** Positive
- **Initiator:** `testA_UI05_StatusToast`
- **Acceptor:** `testB_UI05_StatusToast`
- **Preconditions:** Connected
- **Steps:**
  1. Disconnect
  2. Observe for status toast
- **Expected:** Toast appears on connection events
- **Existing Coverage:** None

---

## Coverage Matrix

| Spec ID | ComprehensiveVerification | TwoDeviceTests | DisabledFeatureUXTests | TimeoutConsentTests | TimeoutReconnectTests | FullFeatureVerification |
|---------|--------------------------|----------------|------------------------|--------------------|-----------------------|------------------------|
| DISC-01 | testA/B_DISC01 | S1 (partial) | - | - | - | - |
| DISC-02 | testA_DISC02 | - | - | - | - | - |
| DISC-03 | testA/B_DISC03 | S4 | - | - | - | test01 |
| DISC-04 | testA_DISC04 | - | - | - | - | - |
| DISC-05 | testA_DISC05 | - | - | - | - | - |
| CONN-01 | testA/B_CONN01 | S1 (partial) | - | - | - | - |
| CONN-02 | testA/B_CONN02 | S2 | - | - | - | - |
| CONN-03 | testA/B_CONN03 | - | - | A4/B4 | - | - |
| CONN-04 | testA/B_CONN04 | - | - | - | - | - |
| CONN-05 | testA/B_CONN05 | S1 (partial) | - | - | - | - |
| CONN-06 | testA/B_CONN06 | S1 (partial) | - | - | A1/B1 | - |
| CONN-07 | testA/B_CONN07 | - | - | - | A2/B2 | - |
| CONN-08 | testA/B_CONN08 | - | - | - | - | - |
| CHAT-01 | testA/B_CHAT01 | S1 (embedded) | - | - | - | - |
| CHAT-02 | testA/B_CHAT02 | S7 (partial) | - | - | - | - |
| CHAT-03 | testA/B_CHAT03 | S7 (partial) | - | - | - | - |
| CHAT-04 | testA/B_CHAT04 | S1 (partial) | - | - | - | - |
| CHAT-05 | testA_CHAT05 | - | - | - | - | - |
| CHAT-06 | testA_CHAT06 | - | - | - | - | - |
| CHAT-07 | testA/B_CHAT07 | - | A3/B3 (partial) | - | - | - |
| FILE-01 | testA/B_FILE01 | S6 (partial) | - | - | - | - |
| FILE-02 | testA_FILE02 | - | - | - | - | - |
| FILE-03 | testA/B_FILE03 | - | - | - | - | - |
| FILE-04 | testA/B_FILE04 | - | - | - | - | - |
| FILE-05 | testA_FILE05 | - | - | - | - | - |
| VOICE-01 | testA/B_VOICE01 | - | - | - | - | - |
| VOICE-02 | testA_VOICE02 | - | - | - | - | - |
| VOICE-03 | testA/B_VOICE03 | - | - | - | - | - |
| VOICE-04 | testA/B_VOICE04 | - | - | - | - | - |
| FEAT-01 | testA/B_FEAT01 | - | A1/B1 | - | - | - |
| FEAT-02 | testA/B_FEAT02 | - | A2/B2 | - | - | - |
| FEAT-03 | testA/B_FEAT03 | - | A3/B3 (partial) | - | - | - |
| FEAT-04 | testA/B_FEAT04 | - | - | - | - | - |
| FEAT-05 | testA_FEAT05 | - | - | - | - | - |
| SET-01 | testA_SET01 | - | - | - | - | test02 |
| SET-02 | testA_SET02 | - | - | - | - | - |
| SET-03 | testA/B_SET03 | S8 | - | - | - | - |
| SET-04 | testA_SET04 | - | - | - | - | - |
| LIB-01 | testA/B_LIB01 | - | - | - | - | - |
| LIB-02 | testA/B_LIB02 | - | - | - | - | - |
| LIB-03 | testA_LIB03 | - | - | - | - | - |
| LIB-04 | testA_LIB04 | - | - | - | - | - |
| UI-01 | testA_UI01 | - | - | - | - | - |
| UI-02 | testA/B_UI02 | S6 | - | - | - | - |
| UI-03 | testA_UI03 | - | - | - | - | - |
| UI-04 | testA/B_UI04 | S5 | - | - | A3/B3 | - |
| UI-05 | testA/B_UI05 | - | - | - | - | - |

**New scenarios (no prior coverage):** DISC-02, DISC-04, DISC-05, CONN-04, CONN-08, CHAT-05, CHAT-06, FILE-02, FILE-03, FILE-04, FILE-05, VOICE-01, VOICE-02, VOICE-03, VOICE-04, FEAT-04, FEAT-05, SET-02, SET-04, LIB-01, LIB-02, LIB-03, LIB-04, UI-01, UI-03, UI-05 (**26 new**)

**Previously covered (consolidated):** DISC-01, DISC-03, CONN-01, CONN-02, CONN-03, CONN-05, CONN-06, CONN-07, CHAT-01, CHAT-02, CHAT-03, CHAT-04, CHAT-07, FILE-01, FEAT-01, FEAT-02, FEAT-03, SET-01, SET-03, UI-02, UI-04 (**21 consolidated**)

---

## Launch Arguments Reference

| Key | Values | Default | Used By |
|-----|--------|---------|---------|
| `peerDropIsOnline` | `0` / `1` | `1` | All tests |
| `peerDropChatEnabled` | `0` / `1` | `1` | FEAT-01, FEAT-03, FEAT-05, CHAT-07 |
| `peerDropFileTransferEnabled` | `0` / `1` | `1` | FEAT-01, FEAT-04, FEAT-05, FILE-04 |
| `peerDropVoiceCallEnabled` | `0` / `1` | `1` | FEAT-01, FEAT-05, VOICE-04 |

## Accessibility Identifiers

| Identifier | Element | Used In |
|------------|---------|---------|
| `send-file-button` | Send File circle button | CONN-01, FILE-*, FEAT-* |
| `chat-button` | Chat circle button | CONN-01, CHAT-*, FEAT-* |
| `voice-call-button` | Voice Call circle button | CONN-01, VOICE-*, FEAT-* |
| `active-peer-row` | Active peer row in Connected | Navigation helper |
| `sheet-primary-action` | Primary button in PeerActionSheet | CONN-05, disconnect flow |
| `Disconnect` | Disconnect button in ConnectionView | CONN-05, disconnect helper |
| `Accept` / `Decline` | ConsentSheet buttons | CONN-01, CONN-02 |

## Screenshot Naming Convention

Format: `{SPEC-ID}-{step}-{description}`

Examples:
- `CONN-01-01-nearby`
- `CONN-01-02-requesting`
- `CONN-01-03-connected`
- `CONN-01-B-01-waiting` (acceptor)

---

## E2E Multi-Simulator Tests

Real device-to-device integration tests using two simulators running in parallel.

### Quick Start

```bash
# Setup (boot simulators, build app)
./Scripts/run-multi-sim-tests.sh setup

# Run smoke tests (4 core scenarios)
./Scripts/run-multi-sim-tests.sh run smoke

# Run full suite (10 scenarios)
./Scripts/run-multi-sim-tests.sh run full

# Run single test
./Scripts/run-multi-sim-tests.sh single CONN_01

# Check status
./Scripts/run-multi-sim-tests.sh status

# Clean test results
./Scripts/run-multi-sim-tests.sh clean
```

### Test Suites

| Suite | Tests | Description |
|-------|-------|-------------|
| smoke | 4 | Core path: DISC-01, CONN-01, CHAT-01, FILE-01 |
| full | 18 | All E2E scenarios |

### E2E Test Scenarios

| ID | Name | Description |
|----|------|-------------|
| DISC-01 | Mutual Discovery | Both devices discover each other via Bonjour |
| DISC-02 | Online/Offline | Peer disappears offline, reappears online |
| CONN-01 | Full Connection | Request → Accept → Connected state |
| CONN-02 | Reject/Retry | First reject, second accept succeeds |
| CONN-03 | Reconnection | Disconnect then reconnect with history preserved |
| CHAT-01 | Bidirectional Messages | 3 round-trip message exchanges |
| CHAT-02 | Rapid Messages | 10 messages in sequence |
| CHAT-03 | Read Receipts | Message read status updates |
| FILE-01 | File Picker UI | Open and cancel file picker |
| FILE-02 | Transfer Progress | Verify progress UI elements |
| LIB-01 | Device Saved | Device saved to contacts after connection |
| UI-01 | Tab Navigation | Switch between Nearby and Connected tabs |
| CALL-01 | Voice Call | Initiate and verify voice call UI |
| CALL-02 | Call Decline/Accept | Decline first call, accept second |
| VOICE-01 | Record Voice Message | Record and send voice message |
| VOICE-02 | Play Voice Message | Play/pause received voice message |
| REACT-01 | Message Reaction | Add emoji reaction to message |
| REPLY-01 | Swipe to Reply | Swipe-to-reply and send reply |

### Synchronization Mechanism

Tests use file-based checkpoints in `/tmp/peerdrop-test-sync/`:

```
Initiator                              Acceptor
    |                                      |
    | signal("ready") ─────────────────────▶|
    |◀───────────────────── wait("ready")   |
    |                                      |
    | tap peer                              |
    | signal("connection-requested") ──────▶|
    |◀────────── signal("connection-accepted")|
```

### Test Files

| File | Description |
|------|-------------|
| `E2E/MultiSimTestBase.swift` | Base class with sync primitives |
| `E2E/E2ETestSuites.swift` | All test implementations |
| `Scripts/run-multi-sim-tests.sh` | Test runner script |

### HTML Reports

Reports are generated at `TestResults/E2E/<timestamp>/report.html` after each run.
