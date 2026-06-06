#if canImport(AppKit)
import SwiftUI

/// SwiftUI content of the floating NSPanel shown when a peer is calling.
///
/// Compact (380×80) so it can hover top-right of the active screen
/// without dominating the user's workspace. Avatar + name + accept /
/// decline buttons. The hosting NSPanel handles "don't activate the
/// app" + "stay across Spaces" behaviour.
struct IncomingCallPanelView: View {
    let callerName: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Incoming call")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(callerName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onDecline) {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Decline call")
                .accessibilityLabel("Decline call")

                Button(action: onAccept) {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.green, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Accept call")
                .accessibilityLabel("Accept call")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 380, height: 80)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif
