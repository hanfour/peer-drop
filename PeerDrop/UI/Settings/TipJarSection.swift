import SwiftUI
import StoreKit

/// "Support PeerDrop" Settings section. Three tip cards driven by
/// `TipJarManager`. Displays only when the products load successfully —
/// silently absent if the user is in a region that can't transact, on
/// a build before the IAPs went live in App Store Connect, or
/// offline. We never want a half-broken paywall to be a user's first
/// impression.
///
/// See docs/plans/2026-05-14-iap-tip-jar.md for the strategy +
/// "no feature gating, ever" stance.
struct TipJarSection: View {
    @StateObject private var tipJar = TipJarManager.shared
    @State private var showThanksToast = false
    @State private var thanksMessage = ""

    var body: some View {
        Group {
            if tipJar.products.isEmpty && !tipJar.isWorking {
                // Either the products haven't loaded yet (first paint
                // before .task fires) or the App Store didn't return
                // them (sandbox / region / pre-launch). Stay invisible
                // rather than showing an empty section.
                EmptyView()
            } else {
                Section {
                    if tipJar.products.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 12) {
                            ForEach(tipJar.products, id: \.id) { product in
                                tipCard(product)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Support PeerDrop")
                } footer: {
                    Text("PeerDrop is free and ad-free. Tips go to the developer — they don't unlock anything, they just say thanks.")
                }
            }
        }
        .task { await tipJar.loadProducts() }
        .onChange(of: tipJar.lastSucceededTipName) { name in
            guard let name else { return }
            thanksMessage = String(localized: "Thanks for the \(name)!")
            withAnimation { showThanksToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showThanksToast = false }
                tipJar.lastSucceededTipName = nil
            }
        }
        .alert("Purchase failed", isPresented: Binding(
            get: { tipJar.lastError != nil },
            set: { if !$0 { tipJar.lastError = nil } }
        ), actions: {
            Button("OK", role: .cancel) { tipJar.lastError = nil }
        }, message: {
            Text(tipJar.lastError ?? "")
        })
        .overlay(alignment: .top) {
            if showThanksToast {
                Text(thanksMessage)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// One tip card. Title from `Product.displayName` (set in ASC per
    /// locale), price from `Product.displayPrice` (auto-localized by
    /// StoreKit including currency symbol). Disabled while any purchase
    /// is in flight to prevent double-taps creating two purchases.
    private func tipCard(_ product: Product) -> some View {
        Button {
            Task { await tipJar.purchase(product) }
        } label: {
            VStack(spacing: 6) {
                Text(emoji(for: product.id))
                    .font(.title)
                Text(product.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(product.displayPrice)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if tipJar.purchasingProductID == product.id {
                    ProgressView()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(tipJar.purchasingProductID != nil)
        .opacity(
            tipJar.purchasingProductID != nil && tipJar.purchasingProductID != product.id
                ? 0.4 : 1.0)
    }

    /// Map product IDs to emojis. Cheap UX hint that scales with
    /// tier — coffee, lunch, party.
    private func emoji(for productID: String) -> String {
        switch productID {
        case "com.hanfour.peerdrop.tip.small":  return "☕"
        case "com.hanfour.peerdrop.tip.medium": return "🍱"
        case "com.hanfour.peerdrop.tip.large":  return "🎉"
        default: return "💝"
        }
    }
}
