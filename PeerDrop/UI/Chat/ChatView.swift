import SwiftUI
import PeerDropCore
import PeerDropProtocol
import PeerDropTransport
import PeerDropPlatform
import PeerDropNotes
import UniformTypeIdentifiers
import os
#if canImport(PhotosUI) && os(iOS)
import PhotosUI
#endif

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ChatView")

struct ChatView: View, PaperThemed {
    @ObservedObject var chatManager: ChatManager
    let peerID: String
    let peerName: String
    var onBack: (() -> Void)?
    /// iOS: show the header info button that pushes `ConnectionView` (only for chats opened from the
    /// Home / Notes stacks; the chat pushed from ConnectionView itself leaves it off).
    var showsConnectionInfo = false
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var messageText = ""
    @State private var showAttachmentMenu = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    #if canImport(PhotosUI) && os(iOS)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif
    @StateObject private var thread = ThreadModel()
    /// Owned by the thread model so leaving live chat clears it.
    private var replyingToMessage: ChatMessage? {
        get { thread.replyingToMessage }
        nonmutating set { thread.replyingToMessage = newValue }
    }
    @State private var modeNotice: String?
    @State private var lastComposerMode: ComposerMode?
    @State private var noteToBlock: NoteRecord?
    @State private var noteToReport: NoteRecord?
    @State private var noteActionMessage: String?
    @State private var showMicPermissionAlert = false
    @State private var showSearch = false
    @State private var scrollToMessageID: String?
    @StateObject private var voiceRecorder = VoiceRecorder()
    #if os(iOS)
    @State private var showConnectionInfo = false
    #endif

    /// A headless peer (peerdrop-cli: a shell or AI agent) has no audio and no
    /// useful file handling, so the chat hides the attach + voice-message
    /// affordances and leaves a text-only composer.
    private var isPeerHeadless: Bool {
        if let pc = connectionManager.connection(for: peerID) {
            return pc.peerIdentity.isHeadless
        }
        return connectionManager.connectedPeer?.id == peerID
            && (connectionManager.connectedPeer?.isHeadless ?? false)
    }

    /// Check if this peer is disconnected. A dropped peer's connection is removed
    /// from the manager (and the global state falls back to discovering), so a
    /// missing connection counts as disconnected unless a dial is in progress.
    private var isPeerDisconnected: Bool {
        ChatPeerPresence.isDisconnected(
            connectionState: connectionManager.connection(for: peerID)?.state,
            globalState: connectionManager.state)
    }

    /// The name the live connection knows for this peer, if any and not blank.
    private var liveName: String? {
        ChatDisplayName.trimmed(connectionManager.connection(for: peerID)?.peerIdentity.displayName)
    }

    /// Peer name for copy and bubbles: the live connection's name first, then the
    /// name this chat was opened with; blank falls back to a neutral phrase.
    private var displayName: String {
        ChatDisplayName.preferred(liveName, peerName) ?? String(localized: "Other person")
    }

    /// Presence of this peer, resolved over every id alias (connection key / identity id).
    private var peerPresence: PeerPresence {
        PeerPresenceResolver.presence(ids: [peerID], sources: connectionManager.presenceSources())
    }

