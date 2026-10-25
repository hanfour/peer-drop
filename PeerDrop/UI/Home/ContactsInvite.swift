#if os(iOS)
import SwiftUI
import Contacts
import MessageUI

/// Phone contacts offered as "invite" rows on Home. Everything stays on this device: the list is read
/// into memory for display only, never stored or sent anywhere. "Invite" hands a message to the
/// system composer (or the share sheet), so the person sends it themselves.
@MainActor
final class ContactsInviteModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        /// First phone number, used only to address the Messages composer.
        let phone: String?
    }

    @Published private(set) var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var entries: [Entry] = []

    var canList: Bool {
        if #available(iOS 18.0, *) { return status == .authorized || status == .limited }
        return status == .authorized
    }
    var canAsk: Bool { status == .notDetermined }

    func refresh() {
        status = CNContactStore.authorizationStatus(for: .contacts)
        guard canList else { entries = []; return }
        Task {
            let loaded = await Task.detached(priority: .utility) { Self.loadEntries() }.value
            entries = loaded
        }
    }

    func requestAccess() {
        CNContactStore().requestAccess(for: .contacts) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    nonisolated private static func loadEntries() -> [Entry] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var out: [Entry] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let name = (CNContactFormatter.string(from: contact, style: .fullName) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            out.append(Entry(id: contact.identifier, name: name, phone: contact.phoneNumbers.first?.value.stringValue))
        }
        return out
    }
}

/// What "Invite" sends. The URL is the App Store page; no per-person code, nothing to track.
enum InviteMessage {
    static let appURL = URL(string: "https://apps.apple.com/app/id6759594513")!

    static func body() -> String {
        String(format: String(localized: "Let's connect on PeerDrop: %@"), appURL.absoluteString)
    }
}

/// Messages composer for one recipient. Falls back to the share sheet where texting is unavailable
/// (iPad without a SIM, simulator).
struct InviteComposer: UIViewControllerRepresentable {
    let recipient: String?
    let onFinish: () -> Void

    static var canCompose: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.body = InviteMessage.body()
        if let recipient { vc.recipients = [recipient] }
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true) { self.onFinish() }
        }
    }
}
#endif
