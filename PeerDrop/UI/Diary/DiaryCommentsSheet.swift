import SwiftUI
import PeerDropAccount
import PeerDropDiary

/// One entry's comments + like (spec §5.2: "DiaryCommentsSheet（留言 500
/// 字、按讚）"). `entry` is the snapshot at sheet-open time for the header;
/// live comments/like-count are recomputed from `store.states` so a
/// concurrent `sync` while the sheet is open still updates them.
struct DiaryCommentsSheet: View {
    let diaryId: String
    let entry: DiaryEvent
    @ObservedObject var store: DiaryStore
    @ObservedObject var accountManager: AccountManager
    @Environment(\.dismiss) private var dismiss
    @State private var commentText = ""
    @State private var isPosting = false
    @State private var isLiking = false
    @State private var errorMessage: String?

    private var events: [DiaryEvent] { store.states[diaryId]?.events ?? [] }
    private var comments: [DiaryEvent] {
        events.filter { $0.type == .comment && $0.refSeq == entry.seq }.sorted { $0.seq < $1.seq }
    }
    private var likeCount: Int { events.filter { $0.type == .like && $0.refSeq == entry.seq }.count }
    private var myId: String? { accountManager.account?.accountId.raw }
    private var likedByMe: Bool { events.contains { $0.type == .like && $0.refSeq == entry.seq && $0.authorAccountId == myId } }
    private var remaining: Int { DiaryCrypto.maxCommentScalars - commentText.unicodeScalars.count }
    private var canPost: Bool { !isPosting && !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remaining >= 0 }
    private var isClosed: Bool { store.states[diaryId]?.meta.isClosed ?? false }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Text(entry.payload?.text ?? String(localized: "Content unavailable"))
                        .font(.body).textSelection(.enabled)
                    Button {
                        Task { await like() }
                    } label: {
                        // Verbatim — see DiaryView's like/comment counts for why.
                        Label(String(likeCount), systemImage: likedByMe ? "heart.fill" : "heart")
                    }
                    .disabled(isLiking || isClosed)
                    .tint(likedByMe ? .red : .secondary)
                }
                Section("Comments") {
                    if comments.isEmpty {
                        Text("No comments yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(comments) { comment in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NoteRowView.display(comment.authorAccountId)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(comment.payload?.text ?? String(localized: "Content unavailable")).font(.body)
                            }
                        }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            if !isClosed {
                HStack {
                    TextField("Add a comment…", text: $commentText, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button { Task { await postComment() } } label: {
                        if isPosting { ProgressView() } else { Text("Post") }
                    }
                    .disabled(!canPost)
                }
                .padding()
            }
        }
        .navigationTitle("Comments")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }

    private func like() async {
        isLiking = true
        defer { isLiking = false }
        do { try await store.like(diaryId, seq: entry.seq) }
        catch let e as DiaryError { errorMessage = e.userMessage() }
        catch { errorMessage = String(localized: "Something went wrong. Please try again.") }
    }

    private func postComment() async {
        isPosting = true; errorMessage = nil
        defer { isPosting = false }
        do {
            try await store.comment(diaryId, seq: entry.seq, text: commentText.trimmingCharacters(in: .whitespacesAndNewlines))
            commentText = ""
        } catch let e as DiaryError {
            errorMessage = e.userMessage()
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
        }
    }
}
