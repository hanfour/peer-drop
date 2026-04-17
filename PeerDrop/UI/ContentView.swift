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

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var petEngine: PetEngine
    @EnvironmentObject var inboxService: InboxService
    @ObservedObject private var pushManager = PushNotificationManager.shared
    @State private var selectedTab = 0
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showShareSheet = false
    @State private var receivedFileURL: URL?
    @State private var showStatusToast = false
    @State private var statusToastMessage: String?
    @State private var showReportSentToast = false
    @State private var currentInvite: RelayInvite?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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
        .sheet(isPresented: $connectionManager.showTransferProgress) {
            TransferProgressView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $connectionManager.showVoiceCall) {
            VoiceCallView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = receivedFileURL {
                ShareSheet(items: [url])
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
                // Only show alert if not suppressed (e.g., ChatView handles it locally)
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
                receivedFileURL = url
                showShareSheet = true
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
            currentInvite = invite
            inboxService.receivedInvite = nil
        }
        .onReceive(pushManager.$receivedInvite.compactMap { $0 }) { invite in
            currentInvite = invite
            pushManager.receivedInvite = nil
        }

            // Invite banner overlay
            if let invite = currentInvite {
                InviteBanner(
                    invite: invite,
                    onAccept: {
                        connectionManager.acceptRelayInvite(invite)
                        currentInvite = nil
                    },
                    onDecline: { currentInvite = nil }
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
}

/// UIKit share sheet wrapper for saving/sharing received files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
