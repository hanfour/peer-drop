import SwiftUI
import PeerDropAccount
import PeerDropDiary
import PeerDropNotes

/// One diary's timeline/page view + holder bar + write/pass/skip/
/// request-key/closed affordances (spec §5.2). `scrollToSeq` — set when
/// this view was pushed from a `DIARY_ENTRY`/`DIARY_REACTION` notification
/// tap (spec §4: "有 seq 則捲到該篇") — scrolls the timeline to that entry
/// once on appear.
struct DiaryView: View {
    let diaryId: String
    @ObservedObject var store: DiaryStore
    @ObservedObject var accountManager: AccountManager
    var scrollToSeq: Int?

    private enum Mode { case timeline, page }

    @State private var mode: Mode = .timeline
    @State private var pageIndex = 0
    @State private var showComposer = false
    @State private var showComments: DiaryEvent?
    @State private var showInvite = false
    @State private var showLeaveConfirm = false
    @State private var reportTarget: DiaryEvent?
    @State private var errorMessage: String?
    @State private var holderNickname: String?
    @State private var didScrollToTarget = false

    private var state: DiaryState? { store.states[diaryId] }
    private var entries: [DiaryEvent] { (state?.events ?? []).filter { $0.type == .entry }.sorted { $0.seq < $1.seq } }
    private var holderId: String? {
        guard let meta = state?.meta, meta.members.indices.contains(meta.holderIndex) else { return nil }
        return meta.members[meta.holderIndex]
    }
    private var myId: String? { accountManager.account?.accountId.raw }

    var body: some View {
        Group {
            if let state {
                diaryContent(state)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(state?.meta.name ?? String(localized: "Untitled Diary"))
        .toolbar { toolbarContent }
        .task { await store.sync(diaryId) }
        .task(id: state?.meta.holderIndex) { await loadHolderNickname() }
        .sheet(isPresented: $showComposer) {
            NavigationStack { DiaryEntryComposer(diaryId: diaryId, store: store) }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 360)
                #endif
        }
        .sheet(item: $showComments) { entry in
            NavigationStack { DiaryCommentsSheet(diaryId: diaryId, entry: entry, store: store, accountManager: accountManager) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 420)
                #endif
        }
        .sheet(isPresented: $showInvite) {
            NavigationStack { DiaryInviteSheet(diaryId: diaryId, store: store) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 320)
                #endif
        }
        .sheet(item: $reportTarget) { entry in
            NavigationStack { DiaryReportSheet(diaryId: diaryId, entry: entry, store: store) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 300)
                #endif
        }
        .confirmationDialog("Leave this diary?", isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button("Leave Diary", role: .destructive) { Task { await leave() } }
        } message: {
            Text("You'll stop receiving new pages, but pages already on this device stay. You'll also keep your copy of the diary key — leaving doesn't revoke it.")
        }
        .alert("Diary", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func diaryContent(_ state: DiaryState) -> some View {
        VStack(spacing: 0) {
            holderBar(state)
            if state.meta.isClosed {
                Text("This diary is closed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !state.hasKey {
                waitingForKeyCard
            }
            Divider()
            if entries.isEmpty {
                Spacer()
                Text("No pages yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                switch mode {
                case .timeline: timelineList
                case .page: pageView
                }
            }
        }
        .refreshable { await store.sync(diaryId) }
    }

    // MARK: - Holder bar

    @ViewBuilder
    private func holderBar(_ state: DiaryState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Turn").font(.caption).foregroundStyle(.secondary)
                    Text(holderNickname ?? holderId.map(NoteRowView.display) ?? "—").font(.subheadline.weight(.semibold))
                }
                Spacer()
                if state.isHolder {
                    Text("Your turn")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
            }
            if !state.meta.isClosed {
                HStack(spacing: 12) {
                    if state.isHolder && state.hasKey {
                        Button { showComposer = true } label: { Label("Write", systemImage: "square.and.pencil") }
                            .buttonStyle(.borderedProminent)
                        Button("Pass to Next") { Task { await pass() } }
                            .buttonStyle(.bordered)
                    }
                    if state.isOwner && !state.isHolder {
                        Button("Skip") { Task { await skip() } }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding()
    }

    private var waitingForKeyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Exact same string as `DiaryError.noKey`'s message (global
            // constraint: no punctuation-only duplicate catalog keys).
            Label("Waiting for the diary key.", systemImage: "key.slash").font(.subheadline.weight(.semibold))
            Button("Request Key Again") { Task { await requestKey() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.bottom, 8)
    }

    // MARK: - Timeline

    private var timelineList: some View {
        ScrollViewReader { proxy in
            List(entries) { entry in
                entryRow(entry).id(entry.seq)
            }
            .listStyle(.plain)
            .onAppear {
                guard !didScrollToTarget, let seq = scrollToSeq else { return }
                didScrollToTarget = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation { proxy.scrollTo(seq, anchor: .top) }
                }
            }
        }
    }

    private func entryRow(_ entry: DiaryEvent) -> some View {
        let comments = (state?.events ?? []).filter { $0.type == .comment && $0.refSeq == entry.seq }.count
        let likes = (state?.events ?? []).filter { $0.type == .like && $0.refSeq == entry.seq }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(NoteRowView.display(entry.authorAccountId)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(entry.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.payload?.text ?? String(localized: "Content unavailable"))
                .font(.body).textSelection(.enabled)
            Button {
                showComments = entry
            } label: {
                HStack(spacing: 14) {
                    // `String(likes)`/`String(comments)`, not string
                    // interpolation directly in `Label(_:)` — a bare
                    // number has no surrounding words to disambiguate it
                    // for translators, and the icon already conveys the
                    // meaning, so this is deliberately NOT run through the
                    // catalog (verbatim `Text`/`Label` overload).
                    Label(String(likes), systemImage: "heart")
                    Label(String(comments), systemImage: "bubble.right")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button { reportTarget = entry } label: { Label("Report Entry", systemImage: "exclamationmark.bubble") }
        }
    }

    // MARK: - Page mode

    @ViewBuilder
    private var pageView: some View {
        #if os(iOS)
        TabView(selection: $pageIndex) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                ScrollView { entryRow(entry).padding() }.tag(index)
            }
        }
        .tabViewStyle(.page)
        #else
        VStack(spacing: 0) {
            if entries.indices.contains(pageIndex) {
                ScrollView { entryRow(entries[pageIndex]).padding() }
            }
            HStack {
                Button { pageIndex = max(0, pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(pageIndex == 0)
                Spacer()
                // Text(verbatim:) — not catalog-extracted, same reason as
                // the like/comment counts above: a bare "N / M" pager has
                // no words to translate.
                Text(verbatim: "\(pageIndex + 1) / \(entries.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { pageIndex = min(entries.count - 1, pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(pageIndex >= entries.count - 1)
            }
            .padding()
        }
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Display Mode", selection: $mode) {
                Text("Timeline").tag(Mode.timeline)
                Text("Page").tag(Mode.page)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItem(placement: .secondaryAction) {
            Button { showInvite = true } label: { Label("Invite", systemImage: "person.crop.circle.badge.plus") }
        }
        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) { showLeaveConfirm = true } label: { Label("Leave Diary", systemImage: "rectangle.portrait.and.arrow.right") }
        }
    }

    // MARK: - Actions

    private func loadHolderNickname() async {
        holderNickname = nil
        guard let holderId, holderId != myId else { return }
        holderNickname = try? await accountManager.lookup(handle: holderId, includeBundle: false)?.nickname
    }

    private func pass() async {
        do { try await store.pass(diaryId) }
        catch let e as DiaryError { errorMessage = e.userMessage() }
        catch { errorMessage = String(localized: "Something went wrong. Please try again.") }
    }
    private func skip() async {
        do { try await store.skip(diaryId) }
        catch let e as DiaryError { errorMessage = e.userMessage() }
        catch { errorMessage = String(localized: "Something went wrong. Please try again.") }
    }
    private func requestKey() async {
        do { try await store.requestKey(diaryId) }
        catch let e as DiaryError { errorMessage = e.userMessage() }
        catch { errorMessage = String(localized: "Something went wrong. Please try again.") }
    }
    private func leave() async {
        do { try await store.leave(diaryId) }
        catch let e as DiaryError { errorMessage = e.userMessage() }
        catch { errorMessage = String(localized: "Something went wrong. Please try again.") }
    }
}

/// Report one entry (spec §6: "每篇可檢舉"). Reuses `PeerDropNotes.ReportReason`
/// via `DiaryClient.report`, same three values as note reports.
private struct DiaryReportSheet: View {
    let diaryId: String
    let entry: DiaryEvent
    @ObservedObject var store: DiaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .spam
    @State private var includeText = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Picker("Report Entry", selection: $reason) {
                Text("Spam").tag(ReportReason.spam)
                Text("Harassment").tag(ReportReason.harassment)
                Text("Other reason").tag(ReportReason.other)
            }
            .pickerStyle(.inline)
            Toggle("Include the entry's text for review", isOn: $includeText).disabled(entry.payload?.text == nil)
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Report Entry")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Report Entry") { Task { await report() } } }
        }
    }

    private func report() async {
        do {
            try await store.report(diaryId, seq: entry.seq, reason: reason, includeText: includeText)
            dismiss()
        } catch let e as DiaryError {
            errorMessage = e.userMessage()
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
        }
    }
}
