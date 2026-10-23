# Task 5 report
Status: DONE_WITH_CONCERNS (minor, see below)

Files: PeerDropCore/FriendBinding.swift, ThreadTransport.swift; PeerDropNotes/NotesStore.swift; PeerDrop/UI/Notes/NotesErrorText.swift (exhaustive switch gained .recipientMismatch, shares the generic "Could not send" text); tests FriendBindingTests, ThreadTransportTests, NotesStoreThreadTests.

Design choices
- FriendBindingResolver (pure) + FriendBinding(@MainActor, closure-injected contacts/records/liveHandshakeKey; convenience init(connectionManager:)). With a live handshake key, resolution is key-only (no id fallback, so a contact owning a different key is never guessed). Offline: unique contact by deviceId == peerID; if the DeviceRecord with that id shares a (case-insensitive) name with another record -> nil. Step 3 is therefore a guard, since record.id == peerID makes it equal to step 2; record.peerDeviceId is never used (test covers).
- boundAccount returns BoundAccount{accountId, contactID, verified, identityKey}; extra bindingState(forChatPeerID:) -> BindingState because boundAccount is nil for a pending claim with no accountId yet.
- ThreadTransport.live(showExchangeButton) = binding != .verified only; the UI hides it additionally when the peer lacks supportsNotesExchange.
- NotesStore: notes(forAccount:) oldest-first (inbound by receivedAt, outbound by sentAt), unreadCount(forAccount:), boundUnreadIDs(accounts: Set<String>) -> Set<String>, sendToBound; send refactored into private deliver(...) with unchanged behaviour (existing NotesStoreTests green). recipientMismatch is checked before the bundle check, so nothing is sealed or spent.

Tests: Kit full swift test 1063 run, only IdentityKeyManagerTests.testKeyPersistsAcrossInstances fails (baseline). New: 10 FriendBinding, 2 ThreadTransport, 8 NotesStoreThread; NotesStoreTests 24 pass. iOS and Mac builds succeed.
Note: implementation was written before the first test run (no separate RED run).

## Fix round 1
- I-2: `boundAccount` replaced by `verifiedAccount(forChatPeerID:) -> VerifiedAccount?` (nil unless accountId != nil && no pending). `bindingState` is pending whenever a pending claim exists (re-exchange locks the thread conservatively). Test: account X + pending Y.
- I-3: `Decision.live` has no payload; literal 18-row table test.
- I-1: merged-name guard and the `records` input removed; resolution is per identity only. Known residual risk: DeviceRecordStore name merges leave no marker and cannot be detected here.
- M-2: live connection without a handshake key (`LiveConnectionKey.unsecured`) -> nil. M-3: offline path requires a unique identity key; blocked + unblocked duplicate -> nil.
- M-4: `notes(forAccount:)` tie-breaks by id. M-5: sender assertion, lowercase accountId -> recipientMismatch, no bundle -> recipientHasNoKeys, noAccount tests; double blank line removed; `[weak cm]`. M-1: OPK comment added.
- M-6 (for Task 6): the outbox must treat `recipientMismatch` as a permanent failure with a re-exchange hint.
- Tests: full Kit 1068, only the baseline IdentityKeyManagerTests failure; iOS and Mac builds succeed.
