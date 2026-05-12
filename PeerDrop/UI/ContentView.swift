import SwiftUI

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

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var petEngine: PetEngine
    @EnvironmentObject var inboxService: InboxService
    @ObservedObject private var pushManager = PushNotificationManager.shared
    @State private var selectedTab = 0
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
                NearbyTab(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("Nearby", systemImage: "wifi")
            }
            .tag(0)
            .accessibilityLabel("Nearby")
            .accessibilityHint("Discover Nearby Devices")

            NavigationStack {
                ConnectedTab()
            }
            .tabItem {
                Label("Connected", systemImage: "link")
            }
            .tag(1)
            .accessibilityLabel("Connected")
            .accessibilityHint("View connected devices")

            NavigationStack {
                LibraryTab()
            }
            .tabItem {
                Label("Library", systemImage: "archivebox")
            }
            .tag(2)
            .accessibilityLabel("Library")
            .accessibilityHint("View saved devices and groups")

            NavigationStack {
                PetTabView()
                    .environmentObject(petEngine)
            }
            .tabItem {
                Label("Pet", systemImage: "pawprint.fill")
            }
            .tag(3)
        }
        .modifier(TabBarOnlyModifier())  // Force tab bar on iPad
        .sheet(item: $connectionManager.pendingIncomingRequest) { request in
            ConsentSheet(request: request)
                .environmentObject(connectionManager)
        }
        .sheet(item: $connectionManager.pendingFirstContact) { pending in
            FirstContactVerificationSheet(
                pending: pending,
                onApprove: {
                    connectionManager.approveFirstContact(fingerprint: pending.fingerprint)
                },
                onReject: {
                    connectionManager.rejectFirstContact(fingerprint: pending.fingerprint)
                }
            )
        }
        .sheet(item: $connectionManager.pendingLocalFirstTrust) { pending in
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
                selectedTab = 0
            }
            Button("Back to Discovery", role: .cancel) {
                connectionManager.transition(to: .discovering)
                connectionManager.restartDiscovery()
                selectedTab = 0
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
                selectedTab = 1
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
}

/// UIKit share sheet wrapper for saving/sharing received files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
