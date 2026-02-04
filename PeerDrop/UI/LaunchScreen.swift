import SwiftUI

struct LaunchScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.12, green: 0.32, blue: 0.78), Color(red: 0.16, green: 0.24, blue: 0.72)]
                    : [Color(red: 0.22, green: 0.49, blue: 0.98), Color(red: 0.28, green: 0.38, blue: 0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                PhoneChatWifiShape()
                    .fill(.white)
                    .frame(width: 90, height: 90)

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

// MARK: - Phone Chat WiFi Shape (from SVG, viewBox 0 0 35 35)

struct PhoneChatWifiShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 35.0
        let ox = rect.minX + (rect.width - 35 * s) / 2
        let oy = rect.minY + (rect.height - 35 * s) / 2

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }

        var path = Path()

        // --- WiFi arc 1 (outermost) ---
        path.move(to: p(20.133, 18.387))
        path.addCurve(to: p(13.797, 12.050), control1: p(20.133, 14.893), control2: p(17.291, 12.050))
        path.addLine(to: p(13.797, 10.983))
        path.addCurve(to: p(21.203, 18.386), control1: p(17.881, 10.981), control2: p(21.203, 14.303))
        path.addLine(to: p(20.133, 18.387))
        path.closeSubpath()

        // --- WiFi arc 2 (middle) ---
        path.move(to: p(19.356, 18.386))
        path.addCurve(to: p(13.795, 12.829), control1: p(19.354, 15.324), control2: p(16.861, 12.829))
        path.addLine(to: p(13.797, 13.898))
        path.addCurve(to: p(18.283, 18.385), control1: p(16.271, 13.898), control2: p(18.283, 15.913))
        path.addLine(to: p(19.356, 18.386))
        path.closeSubpath()

        // --- WiFi arc 3 (innermost) ---
        path.move(to: p(13.797, 14.738))
        path.addLine(to: p(13.799, 15.808))
        path.addCurve(to: p(16.377, 18.386), control1: p(15.219, 15.806), control2: p(16.377, 16.963))
        path.addLine(to: p(17.445, 18.386))
        path.addCurve(to: p(13.797, 14.738), control1: p(17.445, 16.375), control2: p(15.809, 14.739))
        path.closeSubpath()

        // --- Phone body (outer shell) ---
        path.move(to: p(26.29, 2.043))
        path.addLine(to: p(26.29, 28.219))
        path.addCurve(to: p(24.244, 30.264), control1: p(26.29, 29.344), control2: p(25.165, 30.264))
        path.addLine(to: p(16.594, 30.264))
        path.addLine(to: p(11.857, 35.0))
        path.addLine(to: p(11.857, 30.264))
        path.addLine(to: p(10.753, 30.264))
        path.addCurve(to: p(8.71, 28.219), control1: p(9.629, 30.264), control2: p(8.71, 29.344))
        path.addLine(to: p(8.71, 2.043))
        path.addCurve(to: p(10.753, 0), control1: p(8.71, 0.919), control2: p(9.629, 0))
        path.addLine(to: p(24.244, 0))
        path.addCurve(to: p(26.29, 2.043), control1: p(25.369, 0), control2: p(26.29, 0.919))
        path.closeSubpath()

        // --- Speaker notch ---
        path.move(to: p(15.094, 1.723))
        path.addCurve(to: p(15.341, 1.968), control1: p(15.094, 1.858), control2: p(15.205, 1.968))
        path.addLine(to: p(19.655, 1.968))
        path.addCurve(to: p(19.903, 1.723), control1: p(19.795, 1.968), control2: p(19.903, 1.858))
        path.addCurve(to: p(19.655, 1.473), control1: p(19.903, 1.584), control2: p(19.795, 1.473))
        path.addLine(to: p(15.341, 1.473))
        path.addCurve(to: p(15.094, 1.723), control1: p(15.205, 1.473), control2: p(15.094, 1.584))
        path.closeSubpath()

        // --- Screen / chat bubble cutout ---
        path.move(to: p(24.868, 3.241))
        path.addLine(to: p(10.132, 3.241))
        path.addLine(to: p(10.132, 26.48))
        path.addLine(to: p(13.233, 26.497))
        path.addLine(to: p(13.233, 31.656))
        path.addLine(to: p(18.392, 26.497))
        path.addLine(to: p(24.871, 26.48))
        path.addLine(to: p(24.868, 3.241))
        path.closeSubpath()

        return path
    }
}
