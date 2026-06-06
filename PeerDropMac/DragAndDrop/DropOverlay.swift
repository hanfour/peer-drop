import SwiftUI

/// Visual feedback overlay shown when files are being dragged over a
/// drop-receptive view (main window, menu-bar peer rows). Animates in via
/// SwiftUI `.transition(.opacity)`.
struct DropOverlay: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.tint, lineWidth: 4)
                .background(.tint.opacity(0.12))
                .overlay(
                    Label("Drop to send", systemImage: "arrow.down.doc.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                )
                .padding(20)
                .transition(.opacity)
        }
    }
}
