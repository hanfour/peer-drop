import SwiftUI
import PeerDropCore
import PeerDropTransport
import PeerDropNotes
import PeerDropDiary
import PeerDropAccount

/// Modifier to force tab bar style on iPad (iOS 18+)
struct TabBarOnlyModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.tabBarOnly)
        } else {
            content
        }
    }
}

/// Unified sheet state for `ContentView` — replaces the previous mix of
/// boolean `@State` flags driving `.sheet(isPresented:)`. Sheets owned by
/// `ConnectionManager` (transferProgress, voiceCall, pendingIncomingRequest,
/// pendingFirstContact) stay where they are; alerts and toasts use their
/// own mechanics and are intentionally not unified here.
enum ContentSheet: Identifiable {
    case share(URL)
    case connectionOptions

    var id: String {
        switch self {
        case .share: return "share"
        case .connectionOptions: return "connectionOptions"
        }
    }
}

/// Routes the three security-related `ConnectionManager` sheets through a
/// single `.sheet(item:)` binding. Without this, when two of the three
/// underlying `@Published` fields go non-nil concurrently (a remote-mailbox
/// invite landing while a local-Wi-Fi handshake completes is the realistic
/// case), SwiftUI logs `[Invalid Configuration] Currently, only presenting
/// a single sheet is supported` and silently queues one of them. The router
/// picks by priority (incoming → remote first-contact → local first-trust);
/// once the active one is resolved, the next non-nil source surfaces on the
/// next render.
private enum SecuritySheetRoute: Identifiable {
    case incomingRequest(IncomingRequest)
    case firstContact(PendingFirstContact)
    case localFirstTrust(PendingFirstContact)

