import SwiftUI

/// User-facing banner for crypto-hardening events that need surfacing.
/// Currently handles C2 OPK exhaustion (retry-in-progress + final exhausted).
/// PR6 will add a `c1SPKExpired` case for SPK timestamp violations.
public struct CryptoHardeningBanner: View {

    public enum Kind: Equatable {
        case c2OPKRetry(attempts: Int, max: Int)
        case c2OPKExhausted
    }

    public let kind: Kind
    public let onPrimaryAction: () -> Void

    public init(kind: Kind, onPrimaryAction: @escaping () -> Void) {
        self.kind = kind
        self.onPrimaryAction = onPrimaryAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text(titleKey)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(bodyText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(action: onPrimaryAction) {
                    Text(primaryActionKey)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(.systemOrange).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Localization helpers

    private var iconName: String {
        switch kind {
        case .c2OPKRetry:      return "arrow.triangle.2.circlepath"
        case .c2OPKExhausted:  return "exclamationmark.triangle"
        }
    }

    private var titleKey: LocalizedStringKey {
        switch kind {
        case .c2OPKRetry:      return "c2.opk.retry.title"
        case .c2OPKExhausted:  return "c2.opk.exhausted.title"
        }
    }

    /// Body text built as a plain `String` so we can pass positional args
    /// directly through `String(format:)` for the `%1$@/%2$@` body pattern,
    /// matching the project's existing `String(localized:)` interpolation style.
    private var bodyText: String {
        switch kind {
        case .c2OPKRetry(let attempts, let max):
            return String(
                format: String(localized: "c2.opk.retry.body"),
                String(attempts),
                String(max)
            )
        case .c2OPKExhausted:
            return String(localized: "c2.opk.exhausted.body")
        }
    }

    private var primaryActionKey: LocalizedStringKey {
        switch kind {
        case .c2OPKRetry:      return "c2.opk.action.cancel"
        case .c2OPKExhausted:  return "c2.opk.action.retry"
        }
    }
}

// MARK: - Debug test seam

#if DEBUG
extension CryptoHardeningBanner {
    /// Test seam: invoke the primary action without driving SwiftUI.
    /// Used by `CryptoHardeningBannerTests` to verify the action closure
    /// is properly wired without instantiating the whole view hierarchy.
    func invokeActionForTesting() {
        onPrimaryAction()
    }
}
#endif
