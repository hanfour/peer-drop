// PlatformColors.swift
// Cross-platform replacements for iOS UIKit semantic colors.
//
// SwiftUI's `Color(UIColor.systemGray*)` constructors are iOS-only — they
// don't exist on macOS. To keep view source cross-platform, this file
// exposes platform-aware Color helpers that resolve to:
//   - the matching UIKit semantic color on iOS
//   - the closest NSColor equivalent on macOS
//
// Added in M2 Task 6a (surface-level macOS port). If a richer design
// system lands later, these can be replaced with semantic tokens.

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// Subtle fill background (matches iOS `.systemGray6`).
    static var peerDropFillTertiary: Color {
        #if os(iOS)
        return Color(.systemGray6)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.gray.opacity(0.15)
        #endif
    }

    /// Slightly stronger fill (matches iOS `.systemGray5`).
    static var peerDropFillSecondary: Color {
        #if os(iOS)
        return Color(.systemGray5)
        #elseif os(macOS)
        return Color(nsColor: .underPageBackgroundColor)
        #else
        return Color.gray.opacity(0.2)
        #endif
    }

    /// Mid-gray fill (matches iOS `.systemGray4`).
    static var peerDropFillPrimary: Color {
        #if os(iOS)
        return Color(.systemGray4)
        #elseif os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color.gray.opacity(0.25)
        #endif
    }

    /// Grouped-content background (matches iOS `.secondarySystemBackground`).
    static var peerDropGroupedBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemBackground)
        #elseif os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color.gray.opacity(0.1)
        #endif
    }

    /// Secondary grouped-background (matches iOS `.secondarySystemGroupedBackground`).
    static var peerDropSecondaryGroupedBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #elseif os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color.gray.opacity(0.1)
        #endif
    }

    /// Primary-text-tinted shadow color (matches iOS `Color(.label)`).
    /// `Color.primary` is the cross-platform spelling; this alias makes
    /// the intent explicit at the call site (it's used for tinted shadows
    /// in toast/header components).
    static var peerDropLabel: Color {
        Color.primary
    }
}
