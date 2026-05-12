import SwiftUI
import UIKit
import UserNotifications

/// Shows the current APNs registration pipeline status in the Settings
/// Notifications section. Without this surface, the v5.0–v5.2 "silent
/// swallow" of `didFailToRegisterForRemoteNotificationsWithError` left the
/// entire push pipeline broken-by-default invisible to both users and
/// operator — a missing `aps-environment` entitlement looked identical to
/// a working install.
///
/// Tap behavior:
///   - permission denied: open iOS Settings.app (only place to flip it)
///   - permission notDetermined: kick off `requestAuthorizationAndRegister`
///   - registered/registering: no-op (display only)
///   - failed: re-attempt registration
struct PushStatusRow: View {
    @ObservedObject private var pushManager = PushNotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(indicator.color)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push Notifications")
                        .foregroundStyle(.primary)
                    Text(indicator.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if indicator.tappable {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!indicator.tappable)
        .task {
            await pushManager.refreshAuthorizationStatus()
        }
        .onChange(of: scenePhase) { newPhase in
            // User may have flipped permission in iOS Settings while we
            // were backgrounded — re-read on every foreground.
            if newPhase == .active {
                Task { await pushManager.refreshAuthorizationStatus() }
            }
        }
    }

    private struct Indicator {
        let color: Color
        let label: String
        let tappable: Bool
    }

    private var indicator: Indicator {
        switch pushManager.authorizationStatus {
        case .denied:
            return Indicator(
                color: .red,
                label: String(localized: "Permission denied — tap to open Settings"),
                tappable: true)
        case .notDetermined:
            return Indicator(
                color: .gray,
                label: String(localized: "Not requested yet — tap to enable"),
                tappable: true)
        case .authorized, .provisional, .ephemeral:
            switch pushManager.registrationState {
            case .notRequested:
                return Indicator(
                    color: .orange,
                    label: String(localized: "Permission granted — tap to register"),
                    tappable: true)
            case .registering:
                return Indicator(
                    color: .orange,
                    label: String(localized: "Registering with Apple Push…"),
                    tappable: false)
            case .registered(let prefix, let synced):
                return Indicator(
                    color: synced ? .green : .orange,
                    label: synced
                        ? String(localized: "Active · token \(prefix)…")
                        : String(localized: "Token \(prefix)… · syncing with server"),
                    tappable: false)
            case .failed(let reason):
                return Indicator(
                    color: .red,
                    label: String(localized: "Failed: \(reason) — tap to retry"),
                    tappable: true)
            }
        @unknown default:
            return Indicator(
                color: .gray,
                label: String(localized: "Unknown state"),
                tappable: false)
        }
    }

    private func handleTap() {
        switch pushManager.authorizationStatus {
        case .denied:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .notDetermined:
            Task { await pushManager.requestAuthorizationAndRegister() }
        case .authorized, .provisional, .ephemeral:
            switch pushManager.registrationState {
            case .notRequested, .failed:
                Task { await pushManager.requestAuthorizationAndRegister() }
            default:
                break  // registering / registered → no-op
            }
        @unknown default:
            break
        }
    }
}
