import SwiftUI
import PeerDropCore

/// Mac mirror of iOS `ContentView`'s security-sheet routing (that file is
/// excluded from the Mac target, so its `private` route enum + binding
/// never reached macOS). Without this modifier nothing on the Mac consumes
/// `ConnectionManager.pendingIncomingRequest` / `pendingFirstContact` /
/// `pendingLocalFirstTrust`: an inbound connection request had NO accept
/// affordance anywhere on macOS, so the initiating iPhone always hit the
/// 10s "Connection request timed out" path (found during the 2026-06-12
/// Mac ↔ iPhone live verification — see audit round 14's startDiscovery
/// fix for the sibling gap on the outbound side).
///
/// The sheet content views (`ConsentSheet`, `FirstContactVerificationSheet`)
/// are already cross-platform and compiled into the Mac target; only the
/// presentation plumbing was missing.
private enum MacSecuritySheetRoute: Identifiable {
    case incomingRequest(IncomingRequest)
    case firstContact(PendingFirstContact)
    case localFirstTrust(PendingFirstContact)

    var id: String {
        switch self {
        case .incomingRequest(let r):  return "incoming:\(r.id)"
        case .firstContact(let p):     return "remote:\(p.id)"
        case .localFirstTrust(let p):  return "local:\(p.id)"
        }
    }
}

struct MacSecuritySheetsModifier: ViewModifier {
    @EnvironmentObject var connectionManager: ConnectionManager

    func body(content: Content) -> some View {
        content
            .sheet(item: securitySheetBinding) { route in
                switch route {
                case .incomingRequest(let request):
                    ConsentSheet(request: request)
                        .environmentObject(connectionManager)
                case .firstContact(let pending):
                    FirstContactVerificationSheet(
                        pending: pending,
                        onApprove: {
                            connectionManager.approveFirstContact(fingerprint: pending.fingerprint)
                        },
                        onReject: {
                            connectionManager.rejectFirstContact(fingerprint: pending.fingerprint)
                        }
                    )
                case .localFirstTrust(let pending):
                    FirstContactVerificationSheet(
                        pending: pending,
                        onApprove: {
                            connectionManager.approveLocalFirstTrust(fingerprint: pending.fingerprint)
                        },
                        onReject: {
                            connectionManager.blockLocalFirstTrust(fingerprint: pending.fingerprint)
                        }
                    )
                }
            }
    }

    /// Read: highest-priority non-nil source wins. Write: only dismiss-to-nil
    /// matters — clear whichever source the active sheet was reading from.
    /// Mirrors iOS ContentView.securitySheetBinding verbatim.
    private var securitySheetBinding: Binding<MacSecuritySheetRoute?> {
        Binding(
            get: {
                if let req = connectionManager.pendingIncomingRequest {
                    return .incomingRequest(req)
                }
                if let pending = connectionManager.pendingFirstContact {
                    return .firstContact(pending)
                }
                if let pending = connectionManager.pendingLocalFirstTrust {
                    return .localFirstTrust(pending)
                }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if connectionManager.pendingIncomingRequest != nil {
                    connectionManager.pendingIncomingRequest = nil
                } else if connectionManager.pendingFirstContact != nil {
                    connectionManager.pendingFirstContact = nil
                } else if connectionManager.pendingLocalFirstTrust != nil {
                    connectionManager.pendingLocalFirstTrust = nil
                }
            }
        )
    }
}
