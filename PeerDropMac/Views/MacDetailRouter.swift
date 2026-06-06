import SwiftUI
import PeerDropCore

struct MacDetailRouter: View {
    let section: MacSidebarSection?
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        switch section {
        case .nearby:
            MacNearbySectionStub()
        case .trusted:
            MacTrustedSectionStub()
        case .relay:
            MacRelaySectionStub()
        case .pet:
            MacPetSectionStub()
        case .none:
            ContentUnavailableView(
                "Choose a section",
                systemImage: "sidebar.left",
                description: Text("Pick Nearby, Trusted, Relay, or Pet from the sidebar.")
            )
        }
    }
}

// MARK: - Section stubs (Task 6 replaces with real iOS view reuse)

/// Stub for the Nearby section. Task 6 replaces with `NearbyTab` reuse
/// after fixing that view's iOS-only dependencies.
struct MacNearbySectionStub: View {
    var body: some View {
        ContentUnavailableView(
            "Nearby",
            systemImage: "wifi",
            description: Text("Discovery UI lands in Task 6.")
        )
    }
}

/// Stub for the Trusted section. Task 6 replaces with `LibraryTab` reuse.
struct MacTrustedSectionStub: View {
    var body: some View {
        ContentUnavailableView(
            "Trusted",
            systemImage: "checkmark.shield",
            description: Text("Trusted-devices UI lands in Task 6.")
        )
    }
}

/// Stub for the Relay section. Task 6 replaces with `RelayConnectView` reuse.
struct MacRelaySectionStub: View {
    var body: some View {
        ContentUnavailableView(
            "Relay",
            systemImage: "network",
            description: Text("Relay-connect UI lands in Task 6.")
        )
    }
}

/// Stub for the Pet section. Task 9 fills with the Pet sprite renderer.
struct MacPetSectionStub: View {
    var body: some View {
        ContentUnavailableView(
            "Pet",
            systemImage: "pawprint",
            description: Text("Pet hub lands in Task 9.")
        )
    }
}
