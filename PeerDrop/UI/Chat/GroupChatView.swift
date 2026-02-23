import SwiftUI

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
                        ForEach(chatManager.groupMessages) { message in
                            GroupChatBubbleView(message: message, members: groupMembers)
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
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Double tap to connect to more group members")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $messageText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
                .accessibilityLabel("Message")
                .accessibilityHint(hasConnectedMembers ? "Type a message to the group" : "Connect to members first")

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .green)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    @State private var showReadReceipts = false

    private var bubbleColor: Color {
        message.isOutgoing ? Color.green : Color(.systemGray5)
    }

    private var textColor: Color {
        message.isOutgoing ? .white : .primary
    }

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Sender name for incoming messages
                if !message.isOutgoing, let senderName = message.senderName {
                    Text(senderName)
                        .font(.caption2.bold())
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 4)
                }

                // Message bubble
                VStack(alignment: .leading, spacing: 4) {
                    if let text = message.text {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(textColor)
                    }

                    // Timestamp and status
                    HStack(spacing: 4) {
                        Text(formatTime(message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(message.isOutgoing ? .white.opacity(0.7) : .secondary)

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
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if !message.isOutgoing {
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, 4)
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

        Group {
            switch message.status {
            case .sending:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            case .sent:
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            case .delivered, .read:
                HStack(spacing: 2) {
                    HStack(spacing: -3) {
                        Image(systemName: "checkmark")
                        Image(systemName: "checkmark")
                    }
                    .font(.caption2)
                    .foregroundStyle(readCount > 0 ? .cyan : .white.opacity(0.7))

                    // Show count indicator for group messages
                    if totalMembers > 1 {
                        Text("\(max(readCount, deliveredCount))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(readCount > 0 ? .cyan : .white.opacity(0.7))
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
