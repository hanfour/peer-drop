import SwiftUI
import PeerDropCore
import PeerDropSecurity

struct GroupChatView: View {
    let group: DeviceGroup
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var messageText = ""

    private var chatManager: ChatManager {
        connectionManager.chatManager
    }

    private var connectionStatus: (connected: Int, total: Int, online: Int) {
        connectionManager.groupConnectionStatus(group)
    }

    private var hasConnectedMembers: Bool {
        connectionStatus.connected > 0
    }

    /// Get PeerIdentity for all group members
    private var groupMembers: [PeerIdentity] {
        group.deviceIDs.compactMap { deviceID in
            connectionManager.connection(for: deviceID)?.peerIdentity
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Connection status header
            statusHeader

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if chatManager.groupMessages.isEmpty {
                            EmptyChatView(message: String(localized: "No messages yet. Say hello to everyone."))
                                .padding(.top, 80)
                        }
                        let runStarts = ChatMessageRuns.firstInRunIDs(in: chatManager.groupMessages)
                        let dayStarts = ChatMessageRuns.dayStartIDs(in: chatManager.groupMessages)
                        ForEach(chatManager.groupMessages) { message in
                            if dayStarts.contains(message.id) {
                                ChatDatePill(date: message.timestamp)
                            }
                            GroupChatBubbleView(
                                message: message,
                                members: groupMembers,
                                runStart: runStarts.contains(message.id)
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                }
                .onChange(of: chatManager.groupMessages.count) { _ in
                    if let last = chatManager.groupMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            inputBar
                .disabled(!hasConnectedMembers)
                .opacity(hasConnectedMembers ? 1.0 : 0.5)
        }
        .background(PaperTheme.color(.background))
        // Local accent for the chat screen only; the app-wide tint is untouched.
        .tint(PaperTheme.color(.accent))
        .navigationTitle(group.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            // Rounded title face; the system navigation bar itself is kept.
            ToolbarItem(placement: .principal) {
                Text(verbatim: group.name)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            #endif
        }
        .onAppear {
            chatManager.loadGroupMessages(forGroup: group.id)
            chatManager.activeGroupID = group.id
        }
        .onDisappear {
            chatManager.activeGroupID = nil
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            // Connected count
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("\(connectionStatus.connected)/\(connectionStatus.total) connected")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(PaperTheme.color(.datePillText))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(connectionStatus.connected) of \(connectionStatus.total) members connected")

            Spacer()

            // Connect more button
            if connectionStatus.online > connectionStatus.connected {
                Button {
                    connectionManager.connectToGroup(group)
                } label: {
                    Label("Connect More", systemImage: "link.badge.plus")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(PaperTheme.color(.incomingText))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(PaperTheme.color(.background), in: Capsule())
                        .overlay(Capsule().stroke(PaperTheme.color(.border), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Double tap to connect to more group members")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PaperTheme.color(.datePillFill))
        .overlay(alignment: .bottom) {
            Rectangle().fill(PaperTheme.color(.border)).frame(height: 1)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(text: $messageText, prompt: Text(verbatim: "Aa").foregroundColor(PaperTheme.color(.inputPlaceholder))) {
                Text("Message")
            }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(PaperTheme.color(.inputFill))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(PaperTheme.color(.border), lineWidth: 1))
                .accessibilityLabel("Message")
                .accessibilityHint(hasConnectedMembers ? "Type a message to the group" : "Connect to members first")

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PaperTheme.color(.inputPlaceholder) : PaperTheme.color(.sendButton))
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .paperIconButton()
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        connectionManager.broadcastTextMessage(text, toGroup: group.id)
        messageText = ""
    }
}

// MARK: - Group Chat Bubble

struct GroupChatBubbleView: View {
    let message: ChatMessage
    let members: [PeerIdentity]
    let runStart: Bool

    init(message: ChatMessage, members: [PeerIdentity], runStart: Bool = true) {
        self.message = message
        self.members = members
        self.runStart = runStart
    }

    private var senderDisplayName: String {
        ChatDisplayName.trimmed(message.senderName) ?? String(localized: "Other person")
    }

    @State private var showReadReceipts = false

    private var bubbleColor: Color {
        PaperTheme.color(message.isOutgoing ? .outgoingBubble : .incomingBubble)
    }

    private var textColor: Color {
        PaperTheme.color(message.isOutgoing ? .outgoingText : .incomingText)
    }

    var body: some View {
        HStack(alignment: .top) {
            if message.isOutgoing {
                Spacer(minLength: 50)
            }

            if !message.isOutgoing {
                ChatAvatarSlot(name: senderDisplayName, visible: runStart)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Sender name on the first message of a run
                if !message.isOutgoing && runStart {
                    Text(senderDisplayName)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(PaperTheme.color(.datePillText))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 4)
                        .accessibilityHidden(true)
                }

                // Message bubble
                VStack(alignment: .leading, spacing: 4) {
                    if let text = message.text {
                        Text(text)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(textColor)
                    }

                    // Timestamp and status
                    HStack(spacing: 4) {
                        Text(formatTime(message.timestamp))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(textColor.opacity(0.7))

                        if message.isOutgoing {
                            statusIcon
                                .onTapGesture {
                                    showReadReceipts = true
                                }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor)
                .clipShape(MessageBubbleShape(isOutgoing: message.isOutgoing))
                .overlay {
                    if !message.isOutgoing {
                        MessageBubbleShape(isOutgoing: false)
                            .stroke(PaperTheme.color(.border), lineWidth: 1)
                    }
                }
            }

            if !message.isOutgoing {
                Spacer(minLength: 50)
            }
        }
        .padding(.horizontal, 16)
        .padding(message.isOutgoing ? .trailing : .leading, -6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(groupBubbleAccessibilityLabel)
        .sheet(isPresented: $showReadReceipts) {
            GroupReadReceiptView(message: message, members: members)
        }
    }

    private var groupBubbleAccessibilityLabel: String {
        let sender = message.isOutgoing ? "You" : (message.senderName ?? "Unknown")
        let content = message.text ?? "media"
        return "\(sender): \(content)"
    }

    @ViewBuilder
    private var statusIcon: some View {
        let status = message.groupReadStatus
        let deliveredCount = status?.deliveredTo.count ?? 0
        let readCount = status?.readBy.count ?? 0
        let totalMembers = members.count
        let tickColor = PaperTheme.color(PaperTheme.tick(for: readCount > 0 ? .read : .delivered))

        Group {
            switch message.status {
            case .sending:
                ProgressView()
                    .tint(textColor)
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            case .sent:
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(PaperTheme.color(PaperTheme.tick(for: .sent)))
            case .delivered, .read:
                HStack(spacing: 2) {
                    HStack(spacing: -3) {
                        Image(systemName: "checkmark")
                        Image(systemName: "checkmark")
                    }
                    .font(.caption2)
                    .foregroundStyle(tickColor)

                    // Show count indicator for group messages
                    if totalMembers > 1 {
                        Text("\(max(readCount, deliveredCount))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tickColor)
                    }
                }
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
