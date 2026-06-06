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
            PetSectionView()
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
/// after fixing that view's iOS-only dependencies. Task 6b will wire the
/// peer-row tap to `openWindow(id: "chat", value: peerID)` (Task 7 scene).
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

// Task 9 replaced `MacPetSectionStub` with `PetSectionView` (see
// `PetSectionView.swift`). The stub struct is intentionally removed —
// the section now renders the live PetEngine sprite at 256pt.
