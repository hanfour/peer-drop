import SwiftUI
import PeerDropCore

#if os(iOS)
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var connectionManager: ConnectionManager

    private var gradientColors: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.12, green: 0.32, blue: 0.78), Color(red: 0.16, green: 0.24, blue: 0.72)]
            : [Color(red: 0.22, green: 0.49, blue: 0.98), Color(red: 0.28, green: 0.38, blue: 0.95)]
    }

    private struct OnboardingPageModel {
        let id: Int
        let content: AnyView
    }

    private var pages: [OnboardingPageModel] {
        [
            OnboardingPageModel(id: 0, content: AnyView(OnboardingPage(
                icon: { AnyView(PhoneChatWifiShape().fill(.white).frame(width: 80, height: 80)) },
                title: "Welcome to PeerDrop",
                subtitle: "Secure peer-to-peer sharing"
            ))),
            OnboardingPageModel(id: 1, content: AnyView(OnboardingPage(
                icon: { AnyView(Image(systemName: "wifi").font(.system(size: 60)).foregroundStyle(.white)) },
                title: "Discover Nearby Devices",
                subtitle: "Find devices on your local network automatically"
            ))),
            OnboardingPageModel(id: 2, content: AnyView(OnboardingPage(
                icon: { AnyView(Image(systemName: "antenna.radiowaves.left.and.right.circle").font(.system(size: 60)).foregroundStyle(.white)) },
                title: "Connect Anywhere",
                subtitle: "Share across different networks using relay transport — no same WiFi required"
            ))),
            OnboardingPageModel(id: 3, content: AnyView(OnboardingPage(
                icon: { AnyView(Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 60)).foregroundStyle(.white)) },
                title: "Share Anything",
                subtitle: "Send files, photos, videos, and messages securely"
            ))),
            OnboardingPageModel(id: 4, content: AnyView(OnboardingAccountPage(accountManager: connectionManager.accountManager))),
            OnboardingPageModel(id: 5, content: AnyView(OnboardingPage(
                icon: { AnyView(Image(systemName: "checkmark.circle").font(.system(size: 60)).foregroundStyle(.white)) },
                title: "You're All Set",
                subtitle: "Start sharing with nearby devices"
            ))),
        ]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack {
                TabView(selection: $currentPage) {
                    ForEach(pages, id: \.id) { $0.content.tag($0.id) }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if currentPage < pages.count - 1 {
                        withAnimation { currentPage += 1 }
                    } else {
                        hasCompletedOnboarding = true
                    }
                } label: {
                    Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                        .font(.headline)
                        .foregroundStyle(gradientColors[0])
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

                if currentPage < pages.count - 1 {
                    Button("Skip") {
                        hasCompletedOnboarding = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 24)
                } else {
                    Spacer().frame(height: 48)
                }
            }
        }
    }
}

private struct OnboardingPage: View {
    let icon: () -> AnyView
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            icon()
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }
}
#else
// Onboarding is iOS-only — the swipeable intro uses `TabView.page` style and
// touch interactions that don't translate to macOS. macOS users go through
// `MacContentView` (Task 5) on first launch and never see this view.
// Stub kept so the file compiles cross-platform; not invoked anywhere on macOS.
struct OnboardingView: View {
    var body: some View { EmptyView() }
}
#endif
