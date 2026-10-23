// PaperTheme.swift
// "Paper" colour tokens for the chat UI: warm cream in light mode, warm brown
// in dark mode. Hex values live in `PaperPalette` (pure, unit-testable);
// `PaperTheme.color(_:)` resolves them adaptively for the current appearance.

import SwiftUI
import PeerDropCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PaperToken: CaseIterable {
    case background, border, incomingBubble, outgoingBubble
    case incomingText, outgoingText
    case datePillFill, datePillText
    case inputFill, inputPlaceholder, sendButton
    case tickSent, tickDelivered, tickRead, tickFailed
    case quoteBar, typingDot
    /// Fill for prominent action buttons (swipe Reply, Verify, Reconnect). SwiftUI draws their
    /// label white, so one value serves both modes: white >= 4.5:1 and >= 3:1 on `background`.
    case actionFill
    /// Security-warning glyph on banner fills (`datePillFill`), >= 3:1 in both modes.
    case warning
    /// Tint for system controls (back chevron, links); >= 4.5:1 on `background`.
    case accent
    // MSN-style tokens. brand/highlight/online/note* are identical in both modes.
    /// Brand blue; carries a white label at >= 4.5:1.
    case brand
    /// Selection / progress accent (never carries text), >= 3:1 on `background`.
    case highlight
    /// "Online" presence dot (never carries text), >= 3:1 on `background`.
    case online
    /// Sticky-note ("note") fill, border, text and badge.
    case noteFill, noteBorder, noteText, noteBadge
}

/// Page ground: `.live` is a crisp white-blue; `.note` is the warm paper look.
enum PaperMode { case live, note }

enum PaperPalette {
    /// 0xRRGGBB for the token in the given appearance.
    static func hex(_ token: PaperToken, dark: Bool, mode: PaperMode = .note) -> UInt32 {
        switch token {
        // Mode-independent tokens.
        case .brand:      return dark ? 0x0B6FC4 : 0x0076D4
        case .highlight:  return dark ? 0x00A2E8 : 0x0087C8
        case .online:     return dark ? 0x80C41C : 0x4C9A0A
        case .noteFill:   return dark ? 0x4A3810 : 0xFFF1CC
        case .noteBorder: return dark ? 0xF9A825 : 0xC77C00
        case .noteText:   return dark ? 0xFFE9B0 : 0x4A3200
        case .noteBadge:  return 0xF9A825
        default: break
        }
        if mode == .live { return liveHex(token, dark: dark) }
        return noteHex(token, dark: dark)
    }

    private static func liveHex(_ token: PaperToken, dark: Bool) -> UInt32 {
        switch token {
        case .background:       return dark ? 0x0F1720 : 0xF4F9FD
        case .border:           return dark ? 0x2A3846 : 0xDDEAF4
        case .incomingBubble:   return dark ? 0x1A2430 : 0xFFFFFF
        case .outgoingBubble:   return hex(.brand, dark: dark)
        case .incomingText:     return dark ? 0xE6EEF5 : 0x1E2B36
        case .outgoingText:     return 0xFFFFFF
        case .datePillFill:     return dark ? 0x1A2430 : 0xE8F1F8
        case .datePillText:     return dark ? 0x93A4B5 : 0x4F6477
        case .inputFill:        return dark ? 0x1A2430 : 0xFFFFFF
        case .inputPlaceholder: return dark ? 0x93A4B5 : 0x6F8497
        case .sendButton:       return hex(.brand, dark: dark)
        // White blended over the brand bubble: opacity rises sent < delivered < read.
        case .tickSent:         return dark ? 0xC9DFF2 : 0xD9EAF9
        case .tickDelivered:    return dark ? 0xE7F1F9 : 0xEDF5FC
        case .tickRead:         return 0xFFFFFF
        case .tickFailed:       return dark ? 0xFFC4BA : 0xFFD0C8
        case .quoteBar:         return hex(.highlight, dark: dark)
        case .typingDot:        return dark ? 0x93A4B5 : 0x5E7387
        case .actionFill:       return 0x0076D4
        case .warning:          return dark ? 0xF08A6A : 0xC50F1F
        case .accent:           return dark ? 0x5CB0F0 : 0x0069BE
        default:                return noteHex(token, dark: dark)
        }
    }