    /// Live only while the peer is online; nearby / offline fall back to the paper-note look.
    /// Also forced to note while the connection is known to be down.
    /// NOTE: this computed property intentionally shadows the `\.paperMode` environment value
    /// for ChatView itself; descendants receive it via `.paperMode(paperMode)` in `body`.
    var paperMode: PaperMode {
        ChatPresenceMode.mode(peerID: peerID, connectionManager: connectionManager)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var noticeToken = UUID()
    @State private var noteToDelete: NoteRecord?

    var body: some View {
        chatContent
            .paperMode(paperMode)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if thread.items.isEmpty {
                        EmptyChatView(message: String(localized: "No messages yet. Say hello to \(displayName)."))
                            .padding(.top, 80)
                    }
                    if chatManager.hasMoreMessages {
                        Button("Load earlier messages") {
                            chatManager.loadMoreMessages()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                    }

                    ForEach(thread.items) { item in
                        if thread.dayStartIDs.contains(item.id) {
                            ChatDatePill(date: item.date)
                        }
                        threadRow(item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .onChange(of: thread.items.last?.id) { lastID in
                if let lastID {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: scrollToMessageID) { messageID in
                if let messageID {
                    withAnimation {
                        // Thread rows are keyed by ThreadItem.id ("chat:<message id>").
                        proxy.scrollTo("chat:\(messageID)", anchor: .center)
                    }
                    // Clear after scrolling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        scrollToMessageID = nil
                    }
                }
            }
        }
    }

    private var chatContent: some View {
        noteActionDialogs(chatCore)
    }

    private var chatCore: some View {
        VStack(spacing: 0) {
            // Messages
            messageList

            // Typing indicator
            if chatManager.isTyping(peerID: peerID) {
                TypingIndicatorView(peerName: displayName)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Divider()

            // Decrypt-failure banner: surfaces after N consecutive decrypt
            // failures from this peer. Either action clears it.
            if let failureBanner = connectionManager.decryptFailureBanner,
               failureBanner.contactId == peerID {
                DecryptFailureBannerView(
                    displayName: failureBanner.displayName,
                    onVerify: {
                        // No dedicated fingerprint sheet from inside the chat
                        // yet — dismissing keeps the user in the chat without
                        // re-nagging. Future: navigate to contact detail.
                        connectionManager.dismissDecryptFailureBanner()
                    },
                    onDismiss: {
                        connectionManager.dismissDecryptFailureBanner()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Disconnected banner with reconnect option
            if isPeerDisconnected {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(thread.mode.isNote
                             ? String(format: String(localized: "%@ is offline. Notes go to their mailbox."), displayName)
                             : String(localized: "\(displayName) is offline. Chat again when they're back."))
                            .font(.subheadline.weight(.medium))
                    }

                    HStack(spacing: 16) {
                        Button {
                            if !connectionManager.reconnect(to: peerID) {
                                connectionManager.statusToast = String(localized: "Can't find \(displayName) nearby. Make sure they have PeerDrop open.")
                            }
                        } label: {
                            Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(paper(.actionFill))

                        Button {
                            // Navigate back and return to discovery
                            connectionManager.returnToDiscovery()
                        } label: {
                            Text("Back to Nearby")
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                                .foregroundStyle(paper(.incomingText))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(paper(.datePillFill), in: Capsule())
                                .overlay(Capsule().stroke(paper(.border), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(paper(.background))
                .overlay(alignment: .top) {
                    Rectangle().fill(paper(.border)).frame(height: 1)
                }
            }

            // Reply preview bar
            if let replyMessage = replyingToMessage {
                replyPreviewBar(for: replyMessage)
            }

            // Composer: live chat, a note to a bound friend, or a locked bar (ThreadTransport decides).
            if thread.isReady {
                composer
            } else {
                Color.clear.frame(height: 56)
            }
        }
        // Only the ground cross-fades on a live/note flip; layout must not animate.
        .background(paper(.background).animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: paperMode))
        // Local accent for the chat screen only; the app-wide tint is untouched.
        .tint(paper(.accent))
        .navigationTitle(displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            // Rounded title face; the system navigation bar itself is kept.
            // (macOS keeps the system window title from navigationTitle.)
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    PeerAvatar(name: displayName, size: 30, presence: peerPresence, notesReachable: thread.binding == .verified)
                        .accessibilityHidden(true)
                    Text(verbatim: displayName)
                        .font(.system(.headline, design: .rounded))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(displayName), \(peerPresence.accessibilityLabel(notesReachable: thread.binding == .verified))"))
                .accessibilityAddTraits(.isHeader)
            }
            if showsConnectionInfo, ChatPresenceMode.showsInfoButton(presence: peerPresence) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        connectionManager.focus(on: connectionManager.connection(for: peerID)?.id ?? peerID)
                        showConnectionInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel(Text("Connection details"))
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                ExchangeNotesButton(peerID: peerID, peerName: displayName,
                                    bindingState: thread.binding, contactID: thread.contactID)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        #if os(iOS)
        .navigationDestination(isPresented: $showConnectionInfo) {
            ConnectionView().environmentObject(connectionManager)
        }
        #endif
        .onAppear {
            chatManager.loadMessages(forPeer: peerID)
            thread.attach(connectionManager: connectionManager, chatManager: chatManager, peerID: peerID)
            thread.markVisibleNotesRead(isActive: scenePhase == .active)
            chatManager.activeChatPeerID = peerID
            // Focus on this peer for multi-connection
            connectionManager.focus(on: peerID)
            // Suppress the global error alert while in ChatView (we handle disconnection locally)
            connectionManager.suppressErrorAlert = true
            // Send read receipts for unread messages
            connectionManager.sendReadReceipts(for: peerID)
        }
        .onDisappear {
            chatManager.activeChatPeerID = nil
            connectionManager.suppressErrorAlert = false
        }
        .sheet(isPresented: $showAttachmentMenu) {
            AttachmentMenuSheet(
                onCamera: { showAttachmentMenu = false; showCamera = true },
                onPhotos: { showAttachmentMenu = false; showPhotoPicker = true },
                onFiles: { showAttachmentMenu = false; showDocumentPicker = true }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerView { image in
                sendImage(image)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotoItems) { items in
            Task { await handleSelectedPhotos(items) }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                for url in urls {
                    sendFile(url)
                }
            }
        }
        #else
        // The iOS document picker is UIKit; on macOS the "Files" option set
        // `showDocumentPicker` but nothing ever presented, so it did nothing.
        .fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { sendFile(url) }
            }
        }
        #endif
        .alert("Microphone Access Required", isPresented: $showMicPermissionAlert) {
            Button("Open Settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #elseif os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable microphone access in Settings to record voice messages.")
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchView(
                chatManager: chatManager,
                peerID: peerID,
                onSelectMessage: { message in
                    scrollToMessageID = message.id
                }
            )
        }
    }

    private func noteActionDialogs<V: View>(_ content: V) -> some View {
        content
        // Notes from the bound friend count as read while the thread is on screen.
        .onChange(of: thread.unreadNoteIDs) { _ in thread.markVisibleNotesRead(isActive: scenePhase == .active) }
        .onChange(of: scenePhase) { phase in thread.markVisibleNotesRead(isActive: phase == .active) }
        .onChange(of: thread.mode) { newMode in
            handleModeChange(to: newMode)
        }
        .confirmationDialog("Block this sender?", isPresented: Binding(get: { noteToBlock != nil }, set: { if !$0 { noteToBlock = nil } }), titleVisibility: .visible) {
            Button("Block Sender", role: .destructive) {
                if let record = noteToBlock { Task { await block(record) } }
                noteToBlock = nil
            }
        } message: { Text("You will no longer receive notes from this sender, even anonymous ones.") }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete this note", role: .destructive) {
                if let record = noteToDelete { Task { await connectionManager.notesStore.delete(record) } }
                noteToDelete = nil
            }
        } message: { Text("This also deletes the note from the server.") }
        .sheet(item: $noteToReport) { record in
            NoteReportSheet(record: record, onSubmit: { reason, includeText in
                noteToReport = nil
                Task { await report(record, reason: reason, includeText: includeText) }
            }, onCancel: { noteToReport = nil })
        }
        .alert("Note", isPresented: Binding(get: { noteActionMessage != nil }, set: { if !$0 { noteActionMessage = nil } })) {
            Button("OK") { noteActionMessage = nil }
        } message: { Text(noteActionMessage ?? "") }
    }

    // MARK: - Thread rows

    @ViewBuilder
    private func threadRow(_ item: ThreadItem) -> some View {
        switch item {
        case .chat(let message):
            ChatBubbleView(
                message: message,
                chatManager: chatManager,
                runStart: thread.runStartIDs.contains(item.id),
                liveSenderName: liveName,
                onReaction: { emoji in
                    connectionManager.sendReaction(
                        emoji: emoji,
                        to: message.id,
                        action: .add,
                        peerID: peerID
                    )
                },
                onEdit: { messageID, newText in
                    connectionManager.sendMessageEdit(
                        messageID: messageID,
                        newText: newText,
                        to: peerID
                    )
                },
                onDelete: { messageID in
                    connectionManager.sendMessageDelete(
                        messageID: messageID,
                        to: peerID
                    )
                },
                onReply: thread.mode.isLive ? { replyingToMessage = message } : nil
            )
            .swipeToReply(isEnabled: !message.isDeleted && thread.mode.isLive, isDeleted: message.isDeleted) {
                replyingToMessage = message
            }
            .accessibilityActions {
                if !message.isDeleted && thread.mode.isLive {
                    Button("Reply") { replyingToMessage = message }
                }
            }
        case .note(let record):
            NoteBubbleView(
                item: item,
                status: NoteBubbleStatus.status(for: item, sendingIDs: thread.sendingIDs) ?? .received,
                peerName: displayName,
                runStart: thread.runStartIDs.contains(item.id),
                onDelete: {
                    if record.direction == .inbound { noteToDelete = record }
                    else { Task { await connectionManager.notesStore.delete(record) } }
                },
                onBlock: record.direction == .inbound ? { noteToBlock = record } : nil,
                onReport: record.direction == .inbound ? { noteToReport = record } : nil)
        case .queued(let entry):
            NoteBubbleView(
                item: item,
                status: NoteBubbleStatus.status(for: item, sendingIDs: thread.sendingIDs) ?? .queued,
                peerName: displayName,
                runStart: thread.runStartIDs.contains(item.id),
                onRetry: {
                    connectionManager.noteOutbox.retry(id: entry.id)
                    Task { await connectionManager.flushNoteOutbox() }
                },
                onDelete: {
                    // Never remove an entry whose network send is in flight.
                    guard !thread.sendingIDs.contains(entry.id) else { return }
                    connectionManager.noteOutbox.remove(id: entry.id)
                })
        }
    }

    private func block(_ record: NoteRecord) async {
        do {
            _ = try await connectionManager.notesStore.block(record)
            connectionManager.statusToast = String(localized: "Sender blocked")
        } catch {
            noteActionMessage = (error as? NotesStoreError)?.userMessage(context: .inboxAction)
                ?? String(localized: "Something went wrong. Please try again.")
        }
    }

    private func report(_ record: NoteRecord, reason: ReportReason, includeText: Bool) async {
        do {
            try await connectionManager.notesStore.report(record, reason: reason, includeText: includeText)
            connectionManager.statusToast = String(localized: "Report sent")
        } catch {
            noteActionMessage = (error as? NotesStoreError)?.userMessage(context: .inboxAction)
                ?? String(localized: "Something went wrong. Please try again.")
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 0) {
            if thread.outboxProblem {
                Label("Some unsent notes could not be restored", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("outbox-problem-banner")
            }
            switch thread.mode.kind {
            case .live:
                inputBar
            case .note:
                noteInputBar
            case .locked(let reason):
                lockedBar(reason)
            }
        }
    }

    /// The connection dropped or came back while the composer was on screen. Text and
    /// drafts are never converted automatically: only the look changes, with a one-line notice.
    private func handleModeChange(to newMode: ComposerMode) {
        let old = lastComposerMode
        lastComposerMode = newMode
        if !newMode.isLive, voiceRecorder.isRecording { voiceRecorder.cancelRecording() }
        if newMode.isNote, old?.isLive == true {
            modeNotice = String(localized: "Switched to a note")
            noticeToken = UUID()   // restarts the scoped auto-clear task below
        } else if !newMode.isNote {
            modeNotice = nil
        }
    }

    private var noteScalarCount: Int { ComposerMode.scalarCount(messageText) }

    private var noteInputBar: some View {
        VStack(spacing: 0) {
            if let modeNotice {
                Label(modeNotice, systemImage: "envelope")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(paper(.noteText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.updatesFrequently)
                    .task(id: noticeToken) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if !Task.isCancelled { self.modeNotice = nil }
                    }
            }
            if thread.mode.queuesUntilOnline {
                Label("Will be sent when your account is ready", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(paper(.noteText).opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(text: $messageText,
                          prompt: Text(verbatim: String(format: String(localized: "Write a note to %@…"), displayName))
                              .foregroundColor(paper(.noteText).opacity(0.6)),
                          axis: .vertical) {
                    Text("Note")
                }
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(paper(.noteText))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(paper(.noteFill))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(paper(.noteBorder), style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                .accessibilityLabel(Text(verbatim: String(format: String(localized: "Write a note to %@…"), displayName)))
                .onSubmit { sendMessage() }

                if ComposerMode.showsCounter(forText: messageText) {
                    Text(verbatim: "\(noteScalarCount)/\(ComposerMode.noteScalarLimit)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ComposerMode.isOverLimit(messageText) ? Color.red : paper(.noteText).opacity(0.8))
                        .accessibilityLabel(Text(verbatim: String(format: String(localized: "%lld of %lld characters"), noteScalarCount, ComposerMode.noteScalarLimit)))
                }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSendNote ? paper(.noteBadge) : paper(.noteText).opacity(0.3))
                }
                .paperIconButton()
                .disabled(!canSendNote)
                .accessibilityLabel("Send note")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var canSendNote: Bool {
        let t = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !ComposerMode.isOverLimit(t)
    }

    private func lockedBar(_ reason: LockReason) -> some View {
        let text: String
        switch reason {
        case .notExchanged: text = String(localized: "Exchange notes with each other to stay in touch offline.")
        case .verifying: text = String(localized: "Checking their notes account…")
        case .accountUnavailable: text = String(localized: "Notes can't be sent from this device.")
        }
        return HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text(verbatim: text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.gray.opacity(0.15))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Reply Preview Bar

    private func replyPreviewBar(for message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(paper(.quoteBar))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.isOutgoing ? "You" : (message.senderName ?? message.peerName))
                    .font(.caption.bold())
                    .foregroundStyle(paper(.datePillText))

                Text(message.text ?? message.fileName ?? "Media")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                replyingToMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(paper(.inputPlaceholder))
            }
        }
        // The accent bar is a shape with no intrinsic height and would otherwise grow to fill
        // all the space the chat offers, turning this strip into a half-screen block.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(paper(.datePillFill))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Recording indicator
            if voiceRecorder.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)

                    Text("Recording \(formatDuration(voiceRecorder.duration))")
                        .font(.caption)
                        .foregroundStyle(.red)

                    // Waveform visualization
                    HStack(spacing: 2) {
                        ForEach(0..<15, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.red.opacity(0.6))
                                .frame(width: 2, height: CGFloat(voiceRecorder.audioLevel * 16 + 4))
                        }
                    }

                    Spacer()

                    // Cancel button
                    Button {
                        voiceRecorder.cancelRecording()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(paper(.inputPlaceholder))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                // + Attachment button — hidden for headless peers (a shell/agent
                // has no useful file handling).
                if !isPeerHeadless {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(paper(.inputPlaceholder))
                    }
                    .paperIconButton()
                    .accessibilityLabel("Attach")
                }

                // Text field
                TextField(text: $messageText, prompt: Text(verbatim: "Aa").foregroundColor(paper(.inputPlaceholder))) {
                    Text("Message")
                }
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(paper(.inputFill))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(paper(.border), lineWidth: 1))
                    .accessibilityLabel("Message")
                    // Return/Enter sends. Without this the only affordance
                    // was the arrow button — on the Mac, Enter in a chat
                    // input silently doing nothing reads as broken
                    // (audit round 15 live-verification finding).
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }
                    .onChange(of: messageText) { newValue in
                        // Typing indicators are live-chat only; a note composer sends nothing until Send.
                        guard thread.mode.isLive else { return }
                        connectionManager.handleTypingChange(
                            in: peerID,
                            hasText: !newValue.isEmpty
                        )
                    }

                // Send or Mic button. A headless peer can't play audio, so it
                // gets no voice-message button — just send when there's text.
                if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !isPeerHeadless {
                        Button {
                            if voiceRecorder.isRecording {
                                stopAndSendVoiceMessage()
                            } else {
                                startVoiceRecording()
                            }
                        } label: {
                            Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.title2)
                                .foregroundStyle(voiceRecorder.isRecording ? Color.red : paper(.inputPlaceholder))
                        }
                        .paperIconButton()
                        .accessibilityLabel(voiceRecorder.isRecording ? "Stop recording" : "Voice message")
                    }
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(paper(.sendButton))
                    }
                    .paperIconButton()
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Send text

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch thread.mode.kind {
        case .locked: return
        case .note:
            sendNote(text)
            return
        case .live: break
        }
        // Use per-peer send for multi-connection
        connectionManager.sendTextMessage(text, to: peerID, replyTo: replyingToMessage)
        messageText = ""
        replyingToMessage = nil
    }

    /// Queues a note the user just sent. The text stays in the field when anything fails.
    private func sendNote(_ text: String) {
        let outcome = NoteSender.send(text: text, contactID: thread.contactID) { text, id in
            try connectionManager.queueNote(text: text, toContact: id)
        }
        if outcome.clearsText {
            messageText = ""
            modeNotice = nil
        } else if let message = outcome.message {
            connectionManager.statusToast = message
        }
    }

    // MARK: - Send image

    private func sendImage(_ image: PlatformImage) {
        guard let data = image.platformJPEGData(compressionQuality: 0.8) else { return }
        let fileName = "IMG_\(Date().timeIntervalSince1970).jpg"
        let thumbData = makeThumbnail(image, maxSize: 200)

        connectionManager.sendMediaMessage(
            mediaType: .image,
            fileName: fileName,
            fileData: data,
            mimeType: "image/jpeg",
            duration: nil,
            thumbnailData: thumbData
        )
    }

    // MARK: - Handle photo picker (iOS only)

    #if canImport(PhotosUI) && os(iOS)
    private func handleSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let fileName = "Photo_\(Date().timeIntervalSince1970).jpg"
                let thumbData = PlatformImage(data: data).flatMap { self.makeThumbnail($0, maxSize: 200) }

                await MainActor.run {
                    connectionManager.sendMediaMessage(
                        mediaType: .image,
                        fileName: fileName,
                        fileData: data,
                        mimeType: "image/jpeg",
                        duration: nil,
                        thumbnailData: thumbData
                    )
                }
            }
        }
        await MainActor.run { selectedPhotoItems = [] }
    }
    #endif

    // MARK: - Send file

    private func sendFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        // Check before reading: the file rides inline in the message, so there is a
        // cap, and loading a huge file into memory just to refuse it is wasteful.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > MediaMessagePayload.maxInlineFileSize {
            let maxMB = MediaMessagePayload.maxInlineFileSize / (1024 * 1024)
            connectionManager.statusToast = String(localized: "File too large to send in chat (max \(maxMB) MB)")
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let fileName = url.lastPathComponent
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        connectionManager.sendMediaMessage(
            mediaType: .file,
            fileName: fileName,
            fileData: data,
            mimeType: mimeType,
            duration: nil,
            thumbnailData: nil
        )
    }

    // MARK: - Voice recording

    private func startVoiceRecording() {
        Task {
            // Check permission first
            if !VoiceRecorder.hasPermission {
                let granted = await VoiceRecorder.requestPermission()
                if !granted {
                    await MainActor.run {
                        showMicPermissionAlert = true
                    }
                    return
                }
            }

            do {
                try voiceRecorder.startRecording()
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
                // Surface it — without this the mic button appeared to do
                // nothing (or worse, the UI showed a fake "Recording 0:00")
                // when capture couldn't start (audit round 16).
                await MainActor.run {
                    connectionManager.statusToast = error.localizedDescription
                }
            }
        }
    }

    private func stopAndSendVoiceMessage() {
        let duration = voiceRecorder.duration
        guard let url = voiceRecorder.stopRecording() else { return }
        guard duration >= 0.5 else {
            // Too short OR the recorder never actually captured (duration
            // stuck at 0 — e.g. mic unavailable). Silently dropping here
            // made the user think the message was sent (audit round 16
            // live finding) — always surface why nothing appeared.
            try? FileManager.default.removeItem(at: url)
            connectionManager.statusToast = String(localized: "Recording too short")
            return
        }

        // Read the recorded audio data
        guard let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            connectionManager.statusToast = String(localized: "Voice message failed")
            return
        }

        let fileName = "Voice_\(Date().timeIntervalSince1970).m4a"
        connectionManager.sendMediaMessage(
            mediaType: .voice,
            fileName: fileName,
            fileData: data,
            mimeType: "audio/mp4",
            duration: duration,
            thumbnailData: nil
        )

        // Clean up temp file
        try? FileManager.default.removeItem(at: url)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Thumbnail

    /// Resizes a PlatformImage to fit within maxSize×maxSize and returns JPEG data.
    /// iOS: uses UIGraphicsImageRenderer for best quality.
    /// macOS: uses CGContext-based resize — same output, no AppKit dependency.
    private func makeThumbnail(_ image: PlatformImage, maxSize: CGFloat) -> Data? {
        #if canImport(UIKit)
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return thumb.jpegData(compressionQuality: 0.6)
        #elseif canImport(AppKit)
        guard let cgImage = image.platformCGImage else { return nil }
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(maxSize / srcW, maxSize / srcH, 1.0)
        let dstW = Int(srcW * scale)
        let dstH = Int(srcH * scale)
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let resized = ctx.makeImage() else { return nil }
        let thumb = PlatformImage(platformCGImage: resized, size: CGSize(width: dstW, height: dstH))
        return thumb?.platformJPEGData(compressionQuality: 0.6)
        #else
        return nil
        #endif
    }
}

// MARK: - Document Picker (iOS only)

#if canImport(UIKit)
struct DocumentPickerView: UIViewControllerRepresentable {
    var onDocumentsPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentsPicked: onDocumentsPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentsPicked: ([URL]) -> Void

