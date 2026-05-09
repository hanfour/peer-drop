import SwiftUI

/// Wrapper view that observes `PetEngine.renderedImage` and re-passes it
/// into `V5UpgradeOnboarding` whenever the image arrives.
///
/// Without this host, `PeerDropApp`'s `.sheet { V5UpgradeOnboarding(petImage:
/// petEngine.renderedImage, ...) }` captures the image at sheet construction
/// time — typically nil because `updateRenderedImage()` is an async Task
/// that hasn't completed by then. User sees a pawprint placeholder until
/// they dismiss + relaunch.
///
/// SwiftUI re-renders the host body whenever `petEngine` (an
/// `@ObservedObject`) emits, propagating the latest `renderedImage` to the
/// child view via the standard data flow.
struct V5UpgradeOnboardingHost: View {
    @ObservedObject var petEngine: PetEngine
    let onDismiss: () -> Void

    var body: some View {
        V5UpgradeOnboarding(
            petImage: petEngine.renderedImage,
            petName: petEngine.pet.name,
            onDismiss: onDismiss
        )
    }
}
