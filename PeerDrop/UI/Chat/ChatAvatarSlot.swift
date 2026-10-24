import SwiftUI

/// Fixed-width avatar column for incoming chat messages. When `visible` is
/// false it reserves the same width so bubble left edges stay aligned.
struct ChatAvatarSlot: View {
    let name: String
    let visible: Bool

    static let width: CGFloat = 32

    var body: some View {
        Group {
            if visible {
                PeerAvatar(name: name, size: Self.width)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.width, height: visible ? Self.width : 0)
        .accessibilityHidden(true)
    }
}