        init(onDocumentsPicked: @escaping ([URL]) -> Void) {
            self.onDocumentsPicked = onDocumentsPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDocumentsPicked(urls)
        }
    }
}
#endif

// MARK: - iMessage-style Attachment Menu

struct AttachmentMenuSheet: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(menuItems, id: \.label) { item in
                Button(action: item.action) {
                    HStack(spacing: 16) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundStyle(paper(.outgoingText))
                            .frame(width: 40, height: 40)
                            .background(item.color)
                            .clipShape(Circle())

                        Text(item.label)
                            .font(.body)
                            .foregroundStyle(paper(.incomingText))

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }

                if item.label != menuItems.last?.label {
                    Divider().padding(.leading, 76)
                }
            }
        }
        .padding(.top, 8)
        .background(paper(.background))
    }

    private var menuItems: [MenuItem] {
        var items: [MenuItem] = []
        #if os(iOS)
        items.append(MenuItem(icon: "camera.fill", label: "Camera", color: paper(.attachCamera), action: onCamera))
        items.append(MenuItem(icon: "photo.on.rectangle", label: "Photos", color: paper(.attachPhotos), action: onPhotos))
        #endif
        items.append(MenuItem(icon: "doc.fill", label: "Files", color: paper(.attachFiles), action: onFiles))
        return items
    }

    private struct MenuItem {
        let icon: String
        let label: String
        let color: Color
        let action: () -> Void
    }
}

extension ChatPresenceMode {
    /// Mode for a chat with `peerID`, shared by ChatView and the Mac chat window.
    @MainActor
    static func mode(peerID: String, connectionManager: ConnectionManager) -> PaperMode {
        mode(presence: PeerPresenceResolver.presence(ids: [peerID], sources: connectionManager.presenceSources()),
             isDisconnected: ChatPeerPresence.isDisconnected(
                connectionState: connectionManager.connection(for: peerID)?.state,
                globalState: connectionManager.state))
    }
}