    private static func noteHex(_ token: PaperToken, dark: Bool) -> UInt32 {
        switch token {
        case .background:       return dark ? 0x2A221C : 0xFBF6EE
        case .border:           return dark ? 0x3A2F27 : 0xEFE4D3
        case .incomingBubble:   return dark ? 0x3A3029 : 0xFFFFFF
        case .outgoingBubble:   return dark ? 0xB97A52 : 0xF6C9A8
        case .incomingText:     return dark ? 0xEADBC8 : 0x4A3B2E
        case .outgoingText:     return dark ? 0x1F1610 : 0x4A3B2E
        case .datePillFill:     return dark ? 0x3A3029 : 0xF1E6D4
        // light adjusted from 0x8A7561 (3.55:1) to pass AA 4.5:1
        case .datePillText:     return dark ? 0xB7A58F : 0x6F5B48
        case .inputFill:        return dark ? 0x3A3029 : 0xFFFFFF
        // light adjusted from 0xB3A391 (2.45:1) to pass 3:1
        case .inputPlaceholder: return dark ? 0x8F7D69 : 0x978671
        case .sendButton:       return dark ? 0xD89268 : 0xF0A878
        // Ticks sit on the outgoing bubble (>= 3:1 there); never blue/cyan.
        case .tickSent:         return dark ? 0x3D1608 : 0x8A5A3A
        case .tickDelivered:    return dark ? 0x3D1608 : 0x7D5B42
        case .tickRead:         return dark ? 0xFFF1E0 : 0x9A3412
        case .tickFailed:       return dark ? 0x6E0C08 : 0xB3261E
        case .quoteBar:         return dark ? 0xD89268 : 0xD9A27A
        case .typingDot:        return dark ? 0xB7A58F : 0x8A7561
        case .actionFill:       return 0xB5532B
        case .warning:          return dark ? 0xF08A6A : 0xB3261E
        case .accent:           return dark ? 0xD89268 : 0xB5532B
        case .brand, .highlight, .online, .noteFill, .noteBorder, .noteText, .noteBadge:
            preconditionFailure("mode-independent token handled in hex(_:dark:mode:)")
        }
    }

    /// WCAG 2.x contrast ratio between two 0xRRGGBB colours (1...21).
    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func relativeLuminance(_ hex: UInt32) -> Double {
        func lin(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(16) + 0.7152 * lin(8) + 0.0722 * lin(0)
    }
}

enum PaperTheme {
    /// Appearance-adaptive colour for a token.
    static func color(_ token: PaperToken, mode: PaperMode = .note) -> Color {
        let light = PaperPalette.hex(token, dark: false, mode: mode)
        let dark = PaperPalette.hex(token, dark: true, mode: mode)
        #if canImport(UIKit)
        return Color(UIColor { traits in
            rgb(traits.userInterfaceStyle == .dark ? dark : light, UIColor.init(red:green:blue:alpha:))
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, NSColor.init(srgbRed:green:blue:alpha:))
        })
        #else
        return Color(red: Double((light >> 16) & 0xFF) / 255, green: Double((light >> 8) & 0xFF) / 255, blue: Double(light & 0xFF) / 255)
        #endif
    }

    /// Tick colour token for a message status (display only).
    static func tick(for status: MessageStatus) -> PaperToken {
        switch status {
        case .sending, .sent: return .tickSent
        case .delivered:      return .tickDelivered
        case .read:           return .tickRead
        case .failed:         return .tickFailed
        }
    }

    private static func rgb<T>(_ hex: UInt32, _ make: (CGFloat, CGFloat, CGFloat, CGFloat) -> T) -> T {
        make(CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, 1)
    }
}

extension View {
    /// Icon-only buttons in the chat input bars: on macOS the default button style
    /// draws a grey bezel box around the already-circular symbol; use the plain
    /// style there. iOS is unchanged (its default already renders the bare symbol).
    @ViewBuilder
    func paperIconButton() -> some View {
        #if os(macOS)
        self.buttonStyle(.plain)
        #else
        self
        #endif
    }
}

private struct PaperModeKey: EnvironmentKey {
    static let defaultValue: PaperMode = .note
}

extension EnvironmentValues {
    var paperMode: PaperMode {
        get { self[PaperModeKey.self] }
        set { self[PaperModeKey.self] = newValue }
    }
}

extension View {
    /// Sets the paper mode that descendants resolve their colours with.
    func paperMode(_ m: PaperMode) -> some View {
        environment(\.paperMode, m)
    }
}
