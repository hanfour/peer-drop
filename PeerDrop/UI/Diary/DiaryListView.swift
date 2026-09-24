import SwiftUI
import PeerDropAccount
import PeerDropDiary

/// The Diary tab (iOS) / sidebar section (Mac). Expects an enclosing
/// `NavigationStack(path: $path)` — mirrors `NotesInboxView`.
struct DiaryListView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var accountManager: AccountManager
    /// Set by a notification tap; `openPendingDiary()` consumes it (pushes
    /// that diary onto `path`) and clears it in the same update.
    @Binding var openDiaryID: String?
    /// Carried alongside `openDiaryID` so a tapped `DIARY_ENTRY`/
    /// `DIARY_REACTION` notification can also scroll the pushed `DiaryView`
    /// to the entry it named (spec §4: "有 seq 則捲到該篇"). Consumed and
    /// cleared together with `openDiaryID`.
    @Binding var openDiarySeq: Int?
    @Binding var path: [String]
    @State private var showCreate = false
    @State private var showJoin = false
    /// Snapshot of the `(diaryId, seq)` pair `openPendingDiary()` just
    /// pushed, taken before `openDiaryID`/`openDiarySeq` are cleared.
    /// `navigationDestination` scrolls off this (not the bindings, which
    /// are already nil by the time it re-evaluates) — fix round 2: F1's
    /// round-1 fix cleared `openDiaryID` in the same update that set
    /// `path`, so `id == openDiaryID` in `navigationDestination` was
    /// always false and a tapped DIARY_ENTRY/DIARY_REACTION notification
    /// stopped scrolling to the named entry. Cleared once `path` empties
    /// so reopening the same diary manually later doesn't re-scroll.
    @State private var pendingScroll: (id: String, seq: Int?)?

    var body: some View {
        List {
            if case .ready = accountManager.state {} else {
                AccountSectionView(accountManager: accountManager)
            }
            if store.diaries.isEmpty {
                emptyState
            } else {
                ForEach(store.diaries) { summary in
                    NavigationLink(value: summary.diaryId) {
                        DiaryRowView(summary: summary, pendingKey: store.states[summary.diaryId]?.pendingKey ?? false)
                    }
                }
            }
        }
        .navigationTitle("Diaries")
        .navigationDestination(for: String.self) { id in
            DiaryView(diaryId: id, store: store, accountManager: accountManager, scrollToSeq: id == pendingScroll?.id ? pendingScroll?.seq : nil)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("New Diary", systemImage: "plus") }
                    .disabled(accountManager.account == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { showJoin = true } label: { Label("Join a Diary", systemImage: "person.badge.plus") }
                    .disabled(accountManager.account == nil)
            }
        }
        .refreshable { await store.syncList() }
        .sheet(isPresented: $showCreate) {
            NavigationStack { DiaryCreateSheet(store: store, onCreated: { id in path = [id] }) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 260)
                #endif
        }
        .sheet(isPresented: $showJoin) {
            NavigationStack { DiaryJoinSheet(store: store, onJoined: { id in path = [id] }) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 360)
                #endif
        }
        .task { await store.syncList() }
        .onChange(of: openDiaryID) { _ in openPendingDiary() }
        .onChange(of: store.diaries) { _ in openPendingDiary() }
        .onAppear { openPendingDiary() }
        .onChange(of: path) { if $0.isEmpty { pendingScroll = nil } }
    }

    private func openPendingDiary() {
        guard let id = openDiaryID, store.diaries.contains(where: { $0.diaryId == id }) else { return }
        pendingScroll = (id, openDiarySeq)
        path = [id]
        openDiaryID = nil
        openDiarySeq = nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No diaries yet. Create one, or join with a link or code.").foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

/// One row in `DiaryListView`: name, member count, current holder, and a
/// "Your turn" badge when this account is the holder (spec §5.2).
private struct DiaryRowView: View {
    let summary: DiarySummary
    let pendingKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.name ?? String(localized: "Untitled Diary")).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if summary.isMyTurn {
                    Text("Your turn")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
            }
            HStack(spacing: 6) {
                Text("\(summary.memberCount) members").font(.caption).foregroundStyle(.secondary)
                Text("·").font(.caption).foregroundStyle(.secondary)
                Text(NoteRowView.display(summary.holderAccountId)).font(.caption.monospaced()).foregroundStyle(.secondary)
                if pendingKey {
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Label("Waiting for key", systemImage: "key.slash").labelStyle(.titleOnly).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Not one of the spec's named sheets (`DiaryEntryComposer`/
/// `DiaryCommentsSheet`/`DiaryInviteSheet`/`DiaryJoinSheet`) — creating a
/// diary is just a name field, so it lives as a private sheet alongside the
/// list rather than its own top-level file.
private struct DiaryCreateSheet: View {
    @ObservedObject var store: DiaryStore
    var onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var canCreate: Bool { !isCreating && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section("Diary Name") {
                TextField("Enter a name", text: $name)
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("New Diary")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await create() } } label: {
                    if isCreating { ProgressView() } else { Text("Create") }
                }
                .disabled(!canCreate)
            }
        }
    }

    private func create() async {
        isCreating = true; errorMessage = nil
        defer { isCreating = false }
        do {
            let id = try await store.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            onCreated(id)
            dismiss()
        } catch let e as DiaryError {
            errorMessage = e.userMessage()
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
        }
    }
}
