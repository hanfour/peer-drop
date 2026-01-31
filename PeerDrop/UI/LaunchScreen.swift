import SwiftUI

struct LaunchScreen: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.49, blue: 0.98),
                    Color(red: 0.28, green: 0.38, blue: 0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)

                Text("PeerDrop")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Secure peer-to-peer sharing")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}
