import SwiftUI
import PeerDropCore
import PeerDropNotes

/// Delivery state of a note bubble. Notes have no delivered/read ticks: only
/// "sent to the mailbox", "waiting", "sending" and "failed".
enum NoteBubbleStatus: Equatable {
    case received
    case sentToMailbox
    case queued
    case sending
    case failed(NoteOutboxFailure?)

    static func status(for item: ThreadItem, sendingIDs: Set<UUID>) -> NoteBubbleStatus? {
        switch item {
        case .chat: return nil
        case .note(let n): return n.direction == .inbound ? .received : .sentToMailbox
        case .queued(let q):
            if q.state == .failed { return .failed(NoteOutboxFailure(reason: q.failReason)) }
            return sendingIDs.contains(q.id) ? .sending : .queued
        }
    }

    /// The short line under the note. Failed carries the retry hint (tap = retry).
    var statusText: String? {
        switch self {
        case .received: return nil
        case .sentToMailbox: return String(localized: "📮 Sent")
        case .queued: return String(localized: "Waiting to send")
        case .sending: return String(localized: "Sending…")
        case .failed: return String(localized: "Not sent. Tap to retry.")
        }
    }

    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

extension NoteOutboxFailure {
    /// Localized, user-facing reason (the Kit stores diagnostic Chinese text).
    var userText: String {
        switch self {
        case .bindingCancelled: return String(localized: "The notes link was cancelled.")
        case .tooOld: return String(localized: "Couldn't send within 24 hours.")
        case .blocked: return String(localized: "This contact is blocked.")
        case .inboxFull: return String(localized: "Their mailbox is full.")
        case .exhausted: return String(localized: "Couldn't send after several tries. Try again later.")
        case .recipientNotFound: return String(localized: "Their notes account wasn't found.")
        case .recipientHasNoKeys: return String(localized: "They aren't ready to receive notes yet.")
        case .recipientChanged: return String(localized: "Their account or key changed. Exchange notes again.")
        case .tooLong: return String(localized: "The note is too long.")
        case .noteNotFound: return String(localized: "This note is no longer available.")
        }
    }
}

/// A note in a friend thread: dashed paper bubble, no reactions / edit / reply / ticks.
struct NoteBubbleView: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let item: ThreadItem
    let status: NoteBubbleStatus
    let peerName: String
    let runStart: Bool
    var onRetry: () -> Void = {}
    var onDelete: () -> Void = {}
    var onBlock: (() -> Void)?
    var onReport: (() -> Void)?

    private var text: String {
        switch item {
        case .note(let n): return n.text ?? String(localized: "This note could not be decrypted.")
        case .queued(let q): return q.text
        case .chat: return ""
        }
    }

    private var isOutgoing: Bool { item.isOutgoing }

    private var failureText: String? {
        guard case .failed(let f) = status else { return nil }
        return f?.userText
    }

    var body: some View {
        HStack(alignment: .top) {
            if isOutgoing { Spacer(minLength: 50) }
            if !isOutgoing { ChatAvatarSlot(name: peerName, visible: runStart) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                bubble
            }

            if !isOutgoing { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 16)
        .padding(isOutgoing ? .trailing : .leading, -6)
    }

    @ViewBuilder
    private var bubble: some View {
        let content = VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            Text(text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(paper(.noteText))
                .textSelection(.enabled)
            HStack(spacing: 4) {
                Text(item.date, style: .time)
                if let line = status.statusText { Text(line) }
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(status.isFailed ? PaperTheme.color(.tickFailed, mode: paperMode) : paper(.noteText).opacity(0.75))
            if let failureText {
                Text(failureText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(paper(.noteText).opacity(0.75))
                    .multilineTextAlignment(isOutgoing ? .trailing : .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(paper(.noteFill))
        .clipShape(MessageBubbleShape(isOutgoing: isOutgoing))
        .overlay {
            MessageBubbleShape(isOutgoing: isOutgoing)
                .stroke(paper(.noteBorder), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .contextMenu {
            Button {
                NoteClipboard.copy(text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete this note", systemImage: "trash")
            }
            if let onBlock {
                Button(role: .destructive, action: onBlock) {
                    Label("Block Sender", systemImage: "hand.raised")
                }
            }
            if let onReport {
                Button(action: onReport) {
                    Label("Report Note", systemImage: "exclamationmark.bubble")
                }
            }
        }

        if status.isFailed {
            Button(action: onRetry) { content }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Double-tap to try sending again"))
        } else {
            content
        }
    }

    private var accessibilityText: String {
        let who = isOutgoing ? String(localized: "You") : peerName
        let time = item.date.formatted(date: .abbreviated, time: .shortened)
        var parts = [String(format: String(localized: "Note from %@"), who), text, time]
        if let line = status.statusText { parts.append(line) }
        if let failureText { parts.append(failureText) }
        return parts.joined(separator: ", ")
    }
}

/// Copies plain text on both platforms.
enum NoteClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Reason picker for reporting a note from the thread (same reasons as the inbox).
struct NoteReportSheet: View {
    let record: NoteRecord
    let onSubmit: (ReportReason, Bool) -> Void
    let onCancel: () -> Void
    @State private var reason: ReportReason = .spam
    @State private var includeText = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Report Note", selection: $reason) {
                    Text("Spam").tag(ReportReason.spam)
                    Text("Harassment").tag(ReportReason.harassment)
                    Text("Other reason").tag(ReportReason.other)
                }
                .pickerStyle(.inline)
                Toggle("Include the note's text for review", isOn: $includeText).disabled(record.text == nil)
            }
            .navigationTitle("Report Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Report Note") { onSubmit(reason, includeText) } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}