    var id: String {
        switch self {
        case .incomingRequest(let r):  return "incoming:\(r.id)"
        case .firstContact(let p):     return "remote:\(p.id)"
        case .localFirstTrust(let p):  return "local:\(p.id)"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var inboxService: InboxService
    @ObservedObject private var pushManager = PushNotificationManager.shared
    @State private var selectedTab: AppTab = .home
    /// Bumped by the `.openNote` deep link so the Notes tab pushes its inbox (see `ConversationsTab.inboxRequest`).
    @State private var inboxRequest = 0
    @State private var openNoteID: String?
    @State private var diariesPath: [String] = []
    @State private var openDiaryID: String?
    @State private var openDiarySeq: Int?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var activeSheet: ContentSheet?
    @State private var showStatusToast = false
    @State private var statusToastMessage: String?
    @State private var showReportSentToast = false
    @State private var currentInvite: RelayInvite?
    @State private var processedInviteIDs: [String: Date] = [:] // id → timestamp, 60s TTL
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @EnvironmentObject var connectionContext: ConnectionContext

    var body: some View {
        ZStack(alignment: .top) {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeTab(onAddFriend: { selectedTab = .nearby })
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)
            .accessibilityLabel("Home")
            .accessibilityHint("View connected devices")

            ConversationsTabContent(
                store: connectionManager.notesStore,
                accountManager: connectionManager.accountManager,
                openNoteID: $openNoteID,
                inboxRequest: inboxRequest,
                onGoHome: { selectedTab = .home }
            )
            .tabItem { Label("Notes", systemImage: "envelope.fill") }
            .tag(AppTab.notes)
            .accessibilityLabel("Notes")

            NavigationStack {
                NearbyTab(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("Nearby", systemImage: "wifi")
            }
            .tag(AppTab.nearby)
            .accessibilityLabel("Nearby")
            .accessibilityHint("Discover Nearby Devices")

            DiaryTabContent(store: connectionManager.diaryStore, accountManager: connectionManager.accountManager, openDiaryID: $openDiaryID, openDiarySeq: $openDiarySeq, path: $diariesPath)
                .paperMode(.note)
                .tabItem { Label("Diaries", systemImage: "book.closed") }
                .tag(AppTab.diaries)
                .accessibilityLabel("Diaries")
        }
        .tint(PaperTheme.color(.brand))
        .modifier(TabBarOnlyModifier())  // Force tab bar on iPad
        .onReceive(NotificationCenter.default.publisher(for: .openNote)) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            selectedTab = AppTab.tab(forDeepLink: .openNote) ?? .notes
            openNoteID = id
            inboxRequest += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiary)) { note in
            guard let id = note.userInfo?["diaryId"] as? String else { return }
            selectedTab = AppTab.tab(forDeepLink: .openDiary) ?? .diaries
            openDiaryID = id
            openDiarySeq = note.userInfo?["seq"] as? Int
        }
        .sheet(item: securitySheetBinding) { route in
            switch route {
            case .incomingRequest(let request):
                ConsentSheet(request: request)
                    .environmentObject(connectionManager)
            case .firstContact(let pending):
                FirstContactVerificationSheet(
                    pending: pending,
                    onApprove: {
                        connectionManager.approveFirstContact(fingerprint: pending.fingerprint)
                    },
                    onReject: {
                        connectionManager.rejectFirstContact(fingerprint: pending.fingerprint)
                    }
                )
            case .localFirstTrust(let pending):
                FirstContactVerificationSheet(
                    pending: pending,
                    onApprove: {
                        connectionManager.approveLocalFirstTrust(fingerprint: pending.fingerprint)
                    },
                    onReject: {
                        connectionManager.blockLocalFirstTrust(fingerprint: pending.fingerprint)
                    }
                )
            }
        }
        .sheet(isPresented: $connectionManager.showTransferProgress) {
            TransferProgressView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $connectionManager.showVoiceCall) {
            VoiceCallView()
                .environmentObject(connectionManager)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let url):
                ShareSheet(items: [url])
            case .connectionOptions:
                ConnectionOptionsSheet()
                    .environmentObject(connectionManager)
                    .environmentObject(connectionContext)
            }
        }
        .alert("Connection Error", isPresented: $showError) {
            if connectionManager.canReconnect {
                Button("Reconnect") {
                    connectionManager.reconnect()
                }
            }
            Button("Send Error Report") {
                if let error = errorMessage {
                    ErrorReporter.report(
                        error: error,
                        context: "user-reported",
                        extras: ["focusedPeer": connectionManager.focusedPeerID ?? "none"]
                    )
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showReportSentToast = true
                }
                connectionManager.transition(to: .discovering)
                connectionManager.restartDiscovery()
                selectedTab = .nearby
            }
            Button("Back to Discovery", role: .cancel) {
                connectionManager.transition(to: .discovering)
                connectionManager.restartDiscovery()
                selectedTab = .nearby
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .fullScreenCover(isPresented: Binding(
            get: { !hasCompletedOnboarding && !ScreenshotModeProvider.shared.isActive },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView()
        }
        .onChange(of: connectionManager.state) { _ in
            switch connectionManager.state {
            case .connected, .transferring, .voiceCall:
                selectedTab = .home
            case .failed(let reason):
                // Only show alert if not suppressed (e.g., ChatView handles it locally).
                // Recommendation card is now persistent in NearbyTab.
                if !connectionManager.suppressErrorAlert {
                    errorMessage = reason
                    showError = true
                }
            case .rejected:
                // Always show rejected alert (user needs to know)
                errorMessage = "The peer declined your connection request."
                showError = true
            default:
                break
            }
        }
        .onChange(of: connectionManager.fileTransfer?.receivedFileURL) { _ in
            if let url = connectionManager.fileTransfer?.receivedFileURL {
                activeSheet = .share(url)
                connectionManager.fileTransfer?.receivedFileURL = nil
            }
        }
        .onChange(of: connectionManager.statusToast) { _ in
            guard let message = connectionManager.statusToast else { return }
            statusToastMessage = message
            connectionManager.statusToast = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showStatusToast = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    showStatusToast = false
                }
            }
        }
        .onReceive(inboxService.$receivedInvite.compactMap { $0 }) { invite in
            inboxService.receivedInvite = nil
            guard invite.hasToken else { return } // WS invites always have token
            guard !isInviteProcessed(invite.id), currentInvite == nil else { return }
            // If we had a token-less APNs invite for the same room, upgrade it
            if let current = currentInvite, !current.hasToken, current.roomCode == invite.roomCode {
                currentInvite = invite
                return
            }
            currentInvite = invite
        }
        .onReceive(pushManager.$receivedInvite.compactMap { $0 }) { invite in
            pushManager.receivedInvite = nil
            guard !isInviteProcessed(invite.id), currentInvite == nil else { return }
            // APNs invite may not have token — show banner but disable Accept until WS flushes
            currentInvite = invite
        }

            // Invite banner overlay
            if let invite = currentInvite {
                InviteBanner(
                    invite: invite,
                    canAccept: invite.hasToken,
                    onAccept: {
                        markInviteProcessed(invite.id)
                        connectionManager.acceptRelayInvite(invite)
                        currentInvite = nil
                    },
                    onDecline: {
                        markInviteProcessed(invite.id)
                        currentInvite = nil
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
                .zIndex(3)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentInvite)
            }

            // Status toast overlay
            if showStatusToast, let message = statusToastMessage {
                StatusToastView(message, icon: "xmark.circle.fill", iconColor: .orange)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .zIndex(2)
            }

            // Report sent toast
            if showReportSentToast {
                StatusToastView("Error Report Sent", icon: "checkmark.circle.fill", iconColor: .green)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .zIndex(2)
            }

            // Failure recommendation is now surfaced via NearbyTab's persistent GuidanceCard;
            // failure-specific alert is still shown above (showError).
        }
        .onChange(of: showReportSentToast) { newValue in
            if newValue {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation(.easeOut(duration: 0.3)) {
                        showReportSentToast = false
                    }
                }
            }
        }
    }

    // MARK: - Invite dedup helpers (60s TTL)

    private func isInviteProcessed(_ id: String) -> Bool {
        guard let ts = processedInviteIDs[id] else { return false }
        return Date().timeIntervalSince(ts) < 60
    }

    private func markInviteProcessed(_ id: String) {
        processedInviteIDs[id] = Date()
        // Evict stale entries
        let cutoff = Date().addingTimeInterval(-60)
        processedInviteIDs = processedInviteIDs.filter { $0.value > cutoff }
    }

    // MARK: - Security sheet routing

    /// Two-way binding that funnels the three `ConnectionManager` security
    /// sheets through a single `.sheet(item:)`. Read: highest-priority
    /// non-nil source wins. Write: only the dismiss-to-nil case matters;
    /// clear whichever source the active sheet was reading from. The
    /// FirstContactVerificationSheet's button callbacks already clear
    /// their source directly, so set(nil) here mainly handles swipe-down
    /// dismiss (which `.interactiveDismissDisabled(true)` actually blocks
    /// for those sheets, but the path stays correct in case the modifier
    /// is ever removed).
    private var securitySheetBinding: Binding<SecuritySheetRoute?> {
        Binding(
            get: {
                if let req = connectionManager.pendingIncomingRequest {
                    return .incomingRequest(req)
                }
                if let pending = connectionManager.pendingFirstContact {
                    return .firstContact(pending)
                }
                if let pending = connectionManager.pendingLocalFirstTrust {
                    return .localFirstTrust(pending)
                }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if connectionManager.pendingIncomingRequest != nil {
                    connectionManager.pendingIncomingRequest = nil
                } else if connectionManager.pendingFirstContact != nil {
                    connectionManager.pendingFirstContact = nil
                } else if connectionManager.pendingLocalFirstTrust != nil {
                    connectionManager.pendingLocalFirstTrust = nil
                }
            }
        )
    }
}

