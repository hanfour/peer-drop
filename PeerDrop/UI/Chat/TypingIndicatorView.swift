import SwiftUI

struct TypingIndicatorView: View {
    let peerName: String
    @State private var animationPhase = 0

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 6, height: 6)
                        .offset(y: animationOffset(for: index))
                }
            }
            .padding(.trailing, 6)

            Text("\(peerName) is typing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peerName) is typing")
        .onAppear {
            startAnimation()
        }
    }

    private func animationOffset(for index: Int) -> CGFloat {
        animationPhase == index ? -4 : 0
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                animationPhase = (animationPhase + 1) % 3
            }
        }
    }
}

#Preview {
    TypingIndicatorView(peerName: "John")
        .padding()
}
