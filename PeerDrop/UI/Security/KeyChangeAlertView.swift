import SwiftUI

struct KeyChangeAlertView: View {
    let contactName: String
    let oldFingerprint: String
    let newFingerprint: String
    let onBlock: () -> Void
    let onAccept: () -> Void
    let onVerifyLater: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Security Warning")
                .font(.title.bold())

            Text("\(contactName)'s encryption key has changed.")
                .font(.body)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Text("This could be because:")
                    .font(.subheadline.bold())
                reasonRow(icon: "iphone", text: String(localized: "\(contactName) got a new device"))
                reasonRow(icon: "arrow.clockwise", text: String(localized: "\(contactName) reinstalled PeerDrop"))
                reasonRow(icon: "exclamationmark.triangle", text: String(localized: "Someone is trying to impersonate \(contactName)"))
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                fingerprintRow(label: String(localized: "Previous"), value: oldFingerprint)
                fingerprintRow(label: String(localized: "New"), value: newFingerprint)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()

            VStack(spacing: 12) {
                Button(action: onBlock) {
                    Label(String(localized: "Block This Contact"), systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: onAccept) {
                    Label(String(localized: "Accept New Key"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onVerifyLater) {
                    Label(String(localized: "Verify Next Time"), systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding()
    }

    private func reasonRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
        }
    }

    private func fingerprintRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}