/// Notes tab body: hosts `ConversationsTab` in its own NavigationStack and observes the store
/// so the tab badge updates. This view lives outside the stack, so it keeps running while
/// notes are pushed: it (not the inbox view) resolves `openNoteID` into `pendingNote`.
/// A `.openNote` deep link bumps `inboxRequest`, which makes `ConversationsTab` push the inbox
/// (single route, no-op if already showing); `NotesInboxHost` then pushes `pendingNote`.
private struct ConversationsTabContent: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var accountManager: AccountManager
    @Binding var openNoteID: String?
    var inboxRequest: Int
    var onGoHome: () -> Void
    @State private var pendingNote: NoteRecord?

    var body: some View {
        NavigationStack {
            ConversationsTab(inboxUnread: store.unreadCount, onGoHome: onGoHome, inboxRequest: inboxRequest) {
                NotesInboxHost(store: store, accountManager: accountManager, note: $pendingNote)
            }
        }
        .badge(store.unreadCount)
        .onChange(of: openNoteID) { _ in resolve() }
        .onChange(of: store.inbox) { _ in resolve() }
        .onAppear { resolve() }
    }

    private func resolve() {
        guard let id = openNoteID, let record = store.note(id: id) else { return }
        openNoteID = nil
        if pendingNote != nil, pendingNote?.id != record.id {
            // A different note is already open: pop it, then push the new one on the next turn.
            pendingNote = nil
            DispatchQueue.main.async { pendingNote = record }
        } else {
            pendingNote = record
        }
    }
}

/// Wraps `NotesInboxView` for use inside ConversationsTab's stack. The stack has no typed
/// `[NoteRecord]` path (it also carries chat targets), so the note to open arrives as `note`
/// and is shown through an `isPresented` destination. Row taps still use the inbox's own
/// value-based links. The destination is armed one turn after appearing so a note that was
/// resolved before the inbox existed still animates in.
private struct NotesInboxHost: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var accountManager: AccountManager
    @Binding var note: NoteRecord?
    @State private var armed = false

    var body: some View {
        NotesInboxView(
            store: store,
            accountManager: accountManager,
            openNoteID: .constant(nil),
            path: Binding(get: { note.map { [$0] } ?? [] }, set: { note = $0.last })
        )
        .navigationDestination(isPresented: Binding(get: { armed && note != nil }, set: { if !$0 { note = nil } })) {
            if let record = note { NoteDetailView(record: record, store: store) }
        }
        .onAppear { DispatchQueue.main.async { armed = true } }
    }
}

/// Diary tab body: owns the NavigationStack path so a notification tap can push a diary,
/// mirroring `ConversationsTabContent`.
private struct DiaryTabContent: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var accountManager: AccountManager
    @Binding var openDiaryID: String?
    @Binding var openDiarySeq: Int?
    @Binding var path: [String]

    var body: some View {
        NavigationStack(path: $path) {
            DiaryListView(store: store, accountManager: accountManager, openDiaryID: $openDiaryID, openDiarySeq: $openDiarySeq, path: $path)
        }
    }
}

/// UIKit share sheet wrapper for saving/sharing received files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
